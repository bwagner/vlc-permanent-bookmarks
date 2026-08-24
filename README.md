# vlc-permanent-bookmarks

Personal fork of [JacopoBucchioni/vlc-permanents-bookmarks](https://github.com/JacopoBucchioni/vlc-permanents-bookmarks),
a VLC Lua extension that saves per-media bookmarks and stores them permanently.

Upstream was archived on 2024-04-04 and ships no license file. This fork exists
because the dialog was unusable on macOS.

The first commit is upstream v1.0.1 verbatim, so every change here is visible as a
diff against it.

## Install

The extension must NOT live inside the VLC app bundle: that breaks the code
signature and is wiped by VLC upgrades. Symlink it into the user extensions
directory instead, which VLC scans and which follows symlinks:

    ln -s "$PWD/vlc_permanent_bookmarks.lua" \
      ~/Library/"Application Support"/org.videolan.vlc/lua/extensions/

Restart VLC. The extension appears under the **VLC** menu > **Extensions**
(not the View menu, which is where it lives on Windows and Linux).

Bookmarks are stored one file per medium, keyed by a hash of the first and last
64 KB plus the byte size, under
`~/Library/Application Support/org.videolan.vlc/lua/extensions/userdata/bookmarks/`.
The hash is unchanged from upstream. The file format is not: files are now
JSON, named `<hash>.json`.

    {
      "version":1,
      "filename":"Big Buck Bunny.mp4",
      "bookmarks":[
        {
          "time":86205080,
          "formattedTime":"00:01:26.205",
          "label":"Bookmark (1)"
        }
      ]
    }

`time` is the playback position in microseconds and is what the extension seeks
to. `formattedTime` is derived from it, and is what the extension compares when
deciding whether a bookmark already exists at that position, so it keeps its
milliseconds. The list itself shows a shorter `hh:mm:ss` form, derived from
`time` rather than from this field: millisecond precision is noise for seeking,
and the dialog width is fixed, so every character costs label room.

`filename` is meta-information: the hash remains the only key, and nothing
reads the field back. It names the medium the bookmarks belong to, which the
hash alone cannot tell you. Only the file name is stored, never the path, since
these files travel with the media. It is rewritten on every save, so renaming a
medium corrects it the next time a bookmark is touched, and it is left out
entirely for anything with no local file name, such as a network stream. Files
written before the field existed are still read normally and gain it on their
next save.

### Which medium does a bookmark file belong to?

The `filename` field answers that for files written since it existed. For older
ones, and to go the other way - given a medium, find its bookmark file -
`scripts/media_hash.py` recomputes the hash:

    ./scripts/media_hash.py "/path/to/video.mp4"      # hash, byte size, path
    ./scripts/media_hash.py -q "/path/to/video.mp4"   # hash alone

It is a port of the extension's `getFileHash()` and reads only the first and
last 64 KB, so it is fast on large files and never writes anything. Verified
against two hashes the extension itself produced.

### Bookmarks written by an older version

Upstream stores each file as a Lua chunk and reads it back with `loadfile()`,
which executes it. Bookmark files are keyed by media content, so they travel
with a video and are the kind of thing that gets shared or synced - and any one
of them could run arbitrary shell commands as your user. This fork reads JSON
data instead and never executes a bookmark file.

Old files are not read. Convert them once, with VLC closed:

    lua scripts/migrate_bookmarks_to_json.lua            # dry run, writes nothing
    lua scripts/migrate_bookmarks_to_json.lua --apply

Each `<hash>` becomes `<hash>.json`, verified field-by-field by reading the
result back with `jq`, and the original is renamed to `<hash>.legacy` rather
than deleted. An existing `.json` is never overwritten. Requires `lua` and `jq`.

Until a medium is converted, the extension shows its bookmarks as empty and
refuses to save over them, saying so in the footer - so an Add can never strand
the old bookmarks behind a new file.

## Changes against upstream

- **Four-column dialog layout.** Upstream put the list at row span 14 in a
  16-row grid, producing a 259x1642 window on a 1728x1117 screen whose height
  refused every resize request. Now 367x277, height resizable 277-820.
- **`getFileHash()` guards** (from the qrrabbit fork): nil-stream check, no
  nil concatenation in the size-failure warning, and no backward seek on files
  under 64 KB.
- **Default bookmark name derived from the last existing bookmark** (from the
  adhihargo fork) rather than `#Bookmarks + 1`, so deleting bookmarks no longer
  produces duplicate default names.
- **Plain-space separator** in list rows. Upstream used U+3164 Hangul filler,
  which renders zero-width in the macOS dialog font.
- **JSON bookmark files.** Upstream's format is a Lua chunk loaded with
  `loadfile()`, so reading a bookmark file executes it. Files are now JSON,
  decoded with the `dkjson` module VLC bundles, and entries are validated before
  the UI touches them. This is a format change: see the note above.
- **`hh:mm:ss` in the list rows.** Upstream shows milliseconds
  (`00:02:51.238`), which are noise for seeking and cost four characters of
  label room in a dialog whose width is fixed. The stored `formattedTime` keeps
  them.
- **A dedicated Confirm button, and Add that only ever adds.** Upstream commits
  a rename by clicking **Add**: Rename loads the selected label into the input,
  and Add then writes it back. Nothing on screen says which of the two things
  Add is about to do, and a rename loaded before an Add silently wins. Rename
  now announces itself in the footer, **Confirm** - placed directly under Rename
  as its second step - commits it, and Add always adds. A pending rename is also
  refused if the selection has moved to another row, since the edited text came
  from the row that was loaded.
- **The dialog survives a track change.** Upstream hides it and drops all its
  state whenever the medium changes, so it has to be reopened from the
  Extensions menu for every track. It now reloads in place: the same window
  stays where it is and its list, default label and footer follow the new
  medium. Stopping playback altogether leaves the dialog up with an empty list
  and "No media playing" in the footer, where **Add** refuses - with its own
  wording, "Nothing to bookmark - no media is playing", so that pressing it
  visibly answers rather than repeating the message already on screen -
  instead of reading a position that does not exist. A medium that is playing
  but that cannot be hashed - a stream yielding no data - reaches the same
  refusal by a different route, and gets a wording of its own, "Nothing to
  bookmark - this medium cannot be identified", because nothing there has
  stopped. Rebuilding the window instead would
  have been two lines, but it would drop the dialog back at its default
  position, raise it over the video and replay the open-flicker on every track.
- **Remove asks before it deletes.** Upstream deletes the selected bookmarks the
  instant Remove is clicked, with no confirmation and no undo, and it can take
  several at once. **Remove** now only arms: it names what is about to go in the
  footer and writes nothing. **Delete** - directly under Remove, the way Confirm
  sits under Rename - commits it. The two steps are on two different buttons on
  purpose, since a habitual double-click on a single one would arm and commit in
  one gesture. Like a pending rename, an armed removal is refused if the
  selection has moved, and **every other button cancels it** - each callback
  clears the footer first, so an arming that outlived its own message would sit
  there invisibly waiting for a Delete. What cannot be done is clearing the
  list selection along with it: the dialog API has no deselect call, and a list
  rebuilt with `clear()` plus `add_value()` keeps its selected row. That is the
  suite's one XFAIL.
- **"Show in Finder" button.** Reveals this medium's bookmark file in Finder.
  Nothing is written until the first bookmark is saved, so on a medium with no
  bookmarks yet it opens the folder the file will live in and says so in the
  footer. With nothing playing there is no "this video" to name, so that case
  says so instead. macOS only: it shells out to `open`.

## Testing

VLC embeds no Lua interpreter that scripts can reach and there is no offline
harness for extension code, so the only real test is to run it. `luacheck`
catches style problems but has never found a bug in this file.

    ./scripts/smoke-test.sh

The script generates three test videos with ffmpeg, launches VLC on all three as
a playlist, opens the extension, and drives the dialog through the macOS
accessibility API - add, sort order, rename, go, the two-step remove, then a
track change, an old-format bookmark file, a stop, and a reopen with nothing
playing - asserting after each step against the bookmark file the extension
actually wrote, which `jq` reads back - so a malformed file fails the run rather
than being quietly tolerated. The second and third videos exist so the playlist
has somewhere to advance to; nothing touches them until the track-change and
legacy phases respectively.

Two states cannot be reached by driving the dialog, so the harness arranges them
directly. The **old-format** path needs a legacy bookmark file with no `.json`
beside it, which the extension itself will never produce - it only writes JSON.
So one is planted before VLC starts, at the hash `scripts/media_hash.py`
computes for the third video, and the run asserts that hash against the one the
extension logs: `media_hash.py` is a port of `getFileHash()`, and nothing else
keeps the two in step. The **no-medium** path needs the extension activated with
nothing loaded, so the last phase closes the dialog after the stop and reopens
it from there, then starts a medium again to check the placeholder dialog is
replaced by the real one.

The legacy phase makes the extension log a warning and a refusal, both correct.
Those two lines are excluded from the "no Lua errors" check by their exact text,
so nothing else hides behind them.

Requirements: macOS, VLC 3.x, `ffmpeg`, `jq`, `python3` (for `media_hash.py`),
and Accessibility permission for the terminal application you run it from
(System Settings > Privacy & Security > Accessibility). It drives the real GUI
and takes over the screen for about two minutes - 91 seconds of it driving VLC,
measured - and it cannot run headless or over ssh.

It refuses to start if VLC is already running, because it controls VLC's
lifecycle. It touches exactly one bookmark file per fixture - keyed by that
fixture's hash, read from VLC's own debug log - plus the legacy file it plants
at the third fixture's hash, and deletes all of them afterwards. No other file
in the bookmarks directory is opened. If a file already exists at any of those
paths it aborts without touching it: a path is handed to the cleanup trap only
after that check has passed, so a run can only ever delete a file it created
itself. The abort describes the file it refused - how many bookmarks it holds
and which medium it names - because the hash alone identifies nothing, and a
video whose bytes match a fixture shares that fixture's bookmark file.

### Leave the machine alone while the test runs

Using the keyboard, mouse or trackpad during a run derails it: a click steals
focus from the dialog, a keystroke lands in its text field. The harness cannot
prevent that - macOS offers no supported way for a script to block input, and a
modal "please wait" dialog would make things worse, since it has to be frontmost
in some process while the harness needs VLC frontmost to drive its menu bar.

So it detects interference instead. `IOHIDSystem`'s `HIDIdleTime` is nanoseconds
since the last real hardware input, and the accessibility actions the harness
dispatches do not reset it - verified by sampling a complete run 110 times
across menu clicks, button presses, text-field writes and seeks, with zero
resets. The counter therefore only falls when a human touches the machine, and
it is read once at the end of every test phase.

Detected input prints an `INPUT` line naming the phase and adds a notice to the
summary. It does not abort the run and does not change the exit code, which
stays driven by assertion failures - the point is that a red run is never
misread as a code regression. If assertions failed *and* input was detected, the
summary says the failures are unattributable and the run should be repeated.

Two limits worth knowing: the counter cannot tell a harmless mouse twitch from a
focus-stealing click, so any input taints the run equally; and if the machine was
already in use as the run started, input during the first phase can go
undetected, which preflight reports as a `NOTE`.

The detection logic itself is unit-tested:

    ./scripts/test-monitor.sh

It sources the monitoring block out of `smoke-test.sh` between that file's
section markers and feeds it canned counter readings, so it needs no GUI, no VLC
and no Accessibility permission, never steals focus, and finishes in well under
a second. It is the only test here that could run in CI or a commit hook.

Known-open bugs can be carried as `XFAIL` tests: they are expected to fail, do
not fail the run, and turn into an `XPASS` prompting promotion once fixed. There
is one: the list selection cannot be cleared after a committed removal, as
described under the Remove button above.

Not covered: multi-item selection. The accessibility API replaces the list
selection rather than extending it, so the multi-select branches of
`removeBookmark()`, `goToBookmark()` and `editBookmark()` are unreachable from
this harness.

## Linting

    luacheck .

Baseline is **2 warnings, 0 errors**. Both are `loop is executed at most
once` in `goToBookmark()` and `editBookmark()`, where a `pairs()` loop over a
single-element selection breaks on the first iteration. Rewriting them is a
behavior change, not housekeeping. Treat any count above 2 as a regression.

## macOS notes

macOS VLC uses the Cocoa dialog provider, not Qt. Consequences that are easy to
trip over when editing the layout:

- Window width tracks grid **column count**, not content: 1 column = 160px,
  2 = 259px, 4 = 367px. Labels never widen the window, but a **button** does:
  the 112px "Show in Finder" button widened the dialog from 367x277 to 422x292.
  Width is still not draggable, so long bookmark names still truncate - there
  is just more room before they do.
- The "invisible label with `margin-left: NNNpx`" width-autofit hack found in
  upstream does nothing here. CSS in `add_label` does not affect layout.
- Qt mnemonic ampersands (`&Add`) render literally as text.
- The Extensions menu uses `descriptor().title`, not `shortdesc`.
- The Lua dialog API has no geometry call at all. Sizing is only reachable
  through the grid.

Files keep upstream's CRLF line endings.
