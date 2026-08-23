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

    ln -s "$PWD/vlc_permanents_bookmarks.lua" \
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

## macOS notes

macOS VLC uses the Cocoa dialog provider, not Qt. Consequences that are easy to
trip over when editing the layout:

- Window width tracks grid **column count**, not content: 1 column = 160px,
  2 = 259px, 4 = 367px. The four-column layout pins width, so long bookmark
  names truncate.
- The "invisible label with `margin-left: NNNpx`" width-autofit hack found in
  upstream does nothing here. CSS in `add_label` does not affect layout.
- Qt mnemonic ampersands (`&Add`) render literally as text.
- The Extensions menu uses `descriptor().title`, not `shortdesc`.
- The Lua dialog API has no geometry call at all. Sizing is only reachable
  through the grid.

Files keep upstream's CRLF line endings.
