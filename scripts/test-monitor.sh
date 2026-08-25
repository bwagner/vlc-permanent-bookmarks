#!/usr/bin/env bash
#
# Unit tests for smoke-test.sh's hands-off input monitoring.
#
# The monitoring block is sourced out of smoke-test.sh between its section
# markers, so the harness stays a single self-contained script. If those markers
# are renamed this aborts rather than testing nothing.
#
# Unlike smoke-test.sh this needs no GUI, no VLC and no Accessibility
# permission, does not steal focus, and finishes in well under a second.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly HARNESS="$SCRIPT_DIR/smoke-test.sh"
readonly BLOCK_START="# --- Hands-off monitoring"
readonly BLOCK_END="# --- AppleScript helpers"

if [ -t 1 ]; then
    readonly COLOR_PASS=$'\033[32m'
    readonly COLOR_FAIL=$'\033[31m'
    readonly COLOR_OFF=$'\033[0m'
else
    readonly COLOR_PASS="" COLOR_FAIL="" COLOR_OFF=""
fi

# The sourced block prints its warnings with this; the tests do not colorize.
# shellcheck disable=SC2034  # read by the sourced block, not by this file
COLOR_WARN=""

info() { printf '%s\n' "$*"; }
abort() { printf '%sABORT%s %s\n' "$COLOR_FAIL" "$COLOR_OFF" "$*" >&2; exit 2; }

[ -f "$HARNESS" ] || abort "cannot find the harness at $HARNESS"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vlc-bookmarks-monitor.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

readonly BLOCK="$WORK_DIR/monitor.sh"
readonly FEED_FILE="$WORK_DIR/feed.txt"
readonly OUT="$WORK_DIR/out.txt"

sed -n "/^$BLOCK_START/,/^$BLOCK_END/p" "$HARNESS" | sed '$d' > "$BLOCK"
grep -q '^input_watch_check()' "$BLOCK" \
    || abort "the '$BLOCK_START' section of $HARNESS did not yield input_watch_check - were the section markers renamed?"

# Take the real constants rather than restating them, so the two files cannot
# drift apart silently.
eval "$(grep -E '^readonly (NANOS_PER_SECOND|IDLE_AT_START_WARN_S|IDLE_SETTLE_POLL_S|IDLE_SETTLE_TIMEOUT_S)=' "$HARNESS")"
[ -n "${NANOS_PER_SECOND:-}" ] && [ -n "${IDLE_AT_START_WARN_S:-}" ] \
    && [ -n "${IDLE_SETTLE_POLL_S:-}" ] && [ -n "${IDLE_SETTLE_TIMEOUT_S:-}" ] \
    || abort "could not read the monitoring constants from $HARNESS"

# shellcheck disable=SC1090
source "$BLOCK"

# input_watch_init waits for the machine to go quiet, one real sleep per poll.
# Replaced after sourcing so the suite stays sub-second; the loop's behavior is
# unaffected, only its pacing.
sleep() { :; }

# The code under test reads the counter inside $( ), so the queue of canned
# readings has to live in a file: a shell variable would be consumed in the
# subshell and the same value returned every time.
feed() { printf '%s\n' "$@" > "$FEED_FILE"; }
hid_idle_ns() {
    local v
    v="$(head -1 "$FEED_FILE")"
    tail -n +2 "$FEED_FILE" > "$FEED_FILE.tmp" && mv "$FEED_FILE.tmp" "$FEED_FILE"
    printf '%s' "$v"
}

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

output_contains() { case "$(cat "$OUT")" in *"$1"*) echo yes;; *) echo no;; esac; }

# The functions are called in THIS shell with their output redirected to a file.
# Calling them in $( ) would leave the state they set behind in a subshell.
# shellcheck disable=SC2034  # all three are read by the sourced block
reset_state() { user_input_seen=0; input_monitor_ok=1; last_idle_ns=0; }

readonly IDLE_SMALL_NS=500000000          # 0.5s - the counter was just reset
readonly IDLE_AT_START_SMALL_NS=900000000 # 0.9s - machine in use as we started

info "=== Hands-off monitoring ==="

