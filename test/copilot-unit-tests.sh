#!/usr/bin/env bash
# Hermetic unit tests for GitHub Copilot CLI session discovery.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
# COPILOT_HOME is Copilot's own override for the whole ~/.copilot path, so the
# tests drive the same variable a user would (no test-only path hook).
export COPILOT_HOME="$SANDBOX/copilot-home"
# Distinct name: the sourced save script owns a global STATE_DIR of its own.
COPILOT_STATE="$COPILOT_HOME/session-state"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR" \
	"$COPILOT_STATE" "$SANDBOX/bin"

# Keep CLI-flag discovery deterministic and exercise the real help parser.
# Spellings copied verbatim from `copilot --help` (1.0.78) so the real parsers
# are exercised: `<value>` = one value, `[=name...]` = variadic.
HELP_CALLS="$SANDBOX/help-calls"
: >"$HELP_CALLS"
cat >"$SANDBOX/bin/copilot" <<EOF
#!/usr/bin/env bash
echo call >>"$HELP_CALLS"
cat <<'HELP'
  --add-dir <directory>                 Add a directory to the allowed list
  --agent <agent>                       Specify a custom agent to use
  --allow-tool[=tools...]               Tools the CLI has permission to use
  --allow-url[=urls...]                 Allow access to specific URLs or domains
  --available-tools[=tools...]          Only these tools will be available
  --connect[=sessionId]                 Connect to a remote session
  --continue                            Resume the most recent session
  --deny-tool[=tools...]                Tools the CLI does not have permission
  --deny-url[=urls...]                  Deny access to specific URLs or domains
  --excluded-tools[=tools...]           These tools will not be available
  -i, --interactive <prompt>            Start interactive mode and execute prompt
  -n, --name <name>                     Set a name for the new session
  -p, --prompt <prompt>                 Submit one non-interactive prompt
  -r, --resume[=value]                  Resume a previous session
  --secret-env-vars[=vars...]           Environment variable names to redact
  --session-id <id>                     Use a specific session ID
HELP
EOF
chmod +x "$SANDBOX/bin/copilot"
export PATH="$SANDBOX/bin:$PATH"

source "$REPO_DIR/scripts/lib-detect.sh"
source "$REPO_DIR/scripts/save-assistant-sessions.sh" >/dev/null 2>&1

PASS=0
FAIL=0

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        expected: [%s]\n        actual:   [%s]\n' \
			"$desc" "$expected" "$actual"
	fi
}

assert_missing() {
	local desc="$1" path="$2"
	if [ ! -e "$path" ]; then
		PASS=$((PASS + 1))
		printf '  [pass] %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        unexpected path: %s\n' "$desc" "$path"
	fi
}

SID_CURRENT="550e8400-e29b-41d4-a716-446655440000"
SID_STALE="11111111-2222-4333-8444-555555555555"

# Mirror the real layout: session-state/<uuid>/inuse.<pid>.lock, content = PID.
# See test/copilot-contract-test.sh, which pins this against the real binary.
# A *resumable* session: the lock names the owning PID, and session.db marks it
# as having real content. Copilot writes the lock at TUI startup but session.db
# only once the conversation has content, and `--resume` rejects a session
# without it. See test/copilot-contract-test.sh.
make_lock() {
	local sid="$1" pid="$2"
	mkdir -p "$COPILOT_STATE/$sid"
	printf '%s\n' "$pid" >"$COPILOT_STATE/$sid/inuse.$pid.lock"
	: >"$COPILOT_STATE/$sid/session.db"
}

echo "== detect_tool =="
assert_eq "bare copilot" "copilot" "$(detect_tool "copilot")"
assert_eq "copilot with path" "copilot" \
	"$(detect_tool "/opt/homebrew/bin/copilot --resume=$SID_CURRENT")"
assert_eq "node launcher with copilot script" "copilot" \
	"$(detect_tool "node /opt/homebrew/bin/copilot --no-auto-update")"
assert_eq "no false positive copilot-helper" "" \
	"$(detect_tool "/usr/local/bin/copilot-helper --watch")"
assert_eq "unrelated argument value" "" \
	"$(detect_tool "python3 worker.py --profile copilot")"

echo "== inuse lock lookup =="
make_lock "$SID_CURRENT" 1001
assert_eq "resolves UUID from inuse.<pid>.lock" "$SID_CURRENT" \
	"$(get_copilot_session 1001 "copilot")"
assert_eq "live lock wins over stale launcher argv" "$SID_CURRENT" \
	"$(get_copilot_session 1001 "copilot --session-id=$SID_STALE")"

