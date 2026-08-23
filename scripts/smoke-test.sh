#!/usr/bin/env bash
#
# End-to-end smoke test for the vlc_permanent_bookmarks VLC extension.
#
# There is no Lua interpreter inside VLC and no offline harness for extension
# code, so the only way to test this extension is to run it: launch VLC on a
# generated media file, drive the dialog through the macOS accessibility API,
# and assert against the bookmark file the extension writes to disk.
#
# The test touches exactly one bookmark file - the one keyed by the generated
# fixture's hash, read from VLC's own debug log. No other file under the
# bookmarks directory is opened, read or written.
#
# Requirements: macOS, VLC 3.x, ffmpeg, jq, and Accessibility permission for
# the terminal application running this script.

set -euo pipefail

# --- Configuration ---------------------------------------------------------

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EXTENSION_FILE="vlc_permanent_bookmarks.lua"
readonly VLC_APP_BUNDLE="/Applications/VLC.app"
readonly VLC_APP_NAME="VLC"
readonly EXTENSIONS_DIR="$HOME/Library/Application Support/org.videolan.vlc/lua/extensions"
readonly BOOKMARKS_DIR="$EXTENSIONS_DIR/userdata/bookmarks"

# Bookmark files are JSON and named <hash>.json; must match BOOKMARK_FILE_EXT
# in the extension.
readonly BOOKMARK_FILE_EXT=".json"

# The dialog title, which is also the Extensions menu entry (descriptor.title).
readonly DIALOG_TITLE="VLC Permanent Bookmarks"

# Fixture: 5 minutes of testsrc. The keyframe interval equals the frame rate, so
# there is a keyframe every second and seeks land exactly on the second asked
# for. Must exceed 64 KB so getFileHash() takes its normal two-chunk path.
readonly FIXTURE_NAME="smoke-fixture.mp4"
readonly FIXTURE_DURATION_S=300
readonly FIXTURE_RESOLUTION="320x240"
readonly FIXTURE_FPS=10
readonly FIXTURE_KEYFRAME_FRAMES=10

# Bookmark positions, in seconds. GAMMA is deliberately earlier than ALPHA so
# the binary-insert ordering path is exercised.
readonly T_ALPHA=60
readonly T_BETA=120
readonly T_GAMMA=30
readonly T_ELSEWHERE=200

readonly MICROS_PER_SECOND=1000000
# Seeks measured exact on VLC 3.0.23, but allow a keyframe's worth of slack.
readonly TIME_TOLERANCE_US=1000000

# Waits. VLC writes the bookmark file synchronously on the button click, but the
# click itself is dispatched asynchronously through the accessibility API.
readonly UI_SETTLE_S=0.4
readonly ACTION_SETTLE_S=1
readonly LAUNCH_TIMEOUT_TRIES=40
readonly LAUNCH_POLL_S=0.5
readonly QUIT_TIMEOUT_TRIES=10
# Clicking the Extensions menu occasionally no-ops while the Cocoa menu is still
# being built, so the open path polls and retries rather than clicking once.
readonly DIALOG_OPEN_ATTEMPTS=3
readonly DIALOG_WAIT_TRIES=16
# Accessibility calls fail transiently while the dialog is being rebuilt after
# a list change, so element access is retried before it is believed.
readonly AX_RETRY_TRIES=5
readonly AX_RETRY_DELAY_S=0.4

# Hands-off monitoring. HIDIdleTime is reported in nanoseconds; an idle time
# below IDLE_AT_START_WARN_S when the run begins means the machine was still
# being used, which leaves a blind spot over the first phase.
readonly NANOS_PER_SECOND=1000000000
readonly IDLE_AT_START_WARN_S=3

# --- Test bookkeeping ------------------------------------------------------

tests_passed=0
tests_failed=0
tests_xfailed=0
tests_xpassed=0
failure_seen=0

