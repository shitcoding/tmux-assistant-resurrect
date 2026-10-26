#!/usr/bin/env python3
"""Real agy + real tmux + production save/restore hooks, without login.

Pins actual log-file ownership, help and argv. Selection events are explicitly
seeded fixtures: unauthenticated agy cannot create a resumable conversation.
This tests save/restore routing, not authenticated recovery; use
agy-live-lifecycle.py for that. No user server, credentials or prompts are used.
"""

import importlib.util
import json
import os
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "agy_session", ROOT / "scripts/py/agy_session.py"
)
agy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agy)
A = "819ede29-d40e-41d8-8e91-e7cd0f8f7ea8"
B = "e8d5d5bb-d278-44cc-9ba3-79b6896dce97"
SESSION = "timvw/tmux-assistant-resurrect - pr-109 - review-antigravity"


def wait_for(check, message):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(message)


def main():
    binary = shutil.which("agy")
    if not binary:
        raise SystemExit("agy is required (test/install-agy.sh /path/to/bin)")
    test_bash = shutil.which(os.environ.get("TEST_BASH", "bash"))
    with tempfile.TemporaryDirectory(
        prefix="agy-e2e-", ignore_cleanup_errors=True
    ) as temp:
        directory = Path(temp).resolve()
        home = directory / "home"
        home.mkdir()
        workspace = directory / "workspace"
        workspace.mkdir()
        (workspace / "My Logs").mkdir()
        socket = str(directory / "socket")
        env = dict(
            os.environ,
            HOME=str(home),
            XDG_CONFIG_HOME=str(home / ".config"),
            XDG_DATA_HOME=str(home / ".local/share"),
            XDG_STATE_HOME=str(home / ".local/state"),
            TMUX=socket + ",0,0",
            TMUX_RESURRECT_DIR=str(directory / "resurrect"),
            TMUX_ASSISTANT_RESURRECT_DIR=str(directory / "state"),
        )
        # Never inherit a configured provider or credentials from the caller.
        for key in list(env):
            if key.startswith(("GOOGLE_", "GEMINI_", "AGY_")):
                env.pop(key)

        def tm(*args):
            return subprocess.check_output(
                ["tmux", "-S", socket, *args], env=env, text=True, timeout=10
            ).strip()

        def new_server():
            pane = tm(
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                SESSION,
                "-c",
                str(workspace),
                "-P",
                "-F",
                "#{pane_id}",
                "/bin/bash --noprofile --norc",
            )
            tm("set", "-g", "default-shell", "/bin/bash")
            tm("set", "-g", "default-command", "/bin/bash --noprofile --norc")
            tm("set", "-g", "@assistant-resurrect-relaunch", "off")
            assert tm("display", "-p", "-t", pane, "#{session_name}") == SESSION
            return pane

        def launch(pane, *args):
            tm("send-keys", "-t", pane, "-l", shlex.join([binary, *args]))
            tm("send-keys", "-t", pane, "Enter")

        def processes(pane):
            root = int(tm("display", "-pt", pane, "#{pane_pid}"))
            rows = []
            for line in subprocess.check_output(
                ["ps", "-eo", "pid=", "-o", "ppid=", "-o", "args="], text=True
            ).splitlines():
                fields = line.strip().split(None, 2)
                if len(fields) == 3:
                    rows.append((int(fields[0]), int(fields[1]), fields[2]))
            owned = {root}
            while True:
                children = {pid for pid, parent, _ in rows if parent in owned}
                if children <= owned:
                    break
                owned |= children
            return [
                (pid, args)
                for pid, _, args in rows
                if pid in owned and Path(args.split()[0]).name == "agy"
            ]

        def hook(name):
            result = subprocess.run(
                [test_bash, str(ROOT / "scripts" / name)],
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            assert result.returncode == 0, result.stderr

        def saved():
            return json.loads(
                (directory / "resurrect/assistant-sessions.json").read_text()
            )["sessions"]

        stopped = set()

        def resume_writers():
            for pid in stopped:
                try:
                    os.kill(pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
            stopped.clear()

        try:
            help_text = subprocess.check_output(
                [binary, "--help"], env=env, stderr=subprocess.STDOUT, text=True
            )
            for flag in [
                "--conversation",
                "--log-file",
                "--prompt-interactive",
                "--sandbox",
                "--effort",
            ]:
                assert flag in help_text, f"upstream help no longer advertises {flag}"
            p1 = new_server()
            p2 = tm(
                "split-window",
                "-t",
                p1,
                "-c",
                str(workspace),
                "-P",
                "-F",
                "#{pane_id}",
                "/bin/bash --noprofile --norc",
            )
            # Both instances share a workspace; their open logs must stay distinct.
            launch(p1, "--log-file", "My Logs/one.log", "--sandbox", "--effort", "high")
            launch(p2, "--log-file", "./My Logs/two.log", "--effort", "low")
            owners = [
                wait_for(lambda p=p: processes(p), "real agy did not start")[0]
                for p in [p1, p2]
            ]
            logs = [workspace / "My Logs/one.log", workspace / "My Logs/two.log"]
            for (pid, args), log in zip(owners, logs):
                wait_for(
                    lambda: log in [Path(p) for p in agy.log_paths(pid, args)],
                    "PID-owned custom log not found",
                )
            assert owners[0][0] != owners[1][0]
            hook("save-assistant-sessions.sh")
            assert (
                saved() == []
            ), "unauthenticated, unselected panes must not invent a session"
            print(
                "PASS: real binary help, distinct PID-owned relative logs, no fabricated session"
            )

            # Deliberate fixtures; these are not claimed as real upstream selection events.
            # Freeze the real writers while seeding: a later login-screen
            # redraw would legitimately clear the fixture selection.
            for pid, _ in owners:
                os.kill(pid, signal.SIGSTOP)
                stopped.add(pid)
            for log, sid in zip(logs, [A, B]):
                with log.open("a") as stream:
                    stream.write(f"\nStreaming conversation {sid}\n")
            hook("save-assistant-sessions.sh")
            entries = saved()
            assert len(entries) == 2, (
                entries,
                (directory / "resurrect/assistant-save.log").read_text(),
            )
            by_id = {entry["session_id"]: entry for entry in entries}
            assert by_id[A]["cli_args"] == "--sandbox --effort high", entries
            assert by_id[B]["cli_args"] == "--effort low", entries
            assert by_id[A]["pane_index"] != by_id[B]["pane_index"]
            with logs[0].open("a") as stream:
                stream.write(
                    "Full redraw completed (RerenderAll) for conversation  (epoch 0, items 1)\n"
                )
            hook("save-assistant-sessions.sh")
            assert [entry["session_id"] for entry in saved()] == [B]
            with logs[0].open("a") as stream:
                stream.write(f"Starting conversation update stream for {A}\n")
            hook("save-assistant-sessions.sh")
            print(
                "PASS: seeded selections remain per pane; empty selection clears; sandbox survives"
            )

            # Restart tmux and reconstruct the layout, then exercise the real
            # assistant restore hook against real CLIs at their login screens.
            resume_writers()
            tm("kill-server")
            # The dying server can still unlink its socket after kill-server
            # returns. Use a fresh socket for the new server lifetime.
            socket = str(directory / "restored-socket")
            env["TMUX"] = socket + ",0,0"
            p1 = new_server()
            p2 = tm(
                "split-window",
                "-t",
                p1,
                "-c",
                str(workspace),
                "-P",
                "-F",
                "#{pane_id}",
                "/bin/bash --noprofile --norc",
            )
            hook("restore-assistant-sessions.sh")
            restored = []
            for pane, sid, flags in [
                (p1, A, ["--sandbox", "--effort high"]),
                (p2, B, ["--effort low"]),
            ]:
                pid, args = wait_for(
                    lambda p=pane: processes(p), "restore did not launch agy"
                )[0]
                assert f"--conversation {sid}" in args, args
                assert all(flag in args for flag in flags), args
                assert "--log-file" not in args, args
                restored.append(pid)
            hook("restore-assistant-sessions.sh")
            assert [processes(p)[0][0] for p in [p1, p2]] == restored
            assert all(len(processes(p)) == 1 for p in [p1, p2])
            print(
                "PASS: tmux restart → real agy argv routed to each pane; repeated restore does not relaunch"
            )
        finally:
            resume_writers()
            subprocess.run(
                ["tmux", "-S", socket, "kill-server"], capture_output=True, check=False
            )


if __name__ == "__main__":
    main()
