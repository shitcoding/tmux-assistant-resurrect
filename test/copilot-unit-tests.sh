#!/usr/bin/env bash
# Hermetic unit tests for GitHub Copilot CLI session discovery.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

export TMUX_RESURRECT_DIR="$SANDBOX/resurrect"
export TMUX_ASSISTANT_RESURRECT_DIR="$SANDBOX/state"
export COPILOT_SESSION_STATE_DIR="$SANDBOX/copilot-state"
export COPILOT_PROC_ROOT="$SANDBOX/proc"
mkdir -p "$TMUX_RESURRECT_DIR" "$TMUX_ASSISTANT_RESURRECT_DIR" \
	"$COPILOT_SESSION_STATE_DIR" "$COPILOT_PROC_ROOT" "$SANDBOX/bin"

# Keep CLI-flag discovery deterministic and exercise the real help parser.
cat >"$SANDBOX/bin/copilot" <<'EOF'
#!/usr/bin/env bash
cat <<'HELP'
  --connect[=sessionId]                 Connect to a remote session
  --continue                            Resume the most recent session
  -i, --interactive <prompt>            Start interactive mode and execute prompt
  -p, --prompt <prompt>                 Submit one non-interactive prompt
  -r, --resume[=value]                  Resume a previous session
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
mkdir -p "$COPILOT_SESSION_STATE_DIR/$SID_CURRENT"
: >"$COPILOT_SESSION_STATE_DIR/$SID_CURRENT/session.db"

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

echo "== Linux /proc open-file lookup =="
mkdir -p "$COPILOT_PROC_ROOT/1001/fd"
ln -s "$COPILOT_SESSION_STATE_DIR/$SID_CURRENT/session.db" \
	"$COPILOT_PROC_ROOT/1001/fd/9"

LSOF_MARKER="$SANDBOX/lsof-called"
cat >"$SANDBOX/bin/fake-lsof" <<EOF
#!/usr/bin/env bash
touch "$LSOF_MARKER"
printf 'p%s\\n' "\${3:-unknown}"
printf 'n%s\\n' "\${COPILOT_TEST_LSOF_PATH:-}"
EOF
chmod +x "$SANDBOX/bin/fake-lsof"
export COPILOT_LSOF="$SANDBOX/bin/fake-lsof"

export COPILOT_PLATFORM="Linux"
assert_eq "Linux resolves UUID from open session.db" "$SID_CURRENT" \
	"$(get_copilot_session 1001 "copilot")"
assert_eq "open session.db wins over stale launcher argv" "$SID_CURRENT" \
	"$(get_copilot_session 1001 "copilot --session-id=$SID_STALE")"
assert_missing "Linux lookup does not invoke lsof" "$LSOF_MARKER"

mkdir -p "$COPILOT_PROC_ROOT/1002/fd" "$SANDBOX/not-copilot/$SID_STALE"
: >"$SANDBOX/not-copilot/$SID_STALE/session.db"
ln -s "$SANDBOX/not-copilot/$SID_STALE/session.db" \
	"$COPILOT_PROC_ROOT/1002/fd/7"
assert_eq "Linux ignores session.db outside Copilot state root" "" \
	"$(get_copilot_session 1002 "copilot")"

echo "== macOS lsof lookup =="
rm -f "$LSOF_MARKER"
export COPILOT_PLATFORM="Darwin"
export COPILOT_TEST_LSOF_PATH="$COPILOT_SESSION_STATE_DIR/$SID_CURRENT/session.db"
assert_eq "macOS resolves UUID from lsof output" "$SID_CURRENT" \
	"$(get_copilot_session 2001 "copilot")"
if [ -e "$LSOF_MARKER" ]; then
	PASS=$((PASS + 1))
	printf '  [pass] macOS lookup invokes lsof\n'
else
	FAIL=$((FAIL + 1))
	printf '  [FAIL] macOS lookup did not invoke lsof\n'
fi

echo "== batched macOS lsof snapshot =="
rm -f "$LSOF_MARKER"
unset COPILOT_LSOF_SNAPSHOT COPILOT_LSOF_SNAPSHOT_READY
prime_copilot_open_files $'pane\tcopilot\t2001\tcopilot\t/tmp\t/dev/ttys001'
assert_eq "batched lsof snapshot resolves matching PID" "$SID_CURRENT" \
	"$(get_copilot_session 2001 "copilot")"
if [ -e "$LSOF_MARKER" ]; then
	PASS=$((PASS + 1))
	printf '  [pass] batched lsof snapshot invoked lsof once\n'
else
	FAIL=$((FAIL + 1))
	printf '  [FAIL] batched lsof snapshot did not invoke lsof\n'
fi
rm -f "$LSOF_MARKER"
assert_eq "cached lookup does not invoke lsof again" "$SID_CURRENT" \
	"$(get_copilot_session 2001 "copilot")"
assert_missing "cached lookup reused the exported snapshot" "$LSOF_MARKER"
unset COPILOT_LSOF_SNAPSHOT COPILOT_LSOF_SNAPSHOT_READY

echo "== argv fallback =="
rm -rf "$COPILOT_PROC_ROOT/3001"
export COPILOT_PLATFORM="Linux"
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

echo "== native Windows =="
rm -f "$LSOF_MARKER"
export COPILOT_PLATFORM="Windows_NT"
assert_eq "native Windows returns no open-file mapping" "" \
	"$(get_copilot_session 1001 "copilot" 0)"
assert_missing "native Windows does not invoke Unix lsof" "$LSOF_MARKER"

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

echo
echo "copilot unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