if [ -t 1 ]; then
    readonly COLOR_PASS=$'\033[32m'
    readonly COLOR_FAIL=$'\033[31m'
    readonly COLOR_WARN=$'\033[33m'
    readonly COLOR_OFF=$'\033[0m'
else
    readonly COLOR_PASS="" COLOR_FAIL="" COLOR_WARN="" COLOR_OFF=""
fi

info() { printf '%s\n' "$*"; }
abort() { printf '%sABORT%s %s\n' "$COLOR_FAIL" "$COLOR_OFF" "$*" >&2; exit 2; }

report_pass() {
    tests_passed=$((tests_passed + 1))
    printf '%sPASS%s %s\n' "$COLOR_PASS" "$COLOR_OFF" "$1"
}

report_fail() {
    tests_failed=$((tests_failed + 1))
    failure_seen=1
    printf '%sFAIL%s %s\n' "$COLOR_FAIL" "$COLOR_OFF" "$1"
    printf '       expected: %s\n' "$2"
    printf '       actual:   %s\n' "$3"
}

# check <name> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then
        report_pass "$1"
    else
        report_fail "$1" "$2" "$3"
    fi
}

# check_near <name> <expected-us> <actual-us>
check_near() {
    local delta=$(( $2 - $3 ))
    if [ "$delta" -lt 0 ]; then delta=$(( -delta )); fi
    if [ "$delta" -le "$TIME_TOLERANCE_US" ]; then
        report_pass "$1"
    else
        report_fail "$1" "$2 (+/- $TIME_TOLERANCE_US us)" "$3"
    fi
}

# xcheck <name> <expected> <actual> - a test for a known-open bug. Failing is
# the documented current behavior and does not fail the suite; passing means
# the bug is fixed and the test should be promoted to a plain check.
xcheck() {
    if [ "$2" = "$3" ]; then
        tests_xpassed=$((tests_xpassed + 1))
        printf '%sXPASS%s %s\n' "$COLOR_WARN" "$COLOR_OFF" "$1"
        printf '       This known bug appears to be fixed. Promote xcheck -> check.\n'
    else
        tests_xfailed=$((tests_xfailed + 1))
        printf '%sXFAIL%s %s (known bug)\n' "$COLOR_WARN" "$COLOR_OFF" "$1"
        printf '       expected: %s\n' "$2"
        printf '       actual:   %s\n' "$3"
    fi
}

# --- Hands-off monitoring --------------------------------------------------
#
# Nothing here prevents a human from using the machine mid-run; macOS offers no
# supported way to block input, and a modal "wait" dialog would be worse than
# useless - it has to be frontmost in some process, and this harness needs VLC
# frontmost to drive its menu bar. So interference is detected instead.
#
# IOHIDSystem's HIDIdleTime is nanoseconds since the last real hardware input
# event. The accessibility actions dispatched below - AXPress, AXSetValue,
# application activation - do not reset it: measured over a complete run, 110
# samples taken 0.25s apart across menu clicks, button presses, text-field
# writes and seeks, with zero resets. The counter therefore rises steadily for
# as long as nobody touches the machine, and any reading below the previous one
# is a hardware event. That is an exact signal and needs no clock, which matters
# because bash has no portable sub-second timer to compare elapsed time against.
#
# Blind spot: input is missed if the previous reading was already small enough
# that the new one still exceeds it, which only happens when the machine was in
# use moments before. input_watch_init reports that case separately.

user_input_seen=0
input_monitor_ok=1
last_idle_ns=0

hid_idle_ns() {
    ioreg -c IOHIDSystem -r -d 1 2>/dev/null \
        | grep -o '"HIDIdleTime" = [0-9]*' | head -1 | awk '{print $3}'
}

input_watch_init() {
    last_idle_ns="$(hid_idle_ns)"
    if [ -z "$last_idle_ns" ]; then
        input_monitor_ok=0
        info "Hands-off monitoring unavailable: IOHIDSystem reports no HIDIdleTime."
        return
    fi
    if [ "$last_idle_ns" -lt $(( IDLE_AT_START_WARN_S * NANOS_PER_SECOND )) ]; then
        printf '%sNOTE%s the machine was in use as this run started, so input during\n' \
            "$COLOR_WARN" "$COLOR_OFF"
        printf '     the first phase may go undetected.\n'
    fi
}