# A counter that only rises: nobody touched the machine.
reset_state
feed 10000000000 12000000000 20000000000 31000000000
{ input_watch_init; input_watch_check p1; input_watch_check p2; input_watch_check p3; } >"$OUT"
check "a rising counter reports no input" "0" "$user_input_seen"
check "a rising counter prints nothing" "" "$(cat "$OUT")"

# A reading below the previous one means the counter was reset by real input.
reset_state
feed 60000000000 62000000000 "$IDLE_SMALL_NS" 4000000000
{ input_watch_init; input_watch_check p1; input_watch_check p2; input_watch_check p3; } >"$OUT"
check "a drop flags input" "1" "$user_input_seen"
check "a drop names the phase it happened in" "yes" "$(output_contains "activity during p2")"
check "a drop does not blame the neighboring phases" "1" "$(grep -c INPUT "$OUT")"

# Once set the flag stays set, even as the counter climbs again.
reset_state
feed 60000000000 "$IDLE_SMALL_NS" 3000000000 9000000000
{ input_watch_init; input_watch_check p1; input_watch_check p2; input_watch_check p3; } >"$OUT"
check "the flag stays set after the counter recovers" "1" "$user_input_seen"

# A quiet machine: the baseline is taken at once, with nothing said.
reset_state
feed 10000000000
input_watch_init >"$OUT"
check "a quiet machine needs no waiting" "" "$(cat "$OUT")"
check "a quiet machine's first reading is the baseline" "10000000000" "$last_idle_ns"

# In use at the start, then quiet: the baseline waits rather than warning, and
# it is the settled reading that is kept, not the busy one.
reset_state
feed "$IDLE_AT_START_SMALL_NS" "$IDLE_AT_START_SMALL_NS" 4000000000
input_watch_init >"$OUT"
check "a busy start waits for quiet" "yes" "$(output_contains "Waiting for the machine")"
check "a start that settles warns about nothing" "no" "$(output_contains "may go undetected")"
check "the settled reading becomes the baseline" "4000000000" "$last_idle_ns"
check "waiting is announced once, not once per poll" "1" "$(grep -c "Waiting for the machine" "$OUT")"

# The settled baseline is the one input_watch_check compares against.
reset_state
feed "$IDLE_AT_START_SMALL_NS" 4000000000 "$IDLE_SMALL_NS"
{ input_watch_init; input_watch_check p1; } >"$OUT"
check "a drop after the wait is still flagged" "1" "$user_input_seen"

# Never goes quiet: give up, warn, and carry on with the reading in hand.
reset_state
busy_readings=()
for _ in $(seq 1 $(( IDLE_SETTLE_TIMEOUT_S + 1 ))); do
    busy_readings+=("$IDLE_AT_START_SMALL_NS")
done
feed "${busy_readings[@]}"
input_watch_init >"$OUT"
check "a machine that never settles is reported" "yes" "$(output_contains "may go undetected")"
check "giving up is not itself a taint" "0" "$user_input_seen"
check "giving up still leaves monitoring enabled" "1" "$input_monitor_ok"
check "giving up keeps the last reading as the baseline" "$IDLE_AT_START_SMALL_NS" "$last_idle_ns"

# The counter becoming unreadable mid-wait is the same failure as at the start.
reset_state
feed "$IDLE_AT_START_SMALL_NS" ""
input_watch_init >"$OUT"
check "an unreadable counter mid-wait disables monitoring" "0" "$input_monitor_ok"
check "an unreadable counter mid-wait says so" "yes" "$(output_contains "unavailable")"

# ioreg returning nothing: monitoring disables itself instead of guessing.
reset_state
feed ""
input_watch_init >"$OUT"
check "an unreadable counter disables monitoring" "0" "$input_monitor_ok"
check "an unreadable counter says so" "yes" "$(output_contains "unavailable")"
input_watch_check p1 >>"$OUT"
check "a disabled monitor never flags input" "0" "$user_input_seen"

info ""
info "=== Summary ==="
info "passed: $tests_passed  failed: $tests_failed"

[ "$tests_failed" -eq 0 ] || exit 1
