#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   pane_has_assistant <pane_pid> [ps_snapshot] — returns 0 + prints PID if found
#   split_pane_target <target>   — splits "session:window.pane" into its parts
#   match_pane_id <s> <w> <p>    — filters a pane table on stdin to one pane id
#   resolve_tmux_pane_id <s> <w> <p> — prints the live %N for a saved pane
#   resurrect_data_dir           — prints tmux-resurrect's save directory

# --- detect_tool ---
# Match binary name with optional path prefix, standalone or with arguments.
# Handles: /path/to/claude, claude, claude --resume ..., copilot --resume ...,
#          opencode -s ..., codex resume ..., pi --session ..., omp --resume ...,
#          grok --resume ..., etc.
# Excludes: opencode run ... (LSP subprocesses), omp __omp_worker_* subprocesses
#
# Limitation: patterns match any command line containing /claude, /opencode,
# /copilot, /codex, /pi, /omp, or /grok as a path component. An unrelated
# binary with the same name (e.g., a LaTeX tool named "codex") would be falsely
# detected. In practice this is rare inside tmux panes, but worth noting.
# Future: could verify identity via --version or known subcommands if false
# positives become an issue.
detect_tool() {
	local args="$1"
	case "$args" in
	claude | claude\ * | */claude | */claude\ *) echo "claude" ;;
	copilot | copilot\ * | */copilot | */copilot\ *) echo "copilot" ;;
	opencode | opencode\ * | */opencode | */opencode\ *)
		# Exclude LSP/language server subprocesses
		case "$args" in
		*"opencode run "*) ;;
		*) echo "opencode" ;;
		esac
		;;
	codex | codex\ * | */codex | */codex\ *) echo "codex" ;;
	pi | pi\ * | */pi | */pi\ *) echo "pi" ;;
	omp | omp\ * | */omp | */omp\ *)
		# Exclude hidden OMP worker subprocesses; their process title can also be "omp".
		case "$args" in
		*"__omp_worker_"*) ;;
		*) echo "omp" ;;
		esac
		;;
	grok | grok\ * | */grok | */grok\ *) echo "grok" ;;
	esac
}

# --- pane_has_assistant ---
# Check if a pane has a running assistant anywhere in its process tree.
# Checks the pane PID itself (exec-replaced shells) AND walks the full
# descendant tree (handles wrappers like npx, env, direnv, bash -lc).
#
# Usage: pane_has_assistant <pane_shell_pid> [ps_snapshot]
# If ps_snapshot is not provided, takes a fresh snapshot.
# Returns 0 and prints the assistant PID if found, returns 1 otherwise.
pane_has_assistant() {
	local shell_pid="$1"
	local snapshot="${2:-$(ps -eo pid=,ppid=,args= 2>/dev/null)}"

	# Check the pane PID itself (handles exec-replaced shells, e.g. exec claude)
	local pane_args
	pane_args=$(echo "$snapshot" | awk -v pid="$shell_pid" '$1 == pid {print substr($0, index($0,$3)); exit}')
	if [ -n "$(detect_tool "$pane_args")" ]; then
		echo "$shell_pid"
		return 0
	fi

	# Walk the entire process tree under the pane shell.
	# Uses a single-pass awk that builds the descendant set as it goes.
	#
	# Assumption: ps output is ordered by ascending PID, so parents appear
	# before children. POSIX doesn't guarantee this, but it holds on Linux
	# (procfs enumeration) and macOS (libproc). If a child PID appeared before
	# its parent, it would be missed. A multi-pass approach would be more
	# robust but slower; in practice, single-pass has been reliable.
	local found_pid
	found_pid=$(echo "$snapshot" | awk -v root="$shell_pid" '
		BEGIN { pids[root]=1 }
		{ if ($2 in pids) { pids[$1]=1; print $1, substr($0, index($0,$3)) } }
	' | while read -r cpid cargs; do
		if [ -n "$(detect_tool "$cargs")" ]; then
			echo "$cpid"
			break
		fi
	done)

	if [ -n "$found_pid" ]; then
		echo "$found_pid"
		return 0
	fi

	return 1
}

