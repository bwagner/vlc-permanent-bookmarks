#!/usr/bin/env bash
#
# Unit tests for smoke-test.sh's run gate: the duration store behind the
# predicted run time, the duration formatting, option parsing, and which end of
# a run gets announced.
#
# Two blocks are sourced out of smoke-test.sh between its section markers, so
# the harness stays a single self-contained script. If those markers are renamed
# this aborts rather than testing nothing.
#
# HOME is redirected at a scratch directory before the constants are read, so
# DURATION_DIR resolves inside it and the real duration history is never
# touched, read or written.
#
# Not covered here: confirm_start() and show_summary_dialog(), which put a real
# dialog on the screen and need a human to click it. Both are exercised by an
# actual smoke-test.sh run.
#
# Unlike smoke-test.sh this needs no GUI, no VLC and no Accessibility
# permission, does not steal focus, and finishes in well under a second.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly HARNESS="$SCRIPT_DIR/smoke-test.sh"
readonly CONFIG_START="# --- Configuration"
readonly CONFIG_END="# --- Test bookkeeping"
readonly BLOCK_START="# --- Run gate, timing and announcements"
readonly BLOCK_END="# --- Hands-off monitoring"

if [ -t 1 ]; then
    readonly COLOR_PASS=$'\033[32m'
    readonly COLOR_FAIL=$'\033[31m'
    readonly COLOR_OFF=$'\033[0m'
else
    readonly COLOR_PASS="" COLOR_FAIL="" COLOR_OFF=""
fi

info() { printf '%s\n' "$*"; }
abort() { printf '%sABORT%s %s\n' "$COLOR_FAIL" "$COLOR_OFF" "$*" >&2; exit 2; }

[ -f "$HARNESS" ] || abort "cannot find the harness at $HARNESS"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vlc-bookmarks-gate.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

readonly CONFIG="$WORK_DIR/config.sh"
readonly BLOCK="$WORK_DIR/gate.sh"

# Before the constants are read, so DURATION_DIR lands in the scratch directory.
export HOME="$WORK_DIR/home"
mkdir -p "$HOME"

sed -n "/^$CONFIG_START/,/^$CONFIG_END/p" "$HARNESS" | sed '$d' > "$CONFIG"
grep -q '^readonly DURATION_KEEP=' "$CONFIG" \
    || abort "the '$CONFIG_START' section of $HARNESS did not yield DURATION_KEEP - were the section markers renamed?"

sed -n "/^$BLOCK_START/,/^$BLOCK_END/p" "$HARNESS" | sed '$d' > "$BLOCK"
grep -q '^estimated_duration_s()' "$BLOCK" \
    || abort "the '$BLOCK_START' section of $HARNESS did not yield estimated_duration_s - were the section markers renamed?"
grep -q '^parse_args()' "$BLOCK" \
    || abort "the '$BLOCK_START' section of $HARNESS did not yield parse_args - were the section markers renamed?"

# shellcheck disable=SC1090
source "$CONFIG"
# shellcheck disable=SC1090
source "$BLOCK"

[ "${DURATION_FILE#"$WORK_DIR"}" != "$DURATION_FILE" ] \
    || abort "DURATION_FILE is $DURATION_FILE, outside the scratch directory - refusing to run against the real history"

# Replaced after sourcing so the tests never actually make a sound. The braces
# are load-bearing: "$spoken[$1]" reads as an array subscript.
spoken=""
speak() { spoken="${spoken}[$1]"; }

tests_passed=0
tests_failed=0

check() {
    if [ "$2" = "$3" ]; then
        tests_passed=$((tests_passed + 1))
        printf '%sPASS%s %s\n' "$COLOR_PASS" "$COLOR_OFF" "$1"
    else
        tests_failed=$((tests_failed + 1))
        printf '%sFAIL%s %s\n' "$COLOR_FAIL" "$COLOR_OFF" "$1"
        printf '       expected: %s\n' "$2"
        printf '       actual:   %s\n' "$3"
    fi
}

# parse_args aborts by exiting, so all three helpers run it in a subshell.
# shellcheck disable=SC2154  # assume_yes and announce are set by the sourced block
parsed_state() ( parse_args "$@" >/dev/null 2>&1 && printf '%s/%s' "$assume_yes" "$announce" )
parse_status() { ( parse_args "$@" ) >/dev/null 2>&1; echo $?; }
# The abort text with the color escapes and the ABORT prefix stripped. abort()
# colorizes only when stdout is a terminal, so an assertion that assumed plain
# text passed under a pipe and failed in a real shell - strip them always.
parse_error() {
    ( parse_args "$@" ) 2>&1 >/dev/null | tail -1 \
        | sed -e "s/$(printf '\033')\[[0-9;]*m//g" -e 's/^ABORT //'
}

info "=== Reading a duration for humans ==="

check "a short run reads in seconds"        "about 45 seconds" "$(format_duration 45)"
check "just under the threshold"            "about 89 seconds" "$(format_duration 89)"
check "the threshold crosses to minutes"    "about 2 minutes"  "$(format_duration 90)"
check "a typical run rounds down"           "about 2 minutes"  "$(format_duration 121)"
check "a slow run rounds up"                "about 3 minutes"  "$(format_duration 150)"

