#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

# Source shared library (detect_tool, pane_has_assistant, posix_quote,
# split_pane_target, resolve_tmux_pane_id)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

# Follow tmux-resurrect's own save-dir resolution (resurrect_data_dir in
# lib-detect.sh) so we read the sidecar from wherever resurrect saved it.
RESURRECT_DIR="$(resurrect_data_dir)"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"

# Rotate log: keep only the most recent 500 lines
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

if [ ! -f "$INPUT_FILE" ]; then
	log "no saved sessions found at $INPUT_FILE"
	exit 0
fi

# Read saved sessions
sessions=$(jq -r '.sessions // []' "$INPUT_FILE")
count=$(echo "$sessions" | jq 'length')

if [ "$count" -eq 0 ]; then
	log "no assistant sessions to restore"
	exit 0
fi

# Wait for panes to be fully initialized after resurrect restore
sleep 2

log "restoring $count assistant session(s)..."

# Use a temp file to avoid subshell variable scoping issues with pipes
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT INT TERM
echo "$sessions" | jq -c '.[]' >"$tmpfile"

restored=0
while read -r entry; do
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')
	cli_args=$(echo "$entry" | jq -r '.cli_args // empty')
	model=$(echo "$entry" | jq -r '.model // empty')
	env_json=$(echo "$entry" | jq -c '.env // {}')
	copilot_home=$(echo "$entry" | jq -r '.copilot_home // empty')

	# Resolve the saved pane to a live tmux pane id (%N), which every tmux
	# command below then targets. The saved "session:window.pane" string is a
	# display label, NOT a usable tmux target: session names may contain ':'
	# and '.' (tmux 3.7+ keeps them; 3.4-3.6 rewrote them to '_'), and both are
	# reserved by the target grammar. See resolve_tmux_pane_id() in
	# lib-detect.sh for why neither `-t name` nor `-t =name` can be trusted.
	#
	# Prefer the saved components; fall back to splitting the label for
	# sidecars written before those fields existed (the file is a cache
	# regenerated on every save, so the only path that hits this is
	# save -> upgrade -> restore).
	tmux_session=$(echo "$entry" | jq -r '.session_name // empty')
	window_index=$(echo "$entry" | jq -r '.window_index // empty')
	pane_index=$(echo "$entry" | jq -r '.pane_index // empty')
	if [ -z "$tmux_session" ] || [ -z "$window_index" ] || [ -z "$pane_index" ]; then
		if ! split_pane_target "$pane"; then
			log "malformed pane target '$pane', skipping"
			continue
		fi
		tmux_session="$PANE_TARGET_SESSION"
		window_index="$PANE_TARGET_WINDOW"
		pane_index="$PANE_TARGET_INDEX"
	fi

	pane_id=$(resolve_tmux_pane_id "$tmux_session" "$window_index" "$pane_index" || true)
	if [ -z "$pane_id" ]; then
		log "pane $pane does not exist (session '$tmux_session', window $window_index, pane $pane_index), skipping"
		continue
	fi

	# Wait for at least one client to attach to this pane's session before
	# replaying. TUI tools that query the terminal at startup (OSC 11
	# background-color for theme detection, cursor-shape, hyperlinks, etc.)
	# get a null response if no terminal is attached when the query fires
	# — tmux silently drops the query because there's no client to forward
	# it to. crossterm-based tools cache that null response in a OnceLock
	# and never retry, so a single bad startup permanently locks the tool
	# to its fallback state for the lifetime of the process. Symptom seen
	# in the wild: codex's diff palette permanently dark on a light
	# terminal after every reboot, requiring a manual `codex resume` to
	# clear.
	#
	# Poll every 100ms, cap at 5s so we don't hang the rest of the restore
	# if the user never attaches a client. In normal boot flows where a
	# kitty/wezterm/etc auto-attaches via `tmux new-session -A`, the wait
	# resolves in < 200ms.
	#
	# `list-clients` takes a session target, and the session name cannot be one
	# (see above) — but a pane id resolves to its own session, so target that.
	client_wait=0
	while [ "$(tmux list-clients -t "$pane_id" 2>/dev/null | wc -l)" -eq 0 ] && [ $client_wait -lt 50 ]; do
		sleep 0.1
		client_wait=$((client_wait + 1))
	done
	if [ $client_wait -ge 50 ]; then
		log "no client attached to session '$tmux_session' after 5s; replaying anyway (TUI startup queries may miss responses)"
	fi

	# Guard 1: skip if the pane is not running a shell.
	# After tmux-resurrect restore, panes should be running a shell (bash, zsh,
	# etc.). If something else is running (e.g., the user manually started vim,
	# or @resurrect-processes restored a non-assistant program), injecting
	# send-keys would feed commands into the wrong program.
	pane_cmd=$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null || true)
	# Strip leading '-' from login shells (e.g., -bash -> bash, -zsh -> zsh)
	pane_cmd="${pane_cmd#-}"
	case "$pane_cmd" in
	bash | zsh | fish | sh | dash | ksh | tcsh | csh | nu) ;;
	*)
		log "pane $pane is running '$pane_cmd' (not a shell), skipping"
		continue
		;;
	esac

	# Guard 2: skip if the pane already has a running assistant (e.g., if
	# @resurrect-processes launched it, or user restarted manually).
	# Uses the same full tree walk + detect_tool() as the save script to
	# catch exec-replaced shells, wrappers (npx, env, direnv), and deep
	# process chains.
	pane_shell_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null || true)
	if [ -n "$pane_shell_pid" ]; then
		existing=$(pane_has_assistant "$pane_shell_pid" || true)
		if [ -n "$existing" ]; then
			log "pane $pane already has a running assistant (pid $existing), skipping"
			continue
		fi
	fi

	# Build env prefix: only restore user-configured vars from
	# @assistant-resurrect-capture-env. Exclude built-in vars (tmux_pane, shell)
	# which would be stale or already present in the shell environment.
	env_prefix=""
	if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
		capture_env=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
		for var in $capture_env; do
			# Validate var name to prevent shell injection via crafted tmux option
			if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				log "skipping invalid env var name: $var"
				continue
			fi
			val=$(echo "$env_json" | jq -r --arg k "$var" '.[$k] // empty')
			if [ -n "$val" ]; then
				env_prefix="${env_prefix}${var}=$(posix_quote "$val") "
			fi
		done
	fi

	# Build the resume command for each tool.
	# Apply posix_quote to session_id defensively — IDs are alphanumeric in
	# practice, but a corrupt/tampered sidecar JSON could inject shell commands.
	safe_sid=$(posix_quote "$session_id")

	# Quote cli_args tokens and disable glob expansion while splitting, so
	# args like "claude-opus-4-6[1m]" are treated literally.
	safe_cli_args=""
	if [ -n "$cli_args" ]; then
		set -f
		for _arg in $cli_args; do
			safe_cli_args="${safe_cli_args} $(posix_quote "$_arg")"
		done
		set +f
	fi

	# Add --model from the sidecar model field if not already in cli_args.
	# Only for Claude — OpenCode and Codex don't support --model.
	safe_model_arg=""
	if [ -n "$model" ] && [ "$tool" = "claude" ]; then
		case "$cli_args" in
		*--model*) ;;
		*) safe_model_arg=" --model $(posix_quote "$model")" ;;
		esac
	fi

	resume_cmd=""
	case "$tool" in
	claude)
		if [ -n "$safe_cli_args" ] || [ -n "$safe_model_arg" ]; then
			resume_cmd="command claude${safe_cli_args}${safe_model_arg} --resume ${safe_sid}"
		else
			resume_cmd="command claude --resume ${safe_sid}"
		fi
		;;
	copilot)
		copilot_cmd="command copilot"
		if [ -n "$copilot_home" ]; then
			# `VAR=value command ...` is not valid csh/tcsh syntax. `env`
			# preserves aliases/functions bypass while working in every shell
			# accepted by the restore whitelist.
			copilot_cmd="env COPILOT_HOME=$(shell_quote "$pane_cmd" "$copilot_home") copilot"
		fi
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="${copilot_cmd}${safe_cli_args} --resume=${safe_sid}"
		else
			resume_cmd="${copilot_cmd} --resume=${safe_sid}"
		fi
		;;
	opencode)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command opencode${safe_cli_args} -s ${safe_sid}"
		else
			resume_cmd="command opencode -s ${safe_sid}"
		fi
		;;
	codex)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command codex${safe_cli_args} resume ${safe_sid}"
		else
			resume_cmd="command codex resume ${safe_sid}"
		fi
		;;
	pi)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command pi${safe_cli_args} --session ${safe_sid}"
		else
			resume_cmd="command pi --session ${safe_sid}"
		fi
		;;
	omp)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command omp${safe_cli_args} --resume ${safe_sid}"
		else
			resume_cmd="command omp --resume ${safe_sid}"
		fi
		;;
	grok)
		# Deliberately ignore cli_args for grok. Resuming reloads the
		# session's own model/agent/context from disk, and grok's prompt is a
		# positional argument — replaying captured args risks re-submitting a
		# stale prompt into the resumed session. A clean `grok --resume <id>`
		# is the correct restore. The generic cwd `cd` below still runs first,
		# which also lets grok locate the (cwd-scoped) session directory.
		resume_cmd="command grok --resume ${safe_sid}"
		;;
	*)
		log "unknown tool '$tool' for pane $pane, skipping"
		continue
		;;
	esac

	# Prepend env vars if present
	if [ -n "$env_prefix" ]; then
		resume_cmd="${env_prefix}${resume_cmd}"
	fi

	log "restoring $tool in $pane (session: $session_id, cmd: $resume_cmd)"

	# Clear the pane before launching: tmux-resurrect may have restored old
	# pane contents (captured terminal text from the previous session). Without
	# clearing, TUI tools like Claude show stale output above the new instance.
	# Uses tmux clear-history to wipe scrollback, then sends 'clear' to reset
	# the visible area.
	tmux send-keys -t "$pane_id" "clear" Enter
	tmux clear-history -t "$pane_id"
	sleep 0.3

	# Build the full command: cd to cwd (if it exists) then resume.
	# Use POSIX single-quote escaping (safe for bash, zsh, sh, dash, fish).
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		safe_cwd=$(posix_quote "$cwd")
		tmux send-keys -t "$pane_id" "cd ${safe_cwd} 2>/dev/null; ${resume_cmd}" Enter
	else
		tmux send-keys -t "$pane_id" "${resume_cmd}" Enter
	fi

	restored=$((restored + 1))

	# Stagger launches to avoid overwhelming the system
	sleep 1
done <"$tmpfile"

rm -f "$tmpfile"

log "restored $restored of $count assistant session(s)"