# Copilot can leave the old session's lock behind after an in-process /resume.
# The newest valid lock for the PID is the current session.
#
# Uses a PID that does not exist so the stale-lock guard stays out of the way:
# these locks are back-dated to force a same-second mtime, and for a *live* PID
# that would (correctly) look older than the process and be rejected. PID 1006
# happens to be free in a container but taken on macOS, which made this fail
# there only.
SID_SWITCH_OLD="77777777-8888-4999-8aaa-bbbbbbbbbbbb"
SID_SWITCH_NEW="88888888-9999-4aaa-8bbb-cccccccccccc"
make_lock "$SID_SWITCH_OLD" 424242
touch -t 202601010000.00 "$COPILOT_STATE/$SID_SWITCH_OLD/inuse.424242.lock"
make_lock "$SID_SWITCH_NEW" 424242
# Give both locks the same whole-second mtime. Their high-resolution ctime
# still records creation order and must break the tie.
touch -t 202601010000.00 "$COPILOT_STATE/$SID_SWITCH_NEW/inuse.424242.lock"
assert_eq "newest lock wins when mtimes share the same second" "$SID_SWITCH_NEW" \
	"$(get_copilot_session 424242 "copilot")"

# The lookup is keyed on PID, so sessions sharing a cwd stay unambiguous and a
# lock belonging to a different Copilot is never picked up.
make_lock "$SID_STALE" 1002
assert_eq "another PID's lock is not borrowed" "$SID_STALE" \
	"$(get_copilot_session 1002 "copilot")"
assert_eq "PID with no lock resolves nothing" "" \
	"$(get_copilot_session 1003 "copilot" 0)"

echo "== resumability gate =="
# A freshly opened TUI has a lock but no session.db. Saving that UUID would make
# restore replay `--resume=<uuid>` and print "No session, task, or name matched"
# into the user's pane, so it must resolve to nothing until content exists.
SID_EMPTY="55555555-6666-4777-8888-999999999999"
mkdir -p "$COPILOT_STATE/$SID_EMPTY"
printf '%s\n' 1007 >"$COPILOT_STATE/$SID_EMPTY/inuse.1007.lock"
assert_eq "session with no session.db is not saved" "" \
	"$(get_copilot_session 1007 "copilot" 0)"
: >"$COPILOT_STATE/$SID_EMPTY/session.db"
assert_eq "same session resolves once session.db appears" "$SID_EMPTY" \
	"$(get_copilot_session 1007 "copilot" 0)"

echo "== lock integrity =="
mkdir -p "$COPILOT_STATE/not-a-uuid"
printf '%s\n' 1004 >"$COPILOT_STATE/not-a-uuid/inuse.1004.lock"
assert_eq "non-UUID session directory is ignored" "" \
	"$(get_copilot_session 1004 "copilot" 0)"

SID_MISMATCH="22222222-3333-4444-8555-666666666666"
mkdir -p "$COPILOT_STATE/$SID_MISMATCH"
printf '%s\n' 9999 >"$COPILOT_STATE/$SID_MISMATCH/inuse.1005.lock"
assert_eq "lock whose content disagrees with its name is ignored" "" \
	"$(get_copilot_session 1005 "copilot" 0)"

echo "== stale lock from a recycled PID =="
# A SIGKILLed Copilot leaves its lock behind; if the PID is later recycled, the
# stale lock must not map the new process onto the dead session. This needs a
# PID that is genuinely alive so get_process_start_epoch() returns something to
# compare against — the test shell itself is the simplest such process.
LIVE_PID=$$
SID_RECYCLED="33333333-4444-4555-8666-777777777777"
make_lock "$SID_RECYCLED" "$LIVE_PID"
assert_eq "lock newer than the process is accepted" "$SID_RECYCLED" \
	"$(get_copilot_session "$LIVE_PID" "copilot" 0)"
touch -t 200001010000 "$COPILOT_STATE/$SID_RECYCLED/inuse.$LIVE_PID.lock"
assert_eq "lock predating the process is rejected as stale" "" \
	"$(get_copilot_session "$LIVE_PID" "copilot" 0)"
rm -rf "$COPILOT_STATE/$SID_RECYCLED"

echo "== argv fallback =="
assert_eq "--session-id=<uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot --session-id=$SID_CURRENT")"
assert_eq "--session-id <uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot --session-id $SID_CURRENT")"
assert_eq "--resume=<uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot --resume=$SID_CURRENT")"
assert_eq "-r <uuid>" "$SID_CURRENT" \
	"$(get_copilot_session 3001 "copilot -r $SID_CURRENT")"