# input_watch_check <phase> - flag any hardware input since the last reading.
input_watch_check() {
    [ "$input_monitor_ok" -eq 1 ] || return 0
    local now
    now="$(hid_idle_ns)"
    [ -n "$now" ] || return 0
    if [ "$now" -lt "$last_idle_ns" ]; then
        user_input_seen=1
        printf '%sINPUT%s keyboard, mouse or trackpad activity during %s\n' \
            "$COLOR_WARN" "$COLOR_OFF" "$1"
    fi
    last_idle_ns="$now"
}

# --- AppleScript helpers ---------------------------------------------------

osa() { osascript "$@"; }

# osa_retry <applescript> - run one AppleScript statement, retrying transient
# accessibility failures. The last attempt is unredirected so a genuine error
# still surfaces. Only used for statements that are safe to repeat: a failed
# accessibility call has not dispatched its action.
osa_retry() {
    local tries=0 out
    while [ "$tries" -lt $((AX_RETRY_TRIES - 1)) ]; do
        if out="$(osa -e "$1" 2>/dev/null)"; then
            printf '%s' "$out"
            return 0
        fi
        sleep "$AX_RETRY_DELAY_S"
        tries=$((tries + 1))
    done
    osa -e "$1"
}

# Every accessibility statement is addressed to the extension dialog.
in_dialog() {
    printf 'tell application "System Events" to tell process "%s" to %s of window "%s"' \
        "$VLC_APP_NAME" "$1" "$DIALOG_TITLE"
}

vlc_is_running() { pgrep -x "$VLC_APP_NAME" >/dev/null 2>&1; }

vlc_current_time() {
    osa -e "tell application \"$VLC_APP_NAME\" to return current time"
}

vlc_pause() {
    # VLC's "play" command toggles, so only send it while actually playing.
    osa -e "tell application \"$VLC_APP_NAME\" to if playing then play" >/dev/null
    sleep "$UI_SETTLE_S"
}

vlc_seek() {
    osa -e "tell application \"$VLC_APP_NAME\" to set current time to $1" >/dev/null
    sleep "$UI_SETTLE_S"
}

extension_menu_ready() {
    osa -e "tell application \"System Events\" to tell process \"$VLC_APP_NAME\" to return exists menu item \"$DIALOG_TITLE\" of menu 1 of menu item \"Extensions\" of menu 1 of menu bar item \"$VLC_APP_NAME\" of menu bar 1" 2>/dev/null || echo "false"
}

click_extension_menu() {
    osa >/dev/null 2>&1 <<EOF || true
tell application "$VLC_APP_NAME" to activate
delay $UI_SETTLE_S
tell application "System Events" to tell process "$VLC_APP_NAME"
    click menu item "$DIALOG_TITLE" of menu 1 of menu item "Extensions" of menu 1 of menu bar item "$VLC_APP_NAME" of menu bar 1
end tell
EOF
}

# Opens the extension dialog, retrying the menu click if it does not appear.
# Re-clicking is gated on the dialog being absent: once the extension is active
# its Extensions entry turns into a submenu, so a blind second click would not
# mean the same thing.
dialog_open() {
    local attempt=0 tries
    while [ "$attempt" -lt "$DIALOG_OPEN_ATTEMPTS" ]; do
        if [ "$(dialog_exists)" = "true" ]; then return 0; fi
        click_extension_menu
        tries=0
        while [ "$tries" -lt "$DIALOG_WAIT_TRIES" ]; do
            if [ "$(dialog_exists)" = "true" ]; then return 0; fi
            sleep "$LAUNCH_POLL_S"
            tries=$((tries + 1))
        done
        attempt=$((attempt + 1))
    done
    return 1
}

