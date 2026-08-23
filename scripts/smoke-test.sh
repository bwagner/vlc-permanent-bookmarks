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
# Footer text. Two distinct strings on purpose: one describes the state, the
# other answers a click. Sharing one made a refusal invisible.
readonly MSG_NO_MEDIA="No media playing"
readonly MSG_ADD_NO_MEDIA="Nothing to bookmark - no media is playing"
# Remove is two-step: Remove arms and names the count, Delete commits. Only the
# single-bookmark wording is reachable here - the accessibility API cannot build
# a multi-row selection.
readonly MSG_REMOVE_PENDING_ONE="Removing 1 bookmark - click Delete to commit"
readonly MSG_REMOVE_NOT_PENDING="Click Remove first to choose what to delete"
readonly MSG_REMOVE_SELECTION_CHANGED="Selection changed - reselect to delete"
# Shown when a medium has an old-format bookmark file and no JSON beside it.
# The extension will not save over it, so the medium is read-only until the
# migration script runs.
readonly MSG_LEGACY_FOUND="Bookmarks are in the old format - run the migration script"

# Fixture: 5 minutes of testsrc. The keyframe interval equals the frame rate, so
# there is a keyframe every second and seeks land exactly on the second asked
# for. Must exceed 64 KB so getFileHash() takes its normal two-chunk path.
readonly FIXTURE_NAME="smoke-fixture.mp4"
readonly FIXTURE_DURATION_S=300
# A second medium, so a track change can be tested. A different duration means
# different bytes and a different size, so it hashes to its own bookmark file.
readonly FIXTURE2_NAME="smoke-fixture-2.mp4"
readonly FIXTURE2_DURATION_S=180
# A third medium, played only by the legacy read-only test. An old-format
# bookmark file is planted at its hash before VLC starts, so it is the one
# fixture whose bookmark file exists before the extension ever sees it.
readonly FIXTURE3_NAME="smoke-fixture-3.mp4"
readonly FIXTURE3_DURATION_S=240
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

# The legacy file has to be planted before VLC starts, which means knowing the
# fixture's hash before the extension logs it. This is the repo's port of
# getFileHash(); the run also asserts the two agree, so a drift between them
# fails here instead of silently misleading whoever reaches for the script.
readonly MEDIA_HASH_SCRIPT="$REPO_DIR/scripts/media_hash.py"
# Run through python3 rather than the script's uv shebang: it declares no
# dependencies, so uv would only be another thing to have installed.
readonly PYTHON="python3"
# Two diagnostics the legacy phase provokes on purpose: the extension is right
# to warn that an old-format file is there, and right to log a refusal when the
# Add tries to save over it. Both are excluded by their exact text rather than
# by loosening the pattern, so nothing else that looks like Lua trouble hides
# behind them. Both name the planted file - see plant_legacy_bookmark_file().
readonly EXPECTED_LOG_LEGACY_WARNING="Old-format bookmark file found:"
readonly EXPECTED_LOG_LEGACY_REFUSAL="Refusing to save over bookmarks that were not read:"

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

vlc_next() {
    osa -e "tell application \"$VLC_APP_NAME\" to next" >/dev/null
    sleep "$ACTION_SETTLE_S"
}

vlc_stop() {
    osa -e "tell application \"$VLC_APP_NAME\" to stop" >/dev/null
    sleep "$ACTION_SETTLE_S"
}

# vlc_open <path> - load and play a medium by name. Used where "play" would be
# ambiguous: after a stop it is not defined which playlist entry resumes, and
# the no-input test needs to know exactly which medium comes back.
vlc_open() {
    osa -e "tell application \"$VLC_APP_NAME\" to open POSIX file \"$1\"" >/dev/null
    sleep "$ACTION_SETTLE_S"
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

# Remove arms, Delete commits. Steps that only need a row gone use this, so the
# two-step is exercised at every call site instead of only in test_remove().
dialog_remove_selected() {
    dialog_click "Remove"
    dialog_click "Delete"
}

# dialog_has_button <name> - existence only. Show in Finder is deliberately
# never clicked here: it launches Finder, which steals focus mid-run and would
# be read as hardware input by the hands-off monitor.
dialog_has_button() {
    osa_retry "$(in_dialog "return exists button \"$1\"")"
}