assert_eq "reject non-UUID resume selector" "" \
	"$(get_copilot_session 3001 "copilot --resume latest-session")"
assert_eq "deferred argv fallback can be disabled" "" \
	"$(get_copilot_session 3001 "copilot --resume=$SID_CURRENT" 0)"

# `copilot --session-id <uuid>` puts a UUID in argv at launch, long before the
# session can be resumed. The fallback must apply the same gate as the lock path
# or it re-introduces exactly the unresumable saves the gate exists to prevent.
SID_ARGV_EMPTY="99999999-aaaa-4bbb-8ccc-dddddddddddd"
mkdir -p "$COPILOT_STATE/$SID_ARGV_EMPTY"
assert_eq "argv fallback declines a session with no session.db" "" \
	"$(get_copilot_session 3002 "copilot --session-id=$SID_ARGV_EMPTY")"
: >"$COPILOT_STATE/$SID_ARGV_EMPTY/session.db"
assert_eq "argv fallback accepts it once session.db appears" "$SID_ARGV_EMPTY" \
	"$(get_copilot_session 3002 "copilot --session-id=$SID_ARGV_EMPTY")"

echo "== state root resolution =="
# Deprecated but still honored: --config-dir moves the whole state root, and a
# session launched with it writes nothing under ~/.copilot.
SID_CFGDIR="44444444-5555-4666-8777-888888888888"
CFG_ROOT="$SANDBOX/alt-config"
mkdir -p "$CFG_ROOT/session-state/$SID_CFGDIR"
printf '%s\n' 1006 >"$CFG_ROOT/session-state/$SID_CFGDIR/inuse.1006.lock"
: >"$CFG_ROOT/session-state/$SID_CFGDIR/session.db"
assert_eq "--config-dir <path> relocates the state root" \
	"$CFG_ROOT/session-state" \
	"$(copilot_session_state_dir "copilot --config-dir $CFG_ROOT --allow-all")"
assert_eq "--config-dir=<path> relocates the state root" \
	"$CFG_ROOT/session-state" \
	"$(copilot_session_state_dir "copilot --config-dir=$CFG_ROOT")"
# `ps` flattens the quoting, so a root with spaces arrives as several tokens.
CFG_SPACED="$SANDBOX/My State Dir"
SID_SPACED="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
mkdir -p "$CFG_SPACED/session-state/$SID_SPACED"
printf '%s\n' 1008 >"$CFG_SPACED/session-state/$SID_SPACED/inuse.1008.lock"
: >"$CFG_SPACED/session-state/$SID_SPACED/session.db"
assert_eq "--config-dir with spaces is not truncated" \
	"$CFG_SPACED/session-state" \
	"$(copilot_session_state_dir "copilot --config-dir $CFG_SPACED --allow-all")"
assert_eq "lock is found under a spaced --config-dir" "$SID_SPACED" \
	"$(get_copilot_session 1008 "copilot --config-dir $CFG_SPACED" 0)"

assert_eq "lock is found under --config-dir" "$SID_CFGDIR" \
	"$(get_copilot_session 1006 "copilot --config-dir $CFG_ROOT" 0)"
assert_eq "same PID resolves nothing without --config-dir" "" \
	"$(get_copilot_session 1006 "copilot" 0)"

assert_eq "COPILOT_HOME overrides the whole ~/.copilot path" \
	"$COPILOT_HOME/session-state" "$(copilot_session_state_dir)"
assert_eq "defaults to ~/.copilot when COPILOT_HOME is unset" \
	"$HOME/.copilot/session-state" \
	"$(COPILOT_HOME= copilot_session_state_dir)"
assert_eq "missing state root resolves nothing, quietly" "" \
	"$(COPILOT_HOME="$SANDBOX/absent" get_copilot_session 1001 "copilot" 0)"