dialog_exists() {
    osa -e "tell application \"System Events\" to tell process \"$VLC_APP_NAME\" to return exists window \"$DIALOG_TITLE\"" 2>/dev/null || echo "false"
}

# dialog_set_input <text> - text must not contain double quotes or backslashes.
dialog_set_input() {
    osa_retry "$(in_dialog "set value of text field 1") to \"$1\"" >/dev/null
    sleep "$UI_SETTLE_S"
}

dialog_get_input() {
    osa_retry "$(in_dialog "return value of text field 1")"
}

dialog_click() {
    osa_retry "$(in_dialog "click button \"$1\"")" >/dev/null
    sleep "$ACTION_SETTLE_S"
}

# Accessibility row selection replaces the selection rather than extending it,
# so multi-item selection code paths cannot be reached from this harness.
dialog_select_row() {
    osa_retry "$(in_dialog "set selected of row $1 of table 1 of scroll area 1") to true" >/dev/null
    sleep "$UI_SETTLE_S"
}

# dialog_has_button <name> - existence only. Show in Finder is deliberately
# never clicked here: it launches Finder, which steals focus mid-run and would
# be read as hardware input by the hands-off monitor.
dialog_has_button() {
    osa_retry "$(in_dialog "return exists button \"$1\"")"
}

dialog_row_count() {
    osa_retry "$(in_dialog "return count of rows of table 1 of scroll area 1")"
}

dialog_row_text() {
    osa_retry "$(in_dialog "return value of text field 1 of row $1 of table 1 of scroll area 1")"
}

# --- Bookmark file helpers -------------------------------------------------

# TSV, one line per bookmark: index, time (us), formattedTime, label. The file
# is JSON, so jq reads it directly and doubles as a parse check - malformed
# output from the extension fails here rather than being quietly tolerated.
bookmarks_dump() {
    [ -e "$BOOKMARK_FILE" ] || return 0
    jq -r '.bookmarks | to_entries[]
           | [(.key + 1), .value.time, .value.formattedTime, .value.label]
           | @tsv' "$BOOKMARK_FILE"
}

bookmarks_count() { bookmarks_dump | grep -c . || true; }

# bookmarks_field <row> <column>  (columns: 1 index, 2 time, 3 formatted, 4 label)
bookmarks_field() { bookmarks_dump | sed -n "${1}p" | cut -f"$2"; }

bookmarks_labels() { bookmarks_dump | cut -f4 | paste -sd, - ; }

# --- Setup and teardown ----------------------------------------------------

WORK_DIR=""
VLC_PID=""
BOOKMARK_FILE=""

cleanup() {
    local status=$?
    # VLC is started through LaunchServices, so there is no owned pid to signal.
    # Preflight guarantees no VLC was running before this script started, so any
    # VLC alive now is the one this run launched.
    if vlc_is_running; then
        osa -e "tell application \"$VLC_APP_NAME\" to quit" >/dev/null 2>&1 || true
        local waited=0
        while [ "$waited" -lt "$QUIT_TIMEOUT_TRIES" ] && vlc_is_running; do
            sleep "$LAUNCH_POLL_S"
            waited=$((waited + 1))
        done
        if vlc_is_running; then pkill -x "$VLC_APP_NAME" 2>/dev/null || true; fi
    fi
    # Only ever the fixture's own bookmark file.
    if [ -n "$BOOKMARK_FILE" ]; then rm -f "$BOOKMARK_FILE"; fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$status" -eq 0 ] && [ "$failure_seen" -eq 0 ]; then
            rm -rf "$WORK_DIR"
        else
            info ""
            info "Working directory kept for inspection: $WORK_DIR"
            info "VLC log: $WORK_DIR/vlc.log"
        fi
    fi
    return $status
}
trap cleanup EXIT