# --- split_pane_target ---
# Split a saved "session:window.pane" target into its parts, setting
# PANE_TARGET_SESSION, PANE_TARGET_WINDOW and PANE_TARGET_INDEX.
# Returns 1 (leaving the variables untouched) if the target is not that shape.
#
# Splitting from the RIGHT is exact: the window and pane parts are always
# indices, so the LAST ':' and the LAST '.' are the real separators. Splitting
# from the left is not exact — tmux allows both characters in a session name, so
# "${target%%:*}" turns "https://host/x:0.0" into "https".
# shellcheck disable=SC2034  # PANE_TARGET_* are out-parameters, read by callers
split_pane_target() {
	local target="$1" win_pane
	case "$target" in
	*:*.*) ;;
	*) return 1 ;;
	esac
	win_pane="${target##*:}"
	PANE_TARGET_SESSION="${target%:*}"
	PANE_TARGET_WINDOW="${win_pane%.*}"
	PANE_TARGET_INDEX="${win_pane##*.}"
}

# --- match_pane_id ---
# Read a "#{pane_id}|#{window_index}|#{pane_index}|#{session_name}" table on
# stdin and print the pane id whose fields equal <session> <window> <index>.
# Prints nothing when there is no match. Split out from resolve_tmux_pane_id()
# so the matching can be tested without a tmux server.
#
# The session name is last because it is the only field that may contain the '|'
# delimiter: awk peels the fixed-shape fields off the front and takes the
# remainder verbatim. A control-character delimiter would avoid the problem but
# is not portable — tmux < 3.7 rewrites those in -F output, differently per
# version (see AGENTS.md "Pipe delimiter in tmux format output").
#
# The values are passed through the environment rather than `awk -v`, which
# expands backslash escapes and would corrupt a name containing a backslash.
match_pane_id() {
	TAR_SESSION="$1" TAR_WINDOW="$2" TAR_INDEX="$3" awk '
		BEGIN { s = ENVIRON["TAR_SESSION"]; w = ENVIRON["TAR_WINDOW"]; p = ENVIRON["TAR_INDEX"] }
		{
			rec = $0
			i = index(rec, "|"); if (i == 0) next
			id  = substr(rec, 1, i - 1); rec = substr(rec, i + 1)
			i = index(rec, "|"); if (i == 0) next
			win = substr(rec, 1, i - 1); rec = substr(rec, i + 1)
			i = index(rec, "|"); if (i == 0) next
			idx = substr(rec, 1, i - 1); rec = substr(rec, i + 1)
			if (found == "" && rec == s && win == w && idx == p) { found = id }
		}
		END { if (found != "") print found }
	'
}

# --- resolve_tmux_pane_id ---
# Print the live pane id (%N) of the pane identified by <session> <window>
# <index>, or nothing if no such pane exists on this server.
#
# Why not just hand tmux the "session:window.pane" string? Because tmux's target
# grammar reserves ':' and '.' but session names may contain them, and tmux also
# prefix-matches session names. A session named "v1.2" makes
# `has-session -t v1.2` fail with "can't find pane: 2"; a session named
# "https://host/x" makes it succeed against a *different* session. `-t '=name'`
# does not help either — the grammar splits before the exact match is applied.
# Comparing the parts literally against list-panes output sidesteps the grammar
# entirely, and the %N it yields is accepted verbatim by every tmux command.
#
# Pane ids are only unique within one tmux server lifetime — the exact boundary
# this plugin operates across — so they are resolved here at restore time and
# never persisted.
resolve_tmux_pane_id() {
	tmux list-panes -a -F '#{pane_id}|#{window_index}|#{pane_index}|#{session_name}' 2>/dev/null |
		match_pane_id "$1" "$2" "$3"
}

# --- posix_quote ---
# POSIX-safe single-quote escaping.  Wraps value in single quotes and
# replaces embedded single quotes with the sequence '"'"' which closes
# the single-quoted string, adds an escaped single quote in double quotes,
# and re-opens the single-quoted string.
#
# Safe for bash, zsh, sh, dash, and fish (fish accepts single-quoted strings).
posix_quote() {
	local val="$1"
	# Replace each ' with '"'"'
	val="${val//\'/\'\"\'\"\'}"
	printf "'%s'" "$val"
}

