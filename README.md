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
to; `formattedTime` is derived from it and only ever displayed.

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
of them could run arbitrary code inside VLC. This fork reads JSON data instead
and never executes a bookmark file.

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
- **"Show in Finder" button.** Reveals this medium's bookmark file in Finder.
  Nothing is written until the first bookmark is saved, so on a medium with no
  bookmarks yet it opens the folder the file will live in and says so in the
  footer. macOS only: it shells out to `open`.

## Testing

VLC embeds no Lua interpreter that scripts can reach and there is no offline
harness for extension code, so the only real test is to run it. `luacheck`
catches style problems but has never found a bug in this file.

    ./scripts/smoke-test.sh

The script generates a 5-minute test video with ffmpeg, launches VLC on it with
debug logging, opens the extension, and drives the dialog through the macOS
accessibility API - add, sort order, rename, go, remove - asserting after each
step against the bookmark file the extension actually wrote, which `jq` reads
back - so a malformed file fails the run rather than being quietly tolerated.

Requirements: macOS, VLC 3.x, `ffmpeg`, `jq`, and Accessibility permission for
the terminal application you run it from (System Settings > Privacy & Security >
Accessibility). It drives the real GUI and takes over the screen for about
thirty seconds; it cannot run headless or over ssh.

It refuses to start if VLC is already running, because it controls VLC's
lifecycle. It touches exactly one bookmark file - the one keyed by the generated
fixture's hash, read from VLC's own debug log - and deletes it afterwards. No
other file in the bookmarks directory is opened. If a file already exists at
that path it aborts without touching it: the path is handed to the cleanup trap
only after that check has passed, so a run can only ever delete a file it
created itself.

### Leave the machine alone while it runs

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
it is read once at the end of each of the nine test phases.

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
are none at present.

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
