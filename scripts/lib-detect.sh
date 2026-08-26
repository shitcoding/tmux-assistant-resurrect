#!/usr/bin/env bash
# Shared assistant detection library.
# Sourced by save-assistant-sessions.sh and restore-assistant-sessions.sh.
#
# Provides:
#   detect_tool <args>           — returns tool name or empty string
#   relaunch_canon <tool> <argv> — canonical session-less command, or failure
#   relaunch_shape_ok <canon>    — advisory candidate-shape filter
#   relaunch_voucher_match <tool> <canon> — exact vouched line, or failure
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

# --- session-less relaunch vouchers ---

# Canonicalize the flattened argv reported by ps. This is deliberately a
# small, idempotent transform: it validates argv[0], removes the duplicate
# Node script path form (`claude /path/to/claude ...`), and joins tokens with
# one space. It does not interpret shell syntax or decide that a command is
# safe to run; exact membership in the user-owned voucher file is the only
# authorization gate.
relaunch_canon() {
	local tool="$1" raw_args="$2"
	local first token result
	[ "$(detect_tool "$tool")" = "$tool" ] || return 1

	set -f
	# shellcheck disable=SC2086 # ps argv is intentionally split into tokens.
	set -- $raw_args
	set +f
	[ "$#" -gt 0 ] || return 1

	first="$1"
	[ "${first##*/}" = "$tool" ] || return 1
	shift

	# Node-based launchers can expose the script path as a second copy of the
	# tool name. Mirror extract_cli_args() and remove that one token.
	if [ "$#" -gt 0 ]; then
		case "$1" in
		*/"$tool") shift ;;
		esac
	fi

	result="$tool"
	for token in "$@"; do
		result="$result $token"
	done
	printf '%s\n' "$result"
}

# Structural proposer for the advisory candidates ledger. Passing this filter
# never authorizes a relaunch. Keep it conservative because ps has already lost
# quoting boundaries; commands it cannot round-trip cleanly should not be
# suggested to the user.
relaunch_shape_ok() {
	local canon="$1" token flag_name
	local token_count=0 positional_count=0 byte_count
	local flag_re='^--?[A-Za-z0-9][A-Za-z0-9._-]*(=[^[:space:]]{0,64})?$'
	local positional_re='^[a-z][a-z0-9-]{0,31}$'

	byte_count=$(printf '%s' "$canon" | LC_ALL=C wc -c | tr -d ' ')
	[ "$byte_count" -le 128 ] || return 1
	printf '%s' "$canon" | LC_ALL=C grep -Eq '^[ -~]+$' || return 1

	set -f
	# shellcheck disable=SC2086 # canonical argv is intentionally tokenized.
	set -- $canon
	set +f
	[ "$#" -gt 1 ] || return 1
	[ "$#" -le 10 ] || return 1
	shift # validated tool token; relaunch_canon() owns that check

	for token in "$@"; do
		token_count=$((token_count + 1))
		[ "$token" != "--" ] || return 1
		case "$token" in
		-*)
			[[ "$token" =~ $flag_re ]] || return 1
			flag_name="${token%%=*}"
			# Prompt-bearing modes are one-shot work, not long-lived modes.
			# This list is advisory-only and must never be used as the voucher
			# authorization gate in save or restore.
			case "$flag_name" in
			-p | --print | --prompt | -i | --interactive | -m | --message | -q | --query | --input | --instruction | --instructions | --task)
				return 1
				;;
			esac
			;;
		*)
			[[ "$token" =~ $positional_re ]] || return 1
			positional_count=$((positional_count + 1))
			[ "$positional_count" -le 2 ] || return 1
			;;
		esac
	done

	[ "$token_count" -gt 0 ] && [ "$positional_count" -ge 1 ]
}

# Resolve the user-owned voucher file. An unset tmux option follows the
# tmux-resurrect save directory; tests and unusual installations can keep using
# TMUX_RESURRECT_DIR through resurrect_data_dir().
relaunch_voucher_file() {
	local configured
	configured=$(tmux show-option -gqv @assistant-resurrect-relaunch-allow-file 2>/dev/null || true)
	if [ -n "$configured" ]; then
		printf '%s\n' "$configured"
	else
		printf '%s/assistant-relaunch-allow.txt\n' "$(resurrect_data_dir)"
	fi
}

# Print the exact matching line from the voucher file. The sidecar value must
# already be canonical: normalizing a tampered lookup key here would weaken the
# whole-line byte-equality guarantee. CRLF line endings are accepted, but
# trailing spaces remain significant and therefore do not match.
relaunch_voucher_match() {
	local tool="$1" canon="$2" file normalized line
	normalized=$(relaunch_canon "$tool" "$canon") || return 1
	[ "$normalized" = "$canon" ] || return 1

	file=$(relaunch_voucher_file)
	[ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		# Canonical commands cannot begin with whitespace, so all such lines
		# are safely ignorable alongside blank lines and comments.
		case "$line" in
		'' | \#* | [[:space:]]*) continue ;;
		esac
		if printf '%s\n' "$line" | grep -Fxq -- "$canon"; then
			printf '%s\n' "$line"
			return 0
		fi
	done <"$file"
	return 1
}

# Build a shell-safe command only from a line returned by the voucher matcher.
# Metacharacters introduced by expansion are ordinary argv bytes, and every
# token is quoted for the restored pane's shell before send-keys sees it.
relaunch_command_from_voucher() {
	local tool="$1" canon="$2" shell_name="${3:-sh}"
	local line rest="" token
	line=$(relaunch_voucher_match "$tool" "$canon") || return 1

	set -f
	# shellcheck disable=SC2086 # the vouched canonical line is tokenized as argv.
	set -- $line
	set +f
	[ "$#" -gt 0 ] && [ "$1" = "$tool" ] || return 1
	shift
	for token in "$@"; do
		rest="$rest $(shell_quote "$shell_name" "$token")"
	done
	printf 'command %s%s\n' "$tool" "$rest"
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