# A tmux hook does not inherit the interactive shell's environment, so a
# COPILOT_HOME exported from a profile is invisible to the save hook. On
# Linux/WSL it is read back from the Copilot process's own environment.
if [ -r "/proc/$$/environ" ]; then
	PROC_ROOT="$SANDBOX/proc-home"
	SID_PROCENV="66666666-7777-4888-8999-aaaaaaaaaaaa"
	mkdir -p "$PROC_ROOT/session-state/$SID_PROCENV"
	# A live child that carries COPILOT_HOME in its environment, as a Copilot
	# launched from a shell that exported it would.
	# Long-lived and explicitly killed afterwards: a short sleep made this
	# depend on the suite reaching the assertion before it expired, which it
	# did not under load in CI.
	env COPILOT_HOME="$PROC_ROOT" sleep 300 &
	ENV_PID=$!
	disown "$ENV_PID" 2>/dev/null || true
	printf '%s\n' "$ENV_PID" >"$PROC_ROOT/session-state/$SID_PROCENV/inuse.$ENV_PID.lock"
	: >"$PROC_ROOT/session-state/$SID_PROCENV/session.db"
	assert_eq "COPILOT_HOME is read from the Copilot process environment" \
		"$SID_PROCENV" "$(COPILOT_HOME= get_copilot_session "$ENV_PID" "copilot" 0)"
	assert_eq "--config-dir still outranks the process environment" \
		"$CFG_ROOT/session-state" \
		"$(copilot_session_state_dir "copilot --config-dir $CFG_ROOT" "$ENV_PID")"
	# kill without wait: bash re-raises the signal to itself when waiting on a
	# job that a signal terminated.
	kill "$ENV_PID" 2>/dev/null
else
	printf '  [skip] COPILOT_HOME from process env (no /proc on this platform)\n'
fi

echo "== unresolved candidate is non-fatal under set -e =="
UNRESOLVED_PARTS="$SANDBOX/unresolved-parts"
UNRESOLVED_CACHE="$SANDBOX/unresolved-cache"
: >"$UNRESOLVED_PARTS"
: >"$UNRESOLVED_CACHE"
if (
	set -e
	resolve_pane_candidates \
		"test:1.1" "/tmp" "/dev/ttys001" \
		$'copilot\0379999\037copilot' $'\037' 0 \
		"$UNRESOLVED_CACHE" "$UNRESOLVED_PARTS"
); then
	PASS=$((PASS + 1))
	printf '  [pass] unresolved Copilot candidate does not abort save\n'
else
	FAIL=$((FAIL + 1))
	printf '  [FAIL] unresolved Copilot candidate aborted save\n'
fi
assert_eq "unresolved candidate emits no session entry" "0" \
	"$(wc -l <"$UNRESOLVED_PARTS" | tr -d ' ')"

echo "== extract_cli_args =="
unset _SESSION_FLAGS_copilot
assert_eq "strip session selectors and one-shot prompt" \
	"--allow-all --autopilot" \
	"$(extract_cli_args copilot "copilot --allow-all --session-id=$SID_CURRENT --autopilot -p run once --model gpt-5.6-sol")"
assert_eq "multi-word long prompt cannot leak positional args" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-all --prompt add a health check endpoint --autopilot")"
assert_eq "flags before equals-form prompt are preserved" \
	"--allow-all --autopilot" \
	"$(extract_cli_args copilot "copilot --allow-all --autopilot --prompt=add a health check")"
assert_eq "multi-word interactive prompt cannot leak positional args" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-all --interactive add a health check --autopilot")"
assert_eq "short interactive prompt cannot leak positional args" \
	"--allow-all --autopilot" \
	"$(extract_cli_args copilot "copilot --allow-all --autopilot -i fix the login bug --model ignored")"
assert_eq "strip resume and connect selectors" "--no-remote" \
	"$(extract_cli_args copilot "copilot --connect=remote --no-remote --resume $SID_CURRENT")"
assert_eq "preserve operational flags" \
	"--allow-all --autopilot --max-autopilot-continues 20" \
	"$(extract_cli_args copilot "copilot --allow-all --autopilot --max-autopilot-continues 20")"

# `copilot --name x --resume=<id>` is rejected outright ("cannot be used with"),
# so a named session must lose its name to be resumable at all.
assert_eq "strip --name so it cannot collide with --resume" "--allow-all" \
	"$(extract_cli_args copilot "copilot --name nightly-triage --allow-all")"
assert_eq "strip short -n too" "--allow-all" \
	"$(extract_cli_args copilot "copilot -n nightly-triage --allow-all")"

echo "== flattened multi-word values =="
# Copilot takes zero positional arguments, so replaying the tail of a value
# whose quoting `ps` erased makes it exit with "too many arguments". Options
# that cannot be reconstructed are dropped instead.
assert_eq "drop an option whose value lost its quoting" "--allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir /tmp/My Project --allow-all")"
assert_eq "single-token value is unambiguous and kept" \
	"--add-dir /tmp/project --allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir /tmp/project --allow-all")"