preflight() {
    info "=== Preflight ==="

    local missing=""
    for cmd in ffmpeg jq osascript; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then abort "missing required command(s):$missing"; fi
    [ -d "$VLC_APP_BUNDLE" ] || abort "VLC not found at $VLC_APP_BUNDLE"

    osa -e 'tell application "System Events" to return name of first process whose frontmost is true' >/dev/null 2>&1 \
        || abort "System Events is not scriptable. Grant Accessibility permission to this terminal application in System Settings > Privacy & Security > Accessibility."

    if vlc_is_running; then
        abort "VLC is already running. Quit it first - this test needs to control VLC's lifecycle and will not touch an existing session."
    fi

    local installed="$EXTENSIONS_DIR/$EXTENSION_FILE"
    [ -e "$installed" ] || abort "extension is not installed at $installed"
    local resolved
    resolved="$(readlink -f "$installed" 2>/dev/null || true)"
    if [ "$resolved" != "$REPO_DIR/$EXTENSION_FILE" ]; then
        abort "installed extension resolves to '$resolved', not the repo file '$REPO_DIR/$EXTENSION_FILE'. The test would not be testing this working tree."
    fi
    info "Extension under test: $resolved"
    info "Leave the keyboard, mouse and trackpad alone until the summary prints."
    input_watch_init
}

make_fixture() {
    info ""
    info "=== Fixture ==="
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vlc-bookmarks-smoke.XXXXXX")"
    FIXTURE="$WORK_DIR/$FIXTURE_NAME"
    LOG_FILE="$WORK_DIR/vlc.log"
    ffmpeg -y -loglevel error \
        -f lavfi -i "testsrc=duration=$FIXTURE_DURATION_S:size=$FIXTURE_RESOLUTION:rate=$FIXTURE_FPS" \
        -g "$FIXTURE_KEYFRAME_FRAMES" -pix_fmt yuv420p "$FIXTURE" \
        || abort "ffmpeg failed to generate the fixture"
    info "Generated $FIXTURE ($(wc -c < "$FIXTURE" | tr -d ' ') bytes)"
}

launch_vlc() {
    info ""
    info "=== Launch ==="
    # Launch through LaunchServices, not by running the binary directly. Any
    # "tell application" auto-launches VLC if it is not registered yet, and
    # racing that against a directly-executed binary produces two VLC processes:
    # one playing the fixture and writing the log, another owning the menu bar
    # and the extension dialog. Every AppleScript below would then address the
    # wrong one.
    open -a "$VLC_APP_BUNDLE" --args -vv --file-logging --logfile="$LOG_FILE" "$FIXTURE" \
        || abort "failed to launch $VLC_APP_BUNDLE"

    local tries=0
    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        if vlc_is_running; then break; fi
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done
    [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ] || abort "VLC did not start"
    VLC_PID="$(pgrep -x "$VLC_APP_NAME" | head -1)"

    tries=0
    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        if [ "$(osa -e "tell application \"$VLC_APP_NAME\" to return playing" 2>/dev/null || true)" = "true" ]; then
            break
        fi
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done
    [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ] || abort "VLC did not start playing the fixture in time - see $LOG_FILE"

    local vlc_processes
    vlc_processes="$(pgrep -x "$VLC_APP_NAME" | grep -c . || true)"
    if [ "$vlc_processes" != "1" ]; then
        abort "expected exactly one VLC process, found $vlc_processes ($(pgrep -x "$VLC_APP_NAME" | tr '\n' ' ')). The accessibility API would address an arbitrary one."
    fi

    # The Extensions menu is built after the extension scan; clicking before it
    # is populated is the main source of flakiness here.
    osa -e "tell application \"$VLC_APP_NAME\" to activate" >/dev/null 2>&1 || true
    tries=0
    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        if [ "$(extension_menu_ready)" = "true" ]; then break; fi
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done
    [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ] || abort "the extension never appeared in the Extensions menu - is it installed?"
    info "VLC running (pid $VLC_PID), extension present in the Extensions menu"
}