# Quote one value for the shell running in a restored pane. csh/tcsh perform
# history expansion inside single quotes and use different embedded-quote
# rules, so escape `!` and use their `'\''` sequence for a literal quote.
# Other supported shells accept posix_quote().
shell_quote() {
	local shell_name="$1" val="$2"
	case "$shell_name" in
	csh | tcsh)
		local quote_escape="'\\''"
		val="${val//!/\\!}"
		val="${val//\'/$quote_escape}"
		printf "'%s'" "$val"
		;;
	*) posix_quote "$val" ;;
	esac
}

# --- resurrect_data_dir ---
# Print the directory tmux-resurrect saves into, resolved the SAME way resurrect
# resolves it itself (scripts/helpers.sh:resurrect_dir). Our sidecar files
# (assistant-sessions.json, *.log) and the pane_contents.tar.gz we rewrite must
# live next to resurrect's own saves, so this has to track resurrect's logic
# rather than assume a fixed location.
#
# Resolution order:
#   1. $TMUX_RESURRECT_DIR        — explicit override (tests / unusual setups)
#   2. @resurrect-dir tmux option — when the user set one
#   3. ~/.tmux/resurrect          — when that directory already exists (legacy default)
#   4. ${XDG_DATA_HOME:-~/.local/share}/tmux/resurrect — modern (XDG) default
#
# Why this matters — do NOT hardcode ~/.tmux/resurrect: on an XDG install that
# directory does not exist, so resurrect saves under ~/.local/share. Writing our
# files to ~/.tmux/resurrect anyway would not only split them away from
# resurrect's real saves, it would `mkdir` that directory — and resurrect's own
# dir-exists check (step 3) would then flip the user's save location to it on the
# next run, silently migrating their data and orphaning prior saves.
#
# Mirrors resurrect's expansion of ~, $HOME and $HOSTNAME inside @resurrect-dir.
resurrect_data_dir() {
	if [ -n "${TMUX_RESURRECT_DIR:-}" ]; then
		echo "$TMUX_RESURRECT_DIR"
		return
	fi

	local dir
	dir=$(tmux show-option -gqv @resurrect-dir 2>/dev/null || true)
	if [ -z "$dir" ]; then
		if [ -d "$HOME/.tmux/resurrect" ]; then
			dir="$HOME/.tmux/resurrect"
		else
			dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
		fi
	fi

	local host
	host=$(hostname 2>/dev/null || true)
	echo "$dir" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$host,g; s,~,$HOME,g"
}

# Directory holding the per-process assistant state files (claude-<pid>.json,
# opencode-<pid>.json).
#
# Resolution order:
#   1. $TMUX_ASSISTANT_RESURRECT_DIR — explicit override (tests / unusual setups)
#   2. $HOME/.local/state/tmux-assistant-resurrect
#
# Why this is a plain $HOME literal and not $XDG_STATE_HOME / $XDG_RUNTIME_DIR /
# $TMPDIR — this path is a *rendezvous point between two processes that never
# share an environment*: the SessionStart hook writes as a child of the assistant,
# the save hook reads as a child of the tmux server. Every environment variable in
# the expression is therefore a chance for the two sides to disagree, and when they
# do the failure is silent — the save hook finds no state file and falls back to
# scraping --resume out of argv, recording a missing or (worse) a stale ID from a
# previous session.
#
# The previous ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}} chain broke exactly that way:
# Claude Code's settings.json can set "env": {"TMPDIR": ...} — common, because /tmp
# is mounted noexec in many containers — which the hook inherits and the tmux server
# does not. $XDG_STATE_HOME would reintroduce the same bug with a rarer trigger, so
# it is deliberately not consulted. $HOME is the one variable both sides are already
# guaranteed to agree on: Claude Code resolved ~/.claude/settings.json through it and
# tmux read ~/.tmux.conf through it. Same reasoning as the $HOME-only substitution in
# the stored hook paths (see AGENTS.md, "portable hook paths").
#
# Note this deliberately differs from resurrect_data_dir() above, which *does* honour
# $XDG_DATA_HOME. That one is only ever resolved inside the save/restore scripts, so
# it has no second process to disagree with.
#
# To relocate the directory, set TMUX_ASSISTANT_RESURRECT_DIR where BOTH sides see it
# (`tmux set-environment -g` plus the assistant's own env config). Exporting it from a
# shell profile reaches only the assistant, and reintroduces the divergence.
assistant_state_dir() {
	if [ -n "${TMUX_ASSISTANT_RESURRECT_DIR:-}" ]; then
		echo "$TMUX_ASSISTANT_RESURRECT_DIR"
		return
	fi
	echo "${HOME:?tmux-assistant-resurrect: HOME is unset; set TMUX_ASSISTANT_RESURRECT_DIR instead}/.local/state/tmux-assistant-resurrect"
}

