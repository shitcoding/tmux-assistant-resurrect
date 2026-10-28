#!/usr/bin/env bash
# Shared assertion helpers for the hermetic suites. Sourced, never executed.
#
# Each suite used to carry its own copy of these; fourteen copies had drifted
# into four output formats. One definition keeps the summary lines uniform
# for run-tests.sh and CI logs. Suites that must abort on the first failure
# (the real-tmux lifecycle tests) and run-tests.sh itself (JUnit output) keep
# their own helpers on purpose.
#
# Counters: PASS, FAIL and SKIP. A suite's final line stays its own, e.g.
#   echo "<name> unit tests: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]

PASS=0
FAIL=0
SKIP=0

pass() {
	PASS=$((PASS + 1))
	printf '  [pass] %s\n' "$1"
}

# fail <desc> [detail]
fail() {
	FAIL=$((FAIL + 1))
	printf '  [FAIL] %s\n' "$1"
	[ $# -gt 1 ] && printf '         %s\n' "$2"
	return 0
}

# skip <desc> [reason]
skip() {
	SKIP=$((SKIP + 1))
	if [ $# -gt 1 ]; then
		printf '  [skip] %s (%s)\n' "$1" "$2"
	else
		printf '  [skip] %s\n' "$1"
	fi
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
	fi
}

# assert_contains <desc> <haystack> <needle>
assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	case "$haystack" in
	*"$needle"*) pass "$desc" ;;
	*)
		FAIL=$((FAIL + 1))
		printf '  [FAIL] %s\n        expected to contain: [%s]\n        actual:              [%s]\n' "$desc" "$needle" "$haystack"
		;;
	esac
}