open_dialog_and_resolve_bookmark_file() {
    info ""
    info "=== Open extension ==="
    dialog_open || abort "the extension dialog did not open after $DIALOG_OPEN_ATTEMPTS attempts - see $LOG_FILE"

    # getFileHash() runs on activation and logs the hash it computed. Reading it
    # from the log avoids reimplementing that arithmetic here.
    local tries=0 hash=""
    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        hash="$(grep -o 'File hash: [0-9a-f]*' "$LOG_FILE" 2>/dev/null | tail -1 | awk '{print $3}' || true)"
        if [ -n "$hash" ]; then break; fi
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done
    if [ -z "$hash" ]; then
        # Most likely cause: the accessibility API and the log belong to
        # different VLC processes, so print enough to tell that apart.
        info "  windows:       $(osa -e "tell application \"System Events\" to tell process \"$VLC_APP_NAME\" to return name of every window" 2>&1 || true)"
        info "  vlc processes: $(pgrep -x "$VLC_APP_NAME" | tr '\n' ' ')"
        info "  activations logged: $(grep -c 'Activate extension' "$LOG_FILE" || true)"
        abort "the extension never logged a file hash - see $LOG_FILE"
    fi

    local candidate="$BOOKMARKS_DIR/$hash$BOOKMARK_FILE_EXT"
    info "Fixture hash: $hash"
    info "Bookmark file: $candidate"
    if [ -e "$candidate" ]; then
        abort "a bookmark file already exists for the fixture hash. Refusing to overwrite pre-existing data at $candidate"
    fi
    # Assigned only once the guard above has passed. cleanup() deletes
    # BOOKMARK_FILE, so anything assigned before the guard would be destroyed by
    # the EXIT trap on the very abort that refused to touch it.
    BOOKMARK_FILE="$candidate"
}

# --- Tests -----------------------------------------------------------------

test_fresh_medium() {
    info ""
    info "=== Tests ==="
    check "a fresh medium starts with no bookmark file" "absent" \
        "$([ -e "$BOOKMARK_FILE" ] && echo present || echo absent)"
    check "a fresh medium shows an empty list" "0" "$(dialog_row_count)"
    check "the default label starts at index 1" "Bookmark (1)" "$(dialog_get_input)"
    check "the dialog offers Show in Finder" "true" "$(dialog_has_button "Show in Finder")"
}

test_add() {
    vlc_pause
    vlc_seek "$T_ALPHA"
    dialog_set_input "alpha"
    dialog_click "Add"

    check "add: bookmark file is created" "present" \
        "$([ -e "$BOOKMARK_FILE" ] && echo present || echo absent)"
    check "add: one bookmark is saved" "1" "$(bookmarks_count)"
    check "add: the label is saved" "alpha" "$(bookmarks_field 1 4)"
    check_near "add: the playback time is saved" "$((T_ALPHA * MICROS_PER_SECOND))" "$(bookmarks_field 1 2)"
    check "add: the list shows one row" "1" "$(dialog_row_count)"
}

test_add_ordering() {
    vlc_seek "$T_BETA"
    dialog_set_input "beta"
    dialog_click "Add"
    check "add: a later bookmark appends" "alpha,beta" "$(bookmarks_labels)"

    vlc_seek "$T_GAMMA"
    dialog_set_input "gamma"
    dialog_click "Add"
    check "add: an earlier bookmark sorts to the front" "gamma,alpha,beta" "$(bookmarks_labels)"
    check "add: three bookmarks are saved" "3" "$(bookmarks_count)"
    check "add: the list matches the saved file" "3" "$(dialog_row_count)"
    check "add: row text is index, time and label" \
        "#1 - 00:00:$(printf '%02d' "$T_GAMMA").000 - gamma" "$(dialog_row_text 1)"
}

test_rename() {
    dialog_select_row 1
    dialog_click "Rename"
    check "rename: Rename loads the selected label into the input" "gamma" "$(dialog_get_input)"

    dialog_set_input "gamma-renamed"
    dialog_click "Add"
    check "rename: Add commits the new label" "gamma-renamed,alpha,beta" "$(bookmarks_labels)"
    check "rename: the bookmark count is unchanged" "3" "$(bookmarks_count)"
    check_near "rename: the bookmark time is unchanged" "$((T_GAMMA * MICROS_PER_SECOND))" "$(bookmarks_field 1 2)"
}