# The label input. The no-input dialog is a single label with no widgets, so
# this is what separates it from the real one - the same test the extension
# itself uses in reloadCurrentMedium().
dialog_has_text_field() {
    osa_retry "$(in_dialog "return exists text field 1")"
}

# The footer label. "static text 1" is the footer and not the window title,
# which reads back as "static text \"VLC Permanent Bookmarks\"" - verified
# against three different messages on VLC 3.0.23.
dialog_footer() {
    osa_retry "$(in_dialog "return value of static text 1")"
}

# How many rows are selected. The dialog API has no deselect call, so the only
# way to clear a selection is rebuilding the list - this is what says whether
# that works.
dialog_selected_rows() {
    osa_retry "$(in_dialog "return count of (rows of table 1 of scroll area 1 whose selected is true)")"
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

# The medium's file name, recorded as meta-information. Empty when the field is
# absent, which is what an extension that stopped writing it would produce.
bookmarks_filename() {
    [ -e "$BOOKMARK_FILE" ] || return 0
    jq -r '.filename // ""' "$BOOKMARK_FILE"
}

# The hash the extension logged most recently. getFileHash() logs one line per
# load, so this names whichever medium was loaded last.
latest_logged_hash() {
    grep -o 'File hash: [0-9a-f]*' "$LOG_FILE" 2>/dev/null | tail -1 | awk '{print $3}' || true
}

# How many media the extension has hashed so far. input_changed() fires twice
# per track change, so this is what proves the second call was skipped.
hash_log_count() { grep -c 'File hash: ' "$LOG_FILE" || true; }

# --- Setup and teardown ----------------------------------------------------

WORK_DIR=""
VLC_PID=""
BOOKMARK_FILE=""
# Every bookmark file this run claimed, all removed by cleanup(). A run touches
# one per medium it plays.
BOOKMARK_FILES=()
# Files this run wrote into the bookmarks directory itself rather than through
# the extension: the planted old-format file, and the JSON path beside it that
# must stay absent. Both are removed by cleanup(), the second so a regression
# that does write it leaves nothing behind.
PLANTED_FILES=()
FIXTURE3_HASH=""
LEGACY_FILE=""
LEGACY_JSON_FILE=""
LEGACY_MD5=""

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
    # Only ever the fixtures' own bookmark files.
    local claimed
    for claimed in ${BOOKMARK_FILES[@]+"${BOOKMARK_FILES[@]}"}; do rm -f "$claimed"; done
    local planted
    for planted in ${PLANTED_FILES[@]+"${PLANTED_FILES[@]}"}; do rm -f "$planted"; done
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
    for cmd in ffmpeg jq osascript md5 "$PYTHON"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    if [ -n "$missing" ]; then abort "missing required command(s):$missing"; fi
    [ -d "$VLC_APP_BUNDLE" ] || abort "VLC not found at $VLC_APP_BUNDLE"
    [ -f "$MEDIA_HASH_SCRIPT" ] || abort "media_hash.py not found at $MEDIA_HASH_SCRIPT"

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

# generate_fixture <path> <duration_s>
generate_fixture() {
    ffmpeg -y -loglevel error \
        -f lavfi -i "testsrc=duration=$2:size=$FIXTURE_RESOLUTION:rate=$FIXTURE_FPS" \
        -g "$FIXTURE_KEYFRAME_FRAMES" -pix_fmt yuv420p "$1" \
        || abort "ffmpeg failed to generate $1"
    info "Generated $1 ($(wc -c < "$1" | tr -d ' ') bytes)"
}

make_fixture() {
    info ""
    info "=== Fixtures ==="
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vlc-bookmarks-smoke.XXXXXX")"
    FIXTURE="$WORK_DIR/$FIXTURE_NAME"
    FIXTURE2="$WORK_DIR/$FIXTURE2_NAME"
    FIXTURE3="$WORK_DIR/$FIXTURE3_NAME"
    LOG_FILE="$WORK_DIR/vlc.log"
    generate_fixture "$FIXTURE" "$FIXTURE_DURATION_S"
    generate_fixture "$FIXTURE2" "$FIXTURE2_DURATION_S"
    generate_fixture "$FIXTURE3" "$FIXTURE3_DURATION_S"
}

# The extension only ever writes JSON, so the state the legacy path needs - an
# old-format file with no JSON beside it - cannot be reached by driving the
# dialog. It is planted here instead, before VLC starts, at the hash the third
# fixture will produce. The content is a real old-format chunk, though the
# extension never parses it: it checks the file exists and refuses to save.
plant_legacy_bookmark_file() {
    info ""
    info "=== Legacy fixture ==="
    FIXTURE3_HASH="$("$PYTHON" "$MEDIA_HASH_SCRIPT" -q "$FIXTURE3")" \
        || abort "media_hash.py could not hash $FIXTURE3"
    [ -n "$FIXTURE3_HASH" ] || abort "media_hash.py printed no hash for $FIXTURE3"

    LEGACY_FILE="$BOOKMARKS_DIR/$FIXTURE3_HASH"
    LEGACY_JSON_FILE="$BOOKMARKS_DIR/$FIXTURE3_HASH$BOOKMARK_FILE_EXT"
    info "Legacy fixture hash: $FIXTURE3_HASH"
    info "Planting: $LEGACY_FILE"

    # The same refusal claim_bookmark_file() makes, for both names this time.
    # A pre-existing file at either path is somebody's data, and the run would
    # both misread it and delete it on the way out.
    if [ -e "$LEGACY_FILE" ]; then
        abort "a bookmark file already exists at $LEGACY_FILE. Refusing to overwrite pre-existing data"
    elif [ -e "$LEGACY_JSON_FILE" ]; then
        abort "a bookmark file already exists at $LEGACY_JSON_FILE. Refusing to overwrite pre-existing data"
    fi

    mkdir -p "$BOOKMARKS_DIR"
    cat > "$LEGACY_FILE" <<'LEGACY'
return {
-- Table: {1}
{
   {2},
},
-- Table: {2}
{
   ["formattedTime"]="00:01:00.000",
   ["time"]=60000000,
   ["label"]="planted by the smoke test",
},
}
LEGACY
    # Registered only after the guard passed, for the reason claim_bookmark_file
    # gives: the EXIT trap deletes everything on this list, including on an
    # abort that refused to touch the file.
    PLANTED_FILES+=("$LEGACY_FILE" "$LEGACY_JSON_FILE")
    LEGACY_MD5="$(md5 -q "$LEGACY_FILE")"
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
    # All three fixtures, so the playlist has somewhere to advance to. VLC plays
    # the first; nothing reaches the second until the track-change test asks for
    # it, nor the third until the legacy test does.
    open -a "$VLC_APP_BUNDLE" --args -vv --file-logging --logfile="$LOG_FILE" "$FIXTURE" "$FIXTURE2" "$FIXTURE3" \
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

    info "Fixture hash: $hash"
    claim_bookmark_file "$hash"
}

# claim_bookmark_file <hash> - point the bookmark helpers at that medium's file
# and hand it to cleanup(), refusing outright if the file already exists.
claim_bookmark_file() {
    local candidate="$BOOKMARKS_DIR/$1$BOOKMARK_FILE_EXT"
    info "Bookmark file: $candidate"
    if [ -e "$candidate" ]; then
        abort "a bookmark file already exists for hash $1. Refusing to overwrite pre-existing data at $candidate"
    fi
    # Assigned only once the guard above has passed. cleanup() deletes every
    # claimed file, so anything recorded before the guard would be destroyed by
    # the EXIT trap on the very abort that refused to touch it.
    BOOKMARK_FILE="$candidate"
    BOOKMARK_FILES+=("$candidate")
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
    check "the dialog offers Confirm" "true" "$(dialog_has_button "Confirm")"
}

test_add() {
    vlc_pause
    vlc_seek "$T_ALPHA"
    dialog_set_input "alpha"
    dialog_click "Add"

    check "add: bookmark file is created" "present" \
        "$([ -e "$BOOKMARK_FILE" ] && echo present || echo absent)"
    check "add: one bookmark is saved" "1" "$(bookmarks_count)"
    check "add: the medium's file name is recorded" "$FIXTURE_NAME" "$(bookmarks_filename)"
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
    # The row shows hh:mm:ss. The file keeps the milliseconds - see the
    # stored-precision check below.
    check "add: row text is index, time and label" \
        "#1 - 00:00:$(printf '%02d' "$T_GAMMA") - gamma" "$(dialog_row_text 1)"
    check "add: the file keeps millisecond precision" \
        "00:00:$(printf '%02d' "$T_GAMMA").000" "$(bookmarks_field 1 3)"
}

test_rename() {
    dialog_select_row 1
    dialog_click "Rename"
    check "rename: Rename loads the selected label into the input" "gamma" "$(dialog_get_input)"

    dialog_set_input "gamma-renamed"
    dialog_click "Confirm"
    check "rename: Confirm commits the new label" "gamma-renamed,alpha,beta" "$(bookmarks_labels)"
    check "rename: the bookmark count is unchanged" "3" "$(bookmarks_count)"
    check_near "rename: the bookmark time is unchanged" "$((T_GAMMA * MICROS_PER_SECOND))" "$(bookmarks_field 1 2)"

    # Confirm consumed the pending rename, so a second click has nothing to commit.
    dialog_set_input "stray"
    dialog_click "Confirm"
    check "rename: Confirm with nothing pending changes nothing" "gamma-renamed,alpha,beta" "$(bookmarks_labels)"
}

test_go() {
    vlc_seek "$T_ELSEWHERE"
    check "go: precondition - playback moved away" "$T_ELSEWHERE" "$(vlc_current_time)"

    dialog_select_row 2
    dialog_click "Go"
    check "go: playback jumps to the selected bookmark" "$T_ALPHA" "$(vlc_current_time)"
}

# Remove arms and Delete commits, so a deletion takes two deliberate clicks on
# two different buttons - a double-click on one button cannot arm and commit.
# The refusals carry the weight here: an armed removal that committed against a
# row the user had reselected would delete the wrong bookmark silently.
test_remove() {
    local before
    before="$(bookmarks_count)"

    check "remove: the Delete button exists" "true" "$(dialog_has_button "Delete")"

    dialog_select_row 2
    dialog_click "Delete"
    check "remove: Delete alone deletes nothing" "$before" "$(bookmarks_count)"
    check "remove: Delete alone says what is missing" "$MSG_REMOVE_NOT_PENDING" "$(dialog_footer)"

    dialog_click "Remove"
    check "remove: Remove alone deletes nothing" "$before" "$(bookmarks_count)"
    check "remove: Remove announces the armed count" "$MSG_REMOVE_PENDING_ONE" "$(dialog_footer)"

    # Selection moved off the armed row: refused, and the arming is kept so the
    # user can reselect rather than start over.
    dialog_select_row 1
    dialog_click "Delete"
    check "remove: Delete refuses when the selection moved" "$before" "$(bookmarks_count)"
    check "remove: the refusal asks for a reselect" "$MSG_REMOVE_SELECTION_CHANGED" "$(dialog_footer)"

    dialog_select_row 2
    dialog_click "Delete"
    check "remove: the selected bookmark is deleted" "gamma-renamed,beta" "$(bookmarks_labels)"
    check "remove: two bookmarks remain" "2" "$(bookmarks_count)"
    check "remove: the list matches the saved file" "2" "$(dialog_row_count)"
    check "remove: surviving times are intact" "$((T_BETA * MICROS_PER_SECOND))" "$(bookmarks_field 2 2)"
    # Known open: the dialog API has no deselect call, and a rebuilt list keeps
    # its selected row, so a committed removal leaves the row under it selected.
    # Measured, not assumed - this read 1. Promote to check if VLC ever changes.
    xcheck "remove: the committed removal leaves nothing selected" "0" "$(dialog_selected_rows)"
}

# An insert shifts every index after it, so an armed removal cannot survive an
# Add - committing it afterwards would delete against stale indices.
test_remove_guards() {
    local before
    before="$(bookmarks_count)"

    dialog_select_row 1
    dialog_click "Remove"
    vlc_seek "$T_ELSEWHERE"
    dialog_set_input "added-not-removed"
    dialog_click "Add"
    check "guard: Add after Remove adds instead of removing" "$((before + 1))" "$(bookmarks_count)"

    dialog_click "Delete"
    check "guard: the armed removal did not survive the Add" "$((before + 1))" "$(bookmarks_count)"
    check "guard: Delete says the arming is gone" "$MSG_REMOVE_NOT_PENDING" "$(dialog_footer)"

    dialog_select_row 3
    dialog_remove_selected
    check "guard: cleanup left two bookmarks" "$before" "$(bookmarks_count)"

    # Any other button exits the remove cycle. The footer is cleared by every
    # callback anyway, so without this the arming would go on living invisibly
    # and a later Delete would commit it.
    dialog_select_row 1
    dialog_click "Remove"
    dialog_click "Go"
    dialog_click "Delete"
    check "guard: Go cancels an armed removal" "$before" "$(bookmarks_count)"
    check "guard: Delete after Go says the arming is gone" "$MSG_REMOVE_NOT_PENDING" "$(dialog_footer)"

    # Rename disarms too, but keeps the selection: confirmRename() refuses
    # unless the loaded row is still the selected one.
    dialog_select_row 1
    dialog_click "Remove"
    dialog_click "Rename"
    check "guard: Rename keeps its row selected" "1" "$(dialog_selected_rows)"
    dialog_click "Delete"
    check "guard: Rename cancels an armed removal" "$before" "$(bookmarks_count)"
    check "guard: Delete after Rename says the arming is gone" "$MSG_REMOVE_NOT_PENDING" "$(dialog_footer)"
}

test_default_label_index() {
    # The default label is derived from a "(N)" suffix on the last bookmark,
    # not from the bookmark count.
    vlc_seek "$T_ELSEWHERE"
    dialog_set_input "Bookmark (7)"
    dialog_click "Add"
    check "default label: derived from the last bookmark's (N) suffix" "Bookmark (8)" "$(dialog_get_input)"

    dialog_select_row 3
    dialog_remove_selected
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
    dialog_remove_selected
    check "trim: cleanup left two bookmarks" "$before" "$(bookmarks_count)"
}

# Rename loads a label and only Confirm commits it. Add always adds, and a pending
# rename refuses to land on a row other than the one it was loaded from - both
# were possible while Add doubled as the commit button.
test_rename_guards() {
    local before
    before="$(bookmarks_count)"

    dialog_select_row 1
    dialog_click "Rename"
    vlc_seek "$T_ELSEWHERE"
    dialog_set_input "added-not-renamed"
    dialog_click "Add"
    check "guard: Add after Rename adds instead of renaming" "$((before + 1))" "$(bookmarks_count)"
    check "guard: the loaded bookmark keeps its label" "gamma-renamed" "$(bookmarks_field 1 4)"

    dialog_select_row 3
    dialog_remove_selected
    check "guard: cleanup left two bookmarks" "$before" "$(bookmarks_count)"

    # Loaded from row 1, committed with row 2 selected: refused, nothing written.
    dialog_select_row 1
    dialog_click "Rename"
    dialog_set_input "drifted"
    dialog_select_row 2
    dialog_click "Confirm"
    check "guard: Confirm refuses when the selection moved" "gamma-renamed,beta" "$(bookmarks_labels)"

    # The refusal keeps the pending rename, so reselecting the row commits it
    # without having to load the label again.
    dialog_select_row 1
    dialog_click "Confirm"
    check "guard: reselecting the row commits the pending rename" "drifted,beta" "$(bookmarks_labels)"
}

# The dialog used to hide itself on every track change and had to be reopened
# from the menu. It now reloads in place, so the window survives and its
# contents follow the medium.
test_track_change() {
    local previous_file="$BOOKMARK_FILE"
    local previous_count previous_hash previous_loads tries=0
    previous_count="$(bookmarks_count)"
    previous_hash="$(latest_logged_hash)"
    previous_loads="$(hash_log_count)"

    vlc_next

    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        [ "$(latest_logged_hash)" != "$previous_hash" ] && break
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done

    check "track change: the dialog stays open" "true" "$(dialog_exists)"

    local hash
    hash="$(latest_logged_hash)"
    if [ "$hash" = "$previous_hash" ]; then
        report_fail "track change: the extension loads the new medium" \
            "a hash other than $previous_hash" "$hash"
        return
    fi
    report_pass "track change: the extension loads the new medium"

    # input_changed() fires twice per track change (measured on VLC 3.0.23),
    # both times reporting the new item. One load, not two.
    check "track change: the new medium is hashed exactly once" \
        "$((previous_loads + 1))" "$(hash_log_count)"

    info "Second fixture hash: $hash"
    claim_bookmark_file "$hash"

    check "track change: the list follows the new medium" "0" "$(dialog_row_count)"
    check "track change: the default label resets" "Bookmark (1)" "$(dialog_get_input)"

    vlc_pause
    vlc_seek "$T_GAMMA"
    dialog_set_input "second"
    dialog_click "Add"

    check "track change: a bookmark saves to the new medium's file" "1" "$(bookmarks_count)"
    check "track change: the new medium's file name is recorded" "$FIXTURE2_NAME" "$(bookmarks_filename)"
    check "track change: the previous medium's file is untouched" "$previous_count" \
        "$(jq -r '.bookmarks | length' "$previous_file")"
}

# A medium whose bookmarks are still in the old format. The extension will not
# read that file - reading it would mean executing it, since the format is a
# Lua chunk - and it will not save over it either, because a new JSON file
# beside it would strand the old bookmarks behind it. So the medium is
# read-only and the footer says why.
test_legacy_readonly() {
    local previous_hash tries=0
    previous_hash="$(latest_logged_hash)"

    vlc_next

    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        [ "$(latest_logged_hash)" != "$previous_hash" ] && break
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done

    # media_hash.py is a port of getFileHash(), and the planted file is only at
    # the right path if the two agree. Nothing else in the repo enforces that,
    # and a drift would otherwise show up as a confusing failure in whichever
    # tool was reached for later.
    local hash
    hash="$(latest_logged_hash)"
    if [ "$hash" != "$FIXTURE3_HASH" ]; then
        report_fail "legacy: media_hash.py agrees with the extension's getFileHash()" \
            "$FIXTURE3_HASH" "$hash"
        info "  The planted file is not at the hash the extension looked for, so"
        info "  the rest of this phase would test nothing. Skipping it."
        return
    fi
    report_pass "legacy: media_hash.py agrees with the extension's getFileHash()"

    check "legacy: the footer says the file is in the old format" \
        "$MSG_LEGACY_FOUND" "$(dialog_footer)"
    check "legacy: the old bookmarks are not listed" "0" "$(dialog_row_count)"

    vlc_pause
    vlc_seek "$T_GAMMA"
    dialog_set_input "must not be saved"
    dialog_click "Add"

    check "legacy: Add writes no JSON file beside the old one" "absent" \
        "$([ -e "$LEGACY_JSON_FILE" ] && echo present || echo absent)"
    check "legacy: the old-format file is left byte-identical" \
        "$LEGACY_MD5" "$(md5 -q "$LEGACY_FILE")"
    check "legacy: the refusal is on the footer" "$MSG_LEGACY_FOUND" "$(dialog_footer)"
    # Documented, not endorsed: addBookmark() inserts into the in-memory list
    # and only then finds out that saveBookmarks() refuses, so the row appears
    # even though nothing reached the disk. The footer says so and the next
    # load drops it. Pinned here so a change to that ordering is deliberate.
    check "legacy: a refused Add still shows its row (nothing was saved)" "1" \
        "$(dialog_row_count)"
}

# Stopping playback leaves the dialog up with nothing loaded. Add has no
# position to read there and cannot be greyed out, so it must refuse.
test_playback_stopped() {
    vlc_stop

    check "stop: the dialog stays open" "true" "$(dialog_exists)"
    check "stop: the list is cleared" "0" "$(dialog_row_count)"
    check "stop: the footer says why the list is empty" "$MSG_NO_MEDIA" "$(dialog_footer)"

    dialog_set_input "orphan"
    dialog_click "Add"
    check "stop: Add writes nothing with no medium loaded" "1" "$(bookmarks_count)"
    # The refusal must not repeat the message already on screen, or the click
    # looks like it did nothing at all.
    check "stop: Add answers the click with its own message" "$MSG_ADD_NO_MEDIA" "$(dialog_footer)"
}

# Activating the extension with nothing playing builds a placeholder dialog
# with none of the real widgets, and reloadCurrentMedium() detects it by that
# absence and rebuilds when a medium starts. Neither branch is reachable while
# a fixture is playing, so this phase closes the dialog and reopens it from the
# stopped state test_playback_stopped left behind.
test_noinput_dialog() {
    dialog_click "Close"
    local tries=0
    while [ "$tries" -lt "$DIALOG_WAIT_TRIES" ]; do
        [ "$(dialog_exists)" = "false" ] && break
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done
    check "no medium: Close deactivates the extension" "false" "$(dialog_exists)"

    click_extension_menu
    tries=0
    while [ "$tries" -lt "$DIALOG_WAIT_TRIES" ]; do
        [ "$(dialog_exists)" = "true" ] && break
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done

    if [ "$(dialog_exists)" != "true" ]; then
        # It does appear, measured on VLC 3.0.23 - the Cocoa provider shows a
        # dialog once a widget is added to it. Worth knowing if this ever goes
        # red: noinput_dialog() is the one path that never calls
        # dialog_UI:show() (the line is commented out upstream, where
        # main_dialog() calls it), so the extension would look dead to anyone
        # who activates it before opening a file.
        report_fail "no medium: activating with nothing playing shows a dialog" "true" "false"
        info "  noinput_dialog() does not call dialog_UI:show() - see the commented-out line."
    else
        report_pass "no medium: activating with nothing playing shows a dialog"
        check "no medium: the placeholder dialog has no Add button" "false" \
            "$(dialog_has_button "Add")"
        check "no medium: the placeholder dialog has no label input" "false" \
            "$(dialog_has_text_field)"
    fi

    # The third fixture rather than a bare play: after a stop it is undefined
    # which playlist entry resumes, and this needs a medium whose bookmark
    # count is known. That one has none - its bookmarks are the planted
    # old-format file, which the extension refuses to read.
    vlc_open "$FIXTURE3"
    tries=0
    while [ "$tries" -lt "$LAUNCH_TIMEOUT_TRIES" ]; do
        [ "$(dialog_has_button "Add")" = "true" ] && break
        sleep "$LAUNCH_POLL_S"
        tries=$((tries + 1))
    done

    check "no medium: a starting medium builds the real dialog" "true" \
        "$(dialog_has_button "Add")"
    check "no medium: the rebuilt dialog has its label input" "true" \
        "$(dialog_has_text_field)"
    check "no medium: the rebuilt dialog starts at the first label" "Bookmark (1)" \
        "$(dialog_get_input)"
    # The rebuild goes through main_dialog(), which applies the message
    # readBookmarks() left pending - so this also says the state survived the
    # switch from the placeholder.
    check "no medium: the rebuilt dialog carries the medium's own state" \
        "$MSG_LEGACY_FOUND" "$(dialog_footer)"
}

# Lua errors and warnings from the log, minus the ones the legacy phase asks
# for. Shared by the count and the printout so the two cannot disagree about
# what counted.
unexpected_lua_diagnostics() {
    grep -iE 'lua (error|warning)' "$LOG_FILE" \
        | grep -vF -e "$EXPECTED_LOG_LEGACY_WARNING" -e "$EXPECTED_LOG_LEGACY_REFUSAL" \
        || true
}

test_no_lua_errors() {
    local errors
    # The planted old-format file draws two diagnostics the extension is right
    # to emit, so those lines are excluded by their own text. Everything else
    # that looks like Lua trouble still counts.
    errors="$(unexpected_lua_diagnostics | grep -c . || true)"
    if [ "$errors" != "0" ]; then
        info "  --- Lua diagnostics from the log ---"
        unexpected_lua_diagnostics | sed 's/^/  /'
    fi
    check "no Lua errors or warnings were logged" "0" "$errors"
}

# --- Main ------------------------------------------------------------------

main() {
    preflight
    make_fixture
    plant_legacy_bookmark_file
    launch_vlc
    open_dialog_and_resolve_bookmark_file

    local phase
    for phase in test_fresh_medium test_add test_add_ordering test_rename \
                 test_go test_remove test_remove_guards test_default_label_index \
                 test_label_whitespace test_rename_guards test_track_change \
                 test_legacy_readonly test_playback_stopped test_noinput_dialog \
                 test_no_lua_errors; do
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
