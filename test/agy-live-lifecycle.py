#!/usr/bin/env python3
"""Opt-in: resume an existing agy conversation across a private tmux restart.

Usage: python3 test/agy-live-lifecycle.py /path/to/tmux-resurrect UUID HISTORY_TEXT
Uses the current account and local conversation store. Sends no user prompt.
HISTORY_TEXT must be a distinctive existing message visible in the restored
conversation. A UUID in launch argv alone is never evidence of loaded history.
"""

import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "agy_session", ROOT / "scripts/py/agy_session.py"
)
agy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agy)
SESSION = "timvw/tmux-assistant-resurrect - pr-109 - review-antigravity"


def observed_history(paths, sid, terminal, marker):
    """An independent oracle: rendered history plus an actual UUID redraw."""
    if marker not in terminal:
        return False
    redraw = re.compile(
        r"Full redraw completed \([^\n]*\) for conversation ([0-9a-fA-F-]*)\s*\(epoch"
    )
    selected = set()
    for path in paths:
        try:
            events = redraw.findall(Path(path).read_text(errors="replace"))
        except OSError:
            continue
        if events:
            selected.add(events[-1])
    return selected == {sid}


def main():
    if len(sys.argv) != 4 or not sys.argv[3].strip():
        raise SystemExit(
            "usage: agy-live-lifecycle.py /path/to/tmux-resurrect UUID HISTORY_TEXT"
        )
    resurrect, sid, marker = Path(sys.argv[1]).resolve(), sys.argv[2], sys.argv[3]
    if not re.fullmatch(agy.UUID, sid):
        raise SystemExit("CONVERSATION_UUID must be a full UUID")
    binary = shutil.which("agy")
    if not binary:
        raise SystemExit("agy is not installed")
    with tempfile.TemporaryDirectory(prefix="agy-lifecycle-") as temp:
        directory = Path(temp)
        socket = str(directory / "socket")
        env = dict(
            os.environ,
            TMUX=socket + ",0,0",
            TMUX_RESURRECT_DIR=str(directory / "resurrect"),
            TMUX_ASSISTANT_RESURRECT_DIR=str(directory / "state"),
        )
        test_bash = shutil.which(os.environ.get("TEST_BASH", "bash"))

        def tm(*args):
            return subprocess.check_output(
                ["tmux", "-S", socket, *args], env=env, text=True
            ).strip()

        def configure():
            for key, value in [
                ("default-shell", "/bin/bash"),
                ("default-command", "/bin/bash --noprofile --norc"),
                ("@resurrect-dir", str(directory / "resurrect")),
                ("@resurrect-processes", "false"),
                (
                    "@resurrect-hook-post-save-all",
                    shlex.join(
                        [test_bash, str(ROOT / "scripts/save-assistant-sessions.sh")]
                    ),
                ),
                (
                    "@resurrect-hook-post-restore-all",
                    shlex.join(
                        [test_bash, str(ROOT / "scripts/restore-assistant-sessions.sh")]
                    ),
                ),
            ]:
                tm("set", "-g", key, value)

        def pane_id():
            for row in tm(
                "list-panes",
                "-a",
                "-F",
                "#{pane_id}|#{window_index}|#{pane_index}|#{session_name}",
            ).splitlines():
                pane, window, index, session = row.split("|", 3)
                if (session, window, index) == (SESSION, "0", "0"):
                    return pane
            raise AssertionError("restored pane missing")

        def selected():
            rows = subprocess.check_output(
                ["ps", "-axo", "pid=", "-o", "ppid=", "-o", "args="], text=True
            ).splitlines()
            pane = pane_id()
            parent = tm("display", "-pt", pane, "#{pane_pid}")
            for row in rows:
                fields = row.strip().split(None, 2)
                if (
                    len(fields) == 3
                    and fields[1] == parent
                    and Path(fields[2].split()[0]).name == "agy"
                ):
                    terminal = tm("capture-pane", "-p", "-t", pane, "-S", "-500")
                    if observed_history(
                        agy.log_paths(fields[0], fields[2]), sid, terminal, marker
                    ):
                        return fields[0]
            return None

        def wait():
            deadline = time.monotonic() + 30
            trusted = False
            while time.monotonic() < deadline:
                terminal = tm("capture-pane", "-p", "-t", pane_id())
                if (
                    not trusted
                    and "Do you trust the contents of this project?" in terminal
                    and str(directory) in terminal
                    and "> Yes, I trust this folder" in terminal
                ):
                    # Only approve the empty directory this test created.
                    tm("send", "-t", pane_id(), "Enter")
                    trusted = True
                pid = selected()
                if pid:
                    return pid
                time.sleep(0.2)
            raise AssertionError(
                "agy did not select the requested conversation within 30 seconds"
            )

        def plugin(name):
            subprocess.run(
                ["bash", str(resurrect / "scripts" / name)],
                env=env,
                check=True,
                timeout=60,
                capture_output=True,
            )

        try:
            tm(
                "-f",
                "/dev/null",
                "new",
                "-d",
                "-s",
                SESSION,
                "-c",
                str(directory),
                "/bin/bash --noprofile --norc",
            )
            assert tm("display", "-pt", pane_id(), "#{session_name}") == SESSION
            configure()
            tm(
                "send",
                "-t",
                pane_id(),
                "-l",
                shlex.join([binary, "--effort", "high", "--conversation", sid]),
            )
            tm("send", "-t", pane_id(), "Enter")
            wait()
            plugin("save.sh")
            saved = json.loads(
                (directory / "resurrect/assistant-sessions.json").read_text()
            )["sessions"]
            assert (
                len(saved) == 1
                and saved[0]["tool"] == "agy"
                and saved[0]["session_id"] == sid
            ), saved
            assert saved[0]["cli_args"] == "--effort high", saved
            tm("kill-server")
            socket = str(directory / "restored-socket")
            env["TMUX"] = socket + ",0,0"
            tm(
                "-f",
                "/dev/null",
                "new",
                "-d",
                "-s",
                # tmux-resurrect prefix-matches session names; a suffix would
                # make it mistake this bootstrap session for the saved one.
                SESSION.replace("review-antigravity", "bootstrap-antigravity"),
                "/bin/bash --noprofile --norc",
            )
            configure()
            plugin("restore.sh")
            pid = wait()
            subprocess.run(
                [test_bash, str(ROOT / "scripts/restore-assistant-sessions.sh")],
                env=env,
                check=True,
                timeout=30,
                capture_output=True,
            )
            assert selected() == pid, "repeated restore launched another agent"
            print(
                "PASS: real agy save → tmux restart → resume exact conversation; flags retained; repeated restore skipped"
            )
        finally:
            subprocess.run(
                ["tmux", "-S", socket, "kill-server"], capture_output=True, check=False
            )


if __name__ == "__main__":
    main()