test_go() {
    vlc_seek "$T_ELSEWHERE"
    check "go: precondition - playback moved away" "$T_ELSEWHERE" "$(vlc_current_time)"

    dialog_select_row 2
    dialog_click "Go"
    check "go: playback jumps to the selected bookmark" "$T_ALPHA" "$(vlc_current_time)"
}

test_remove() {
    dialog_select_row 2
    dialog_click "Remove"
    check "remove: the selected bookmark is deleted" "gamma-renamed,beta" "$(bookmarks_labels)"
    check "remove: two bookmarks remain" "2" "$(bookmarks_count)"
    check "remove: the list matches the saved file" "2" "$(dialog_row_count)"
    check "remove: surviving times are intact" "$((T_BETA * MICROS_PER_SECOND))" "$(bookmarks_field 2 2)"
}

test_default_label_index() {
    # The default label is derived from a "(N)" suffix on the last bookmark,
    # not from the bookmark count.
    vlc_seek "$T_ELSEWHERE"
    dialog_set_input "Bookmark (7)"
    dialog_click "Add"
    check "default label: derived from the last bookmark's (N) suffix" "Bookmark (8)" "$(dialog_get_input)"

    dialog_select_row 3
    dialog_click "Remove"
    check "default label: cleanup left two bookmarks" "2" "$(bookmarks_count)"
}

test_label_whitespace() {
    local before
    before="$(bookmarks_count)"
    dialog_set_input "   "
    dialog_click "Add"
    check "a whitespace-only label is rejected" "$before" "$(bookmarks_count)"

    # Surrounding whitespace is stripped, so the stored label is the trimmed one.
    vlc_seek "$T_ELSEWHERE"
    dialog_set_input "  padded  "
    dialog_click "Add"
    check "a padded label is stored trimmed" "padded" "$(bookmarks_field 3 4)"

    dialog_select_row 3
    dialog_click "Remove"
    check "trim: cleanup left two bookmarks" "$before" "$(bookmarks_count)"
}

test_no_lua_errors() {
    local errors
    errors="$(grep -ciE 'lua (error|warning)' "$LOG_FILE" || true)"
    if [ "$errors" != "0" ]; then
        info "  --- Lua diagnostics from the log ---"
        grep -iE 'lua (error|warning)' "$LOG_FILE" | sed 's/^/  /'
    fi
    check "no Lua errors or warnings were logged" "0" "$errors"
}

# --- Main ------------------------------------------------------------------

main() {
    preflight
    make_fixture
    launch_vlc
    open_dialog_and_resolve_bookmark_file

    local phase
    for phase in test_fresh_medium test_add test_add_ordering test_rename \
                 test_go test_remove test_default_label_index \
                 test_label_whitespace test_no_lua_errors; do
        "$phase"
        input_watch_check "$phase"
    done

    info ""
    info "=== Summary ==="
    info "passed: $tests_passed  failed: $tests_failed  xfail: $tests_xfailed  xpass: $tests_xpassed"
    if [ "$user_input_seen" -eq 1 ]; then
        info ""
        printf '%sThe machine was used while this run was in progress.%s\n' "$COLOR_WARN" "$COLOR_OFF"
        if [ "$tests_failed" -ne 0 ]; then
            info "Failures above may be interference rather than regressions. Re-run"
            info "without touching the machine before believing any of them."
        else
            info "It passed anyway, but a hands-off run is the only trustworthy one."
        fi
    fi
    info ""
    info "Not covered: multi-item selection. The accessibility API replaces the"
    info "list selection rather than extending it, so the multi-select paths in"
    info "removeBookmark(), goToBookmark() and editBookmark() cannot be reached"
    info "from this harness."

    [ "$tests_failed" -eq 0 ] || exit 1
}

main "$@"
