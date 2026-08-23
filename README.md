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
The hash is unchanged from upstream, so existing bookmark files stay valid.

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
step against the bookmark file the extension actually wrote. `scripts/dump_bookmarks.lua`
reads those files back; they are plain Lua table constructors, so they load
directly.

Requirements: macOS, VLC 3.x, `ffmpeg`, `lua`, and Accessibility permission for
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