assert_eq "variadic options keep all their values" \
	"--allow-tool shell write --allow-all" \
	"$(extract_cli_args copilot "copilot --allow-tool shell write --allow-all")"
assert_eq "multi-word --name leaves no stray positional" "--allow-all" \
	"$(extract_cli_args copilot "copilot --name my nightly run --allow-all")"
assert_eq "flattened value at end of argv" "--autopilot" \
	"$(extract_cli_args copilot "copilot --autopilot --agent my custom agent")"

# `--name="my feature"` reaches ps as `--name=my feature`: the bare run is only
# one token, but the equals already bounded the value, so the extra word can
# only be a lost fragment.
assert_eq "drop equals-form option whose value lost its quoting" "--allow-all" \
	"$(extract_cli_args copilot "copilot --name=my feature --allow-all")"
assert_eq "drop equals-form --add-dir with a space in the path" "--allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir=/tmp/My Project --allow-all")"
assert_eq "drop equals-form variadic option with flattened values" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-tool=shell write --allow-all")"
assert_eq "equals-form value without spaces is kept" \
	"--add-dir=/tmp/project --allow-all" \
	"$(extract_cli_args copilot "copilot --add-dir=/tmp/project --allow-all")"

# Argv is data: a quoted wildcard must not be expanded against the save hook's
# cwd and persisted as whatever files happen to live there.
assert_eq "wildcard option value is not glob-expanded" \
	"--allow-tool * --allow-all" \
	"$(cd "$SANDBOX/bin" && extract_cli_args copilot "copilot --allow-tool * --allow-all")"
assert_eq "variadic list detected from real --help spelling" \
	"--allow-tool --allow-url --available-tools --deny-tool --deny-url --excluded-tools --secret-env-vars" \
	"$(_copilot_variadic_flags)"

# `--deny-tool='shell(git push)'` reaches ps as `--deny-tool=shell(git push)`.
# Being variadic does not make that reconstructable: the `=` already delimited
# the value, and Copilot reads the fragment as a positional.
assert_eq "equals-form variadic value is not exempt" "--allow-all" \
	"$(extract_cli_args copilot "copilot --deny-tool=shell(git push) --allow-all")"
assert_eq "space-form variadic value is still exempt" \
	"--deny-tool shell write --allow-all" \
	"$(extract_cli_args copilot "copilot --deny-tool shell write --allow-all")"

echo "== prompt-only options =="
# Copilot refuses --attachment on an interactive resume, and the prompt
# truncation only reaches flags written after the prompt.
assert_eq "strip --attachment placed before the prompt" "--allow-all" \
	"$(extract_cli_args copilot "copilot --allow-all --attachment /tmp/a.png -p summarize this")"
assert_eq "strip --attachment with no prompt at all" "--allow-all" \
	"$(extract_cli_args copilot "copilot --attachment /tmp/a.png --allow-all")"
assert_eq "strip equals-form --attachment" "--allow-all" \
	"$(extract_cli_args copilot "copilot --attachment=/tmp/a.png --allow-all")"

echo "== hidden launch-mode selectors =="
# --worktree/-w and --cloud never appear in --help, so discovery cannot learn
# them, yet Copilot refuses each one alongside --resume.
assert_eq "strip --worktree" "--allow-all" \
	"$(extract_cli_args copilot "copilot --worktree --allow-all")"
assert_eq "strip --worktree=<name>" "--allow-all" \
	"$(extract_cli_args copilot "copilot --worktree=feature-x --allow-all")"
assert_eq "strip short -w" "--allow-all" \
	"$(extract_cli_args copilot "copilot -w --allow-all")"
assert_eq "strip --cloud" "--experimental --allow-all" \
	"$(extract_cli_args copilot "copilot --experimental --cloud --allow-all")"

echo "== --help probe cost =="
# The save hook runs every few minutes: discovery must not exec the CLI once per
# pane. The caches live in shell vars, and extract_cli_args runs in a $()
# subshell, so they only pay off when warmed in the parent shell.
unset _TOOL_HELP_copilot _SESSION_FLAGS_copilot _COPILOT_VARIADIC_FLAGS
: >"$HELP_CALLS"
_warm_session_discovery "$(printf 'pane\tcopilot\t1\targs\n')"
for _ in 1 2 3 4 5 6 7 8; do
	extract_cli_args copilot "copilot --allow-all --deny-tool a" >/dev/null
done
assert_eq "one --help exec per save, not per pane" "1" \
	"$(wc -l <"$HELP_CALLS" | tr -d ' ')"

echo
echo "copilot unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