info ""
info "=== The duration store ==="

rm -f "$DURATION_FILE"
check "no history yields no estimate"       ""    "$(estimated_duration_s || true)"
check "and says so with its exit code"      "1"   "$(estimated_duration_s >/dev/null 2>&1; echo $?)"

record_duration 100
check "one run is its own median"           "100" "$(estimated_duration_s)"
record_duration 200
check "an even count takes the upper median" "200" "$(estimated_duration_s)"
record_duration 150
check "an odd count takes the middle"       "150" "$(estimated_duration_s)"

# The window must drop the oldest rather than growing without bound.
rm -f "$DURATION_FILE"
for n in 1 2 3 4 5 6 7; do record_duration "$n"; done
check "the window keeps $DURATION_KEEP runs" "$DURATION_KEEP" "$(wc -l < "$DURATION_FILE" | tr -d ' ')"
check "it keeps the newest, drops the oldest" "3 4 5 6 7" "$(tr '\n' ' ' < "$DURATION_FILE" | sed 's/ $//')"
check "the median follows the window"       "5"   "$(estimated_duration_s)"

# The point of a median rather than the last run: one bad sample cannot move it.
printf '118\n124\n121\n119\n122\n' > "$DURATION_FILE"
check "a steady set gives its middle value" "121" "$(estimated_duration_s)"
record_duration 900
check "a 15-minute outlier barely moves it" "122" "$(estimated_duration_s)"

# A store damaged by anything else must degrade to the fallback, never crash.
printf 'garbage\n\nnot-a-number\n' > "$DURATION_FILE"
check "an unreadable store yields nothing"  "1"   "$(estimated_duration_s >/dev/null 2>&1; echo $?)"
printf 'garbage\n130\n' > "$DURATION_FILE"
check "junk beside a number is skipped"     "130" "$(estimated_duration_s)"

info ""
info "=== Option parsing ==="

check "no arguments take the defaults"      "0/$ANNOUNCE_DEFAULT" "$(parsed_state)"
check "-y skips the gate"                   "1/$ANNOUNCE_DEFAULT" "$(parsed_state -y)"
check "--yes skips the gate"                "1/$ANNOUNCE_DEFAULT" "$(parsed_state --yes)"
check "--announce=$ANNOUNCE_NONE"           "0/$ANNOUNCE_NONE"    "$(parsed_state "--announce=$ANNOUNCE_NONE")"
check "--announce=$ANNOUNCE_BOTH"           "0/$ANNOUNCE_BOTH"    "$(parsed_state "--announce=$ANNOUNCE_BOTH")"
check "--announce takes a separate value"   "0/$ANNOUNCE_BOTH"    "$(parsed_state --announce "$ANNOUNCE_BOTH")"
check "the flags combine"                   "1/$ANNOUNCE_NONE"    "$(parsed_state "--announce=$ANNOUNCE_NONE" -y)"
check "and in either order"                 "1/$ANNOUNCE_NONE"    "$(parsed_state -y --announce "$ANNOUNCE_NONE")"

check "an unknown option is refused"        "2" "$(parse_status --bogus)"
check "and is named in the message"         "unknown option: --bogus" "$(parse_error --bogus)"
check "a bad announce value is refused"     "2" "$(parse_status --announce=sometimes)"
check "and the bad value is quoted back"    "yes" \
    "$(case "$(parse_error --announce=sometimes)" in *"'sometimes'"*) echo yes;; *) echo no;; esac)"
check "--announce with no value is refused" "2" "$(parse_status --announce)"
check "--help exits cleanly"                "0" "$(parse_status --help)"
check "--help prints usage"                 "yes" \
    "$(case "$("$HARNESS" --help | head -1)" in "Usage: smoke-test.sh"*) echo yes;; *) echo no;; esac)"

info ""
info "=== Which end gets announced ==="

announce="$ANNOUNCE_END";  spoken=""; announce_start; check "$ANNOUNCE_END: silent at the start" "" "$spoken"
announce="$ANNOUNCE_END";  spoken=""; announce_end;   check "$ANNOUNCE_END: speaks at the end" "[$SPOKEN_END]" "$spoken"
announce="$ANNOUNCE_BOTH"; spoken=""; announce_start; check "$ANNOUNCE_BOTH: speaks at the start" "[$SPOKEN_START]" "$spoken"
announce="$ANNOUNCE_BOTH"; spoken=""; announce_end;   check "$ANNOUNCE_BOTH: speaks at the end" "[$SPOKEN_END]" "$spoken"
announce="$ANNOUNCE_NONE"; spoken=""; announce_start; announce_end
check "$ANNOUNCE_NONE: silent at both ends" "" "$spoken"

info ""
info "=== Summary ==="
info "passed: $tests_passed  failed: $tests_failed"

[ "$tests_failed" -eq 0 ] || exit 1