# The pre-$HOME default locations, newline-separated, most-likely first. Used only by
# the save hook, to migrate state files written by hooks that ran before the upgrade —
# without it, every already-running assistant loses its session ID until it is
# restarted, and continuum overwrites the good sidecar within five minutes.
#
# Why a *set* and not one resolved path: the old expression was
# ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-assistant-resurrect, and issue #65 is
# precisely that it resolved differently in the writer's environment than in the
# reader's. Evaluating it once here resolves it in the reader's — so it would migrate
# only the users whose two sides already agreed, i.e. the ones who were never broken,
# and find nothing for the ones who were.
#
# So enumerate every location a pre-upgrade hook could plausibly have written to,
# whether or not this process's environment names it:
#   $XDG_RUNTIME_DIR   the reader's, when it has one
#   /run/user/<uid>    the systemd default — covers the reader having no
#                      XDG_RUNTIME_DIR while the hook, run from a login session, did
#   $TMPDIR            the reader's, when it has one
#   /var/folders/<hash>/T  macOS's per-uid temp dir, but only when this side has no
#                      $TMPDIR of its own -- covers a tmux server started by launchd
#                      or over ssh, which inherits none, while the hook that wrote
#                      the file did. It is keyed on uid, not on the login session, so
#                      it resolves to the same path the writer used.
#   /tmp               the final fallback of the old chain
#
# Still not discoverable from this side: a settings.json naming a private TMPDIR for
# the assistant alone. That residue is what missing_session_hint()'s diagnostic exists
# to explain.
#
# Deliberately fork-free (no sed/id) on the hot path: this runs on every save cycle.
# The one `getconf` is gated twice -- a normal macOS shell always exports $TMPDIR, and
# /var/folders does not exist off Darwin -- so in practice it never runs.
legacy_assistant_state_dirs() {
	if [ -n "${TMUX_ASSISTANT_RESURRECT_DIR:-}" ]; then
		return
	fi

	local nl='
'
	local current uid seen="" base dir darwin_tmp=""
	current=$(assistant_state_dir)
	uid="${EUID:-${UID:-}}"

	if [ -z "${TMPDIR:-}" ] && [ -d /var/folders ]; then
		# `|| darwin_tmp=""` is load-bearing: the save hook runs under `set -e`, and a
		# getconf that does not know the key exits non-zero.
		darwin_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || darwin_tmp=""
	fi

	for base in \
		"${XDG_RUNTIME_DIR:-}" \
		"${uid:+/run/user/$uid}" \
		"${TMPDIR:-}" \
		"$darwin_tmp" \
		/tmp; do
		[ -n "$base" ] || continue
		# Strip the trailing slash $TMPDIR usually carries, so the dedupe below and
		# the log line both show a canonical path.
		while [ "${base%/}" != "$base" ]; do base="${base%/}"; done
		dir="$base/tmux-assistant-resurrect"
		[ "$dir" = "$current" ] && continue
		case "$nl$seen" in
		*"$nl$dir$nl"*) continue ;;
		esac
		seen="$seen$dir$nl"
	done

	printf '%s' "$seen"
}
