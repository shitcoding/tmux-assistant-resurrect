#!/usr/bin/env bash
# Shared log handling for the save and restore hooks. Sourced, never executed.
#
# Both hooks keep a 500-line log next to tmux-resurrect's saves. The log holds
# session ids, reconstructed CLI arguments and captured environment values, so
# it is created owner-only, never appended through a symlinked path, and
# written through a descriptor retained from creation so a later path swap
# cannot redirect output. This used to be duplicated verbatim in both scripts.

# open_assistant_log <path> <kind>
#
# Move an existing log aside without following it, create the replacement
# atomically under noclobber and keep it open on fd 9, then carry the previous
# log's tail over. The moved file is rechecked before it is read so a raced
# symlink is never used as rotation input. Sets LOG_FILE and LOG_ENABLED for
# log() below; on any failure file logging is disabled and the hook carries on
# with stderr only. <kind> names the hook in diagnostics ("save", "restore").
open_assistant_log() {
	LOG_FILE="$1"
	local kind="$2"
	LOG_ENABLED=0
	local previous="" previous_copied=0 had_noclobber=0 old_umask
	if [ -e "$LOG_FILE" ] || [ -L "$LOG_FILE" ]; then
		if [ -L "$LOG_FILE" ]; then
			printf '%s\n' "tmux-assistant-resurrect: refusing symlinked $kind log: $LOG_FILE" >&2
		elif [ ! -f "$LOG_FILE" ]; then
			printf '%s\n' "tmux-assistant-resurrect: refusing non-regular $kind log: $LOG_FILE" >&2
		else
			previous=$(mktemp "${LOG_FILE}.rotate.XXXXXX" 2>/dev/null || true)
			if [ -z "$previous" ] || ! mv "$LOG_FILE" "$previous" 2>/dev/null; then
				printf '%s\n' "tmux-assistant-resurrect: cannot rotate $kind log, disabling file logging: $LOG_FILE" >&2
				[ -z "$previous" ] || rm -f "$previous"
				previous=""
			fi
		fi
	fi

	if { [ ! -e "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ]; } &&
		{ [ -z "$previous" ] || { [ -f "$previous" ] && [ ! -L "$previous" ]; }; }; then
		case "$-" in *C*) had_noclobber=1 ;; esac
		old_umask=$(umask)
		umask 077
		set -C
		if exec 9>"$LOG_FILE"; then
			LOG_ENABLED=1
		fi
		[ "$had_noclobber" -eq 1 ] || set +C
		umask "$old_umask"
		if [ "$LOG_ENABLED" -eq 1 ] && [ -n "$previous" ]; then
			if tail -n 500 "$previous" >&9 2>/dev/null; then
				previous_copied=1
			fi
		fi
	fi

	if [ -n "$previous" ]; then
		if [ "$LOG_ENABLED" -eq 1 ] && [ "$previous_copied" -eq 1 ]; then
			rm -f "$previous"
		else
			printf '%s\n' "tmux-assistant-resurrect: previous $kind log retained at $previous" >&2
		fi
	fi
	if [ "$LOG_ENABLED" -ne 1 ] && [ ! -e "$LOG_FILE" ]; then
		printf '%s\n' "tmux-assistant-resurrect: cannot securely open $kind log, disabling file logging: $LOG_FILE" >&2
	fi
	_LOG_KIND="$kind"
	return 0
}

# log <message...>
#
# One event per physical line, to stderr (tmux-resurrect's execute_hook evals
# the hook, so stdout would land in the active pane) and to the log when open.
# Sidecar and process values may contain control characters: escaping CR, LF
# and ESC keeps a corrupt value from forging log entries or emitting an escape
# sequence into the hook's terminal.
log() {
	local msg
	msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	msg="${msg//$'\r'/\\r}"
	msg="${msg//$'\n'/\\n}"
	msg="${msg//$'\033'/\\e}"
	printf '%s\n' "$msg" >&2
	if [ "${LOG_ENABLED:-0}" -eq 1 ]; then
		if ! printf '%s\n' "$msg" >&9 2>/dev/null; then
			LOG_ENABLED=0
			printf '%s\n' "tmux-assistant-resurrect: cannot write ${_LOG_KIND:-} log, disabling file logging: ${LOG_FILE:-}" >&2
		fi
	fi
}
