#!/usr/bin/env -S uv run --script
# /// script
# dependencies = []
# ///
"""Compute the bookmark-file hash of a medium.

Bookmark files are named after a hash of the medium's content, so nothing in
the bookmarks directory says which file it belongs to. This recomputes that
hash, which answers the question the other way round: given a medium, which
bookmark file is its own.

The algorithm is a port of getFileHash() in vlc_permanent_bookmarks.lua, which
is unchanged from upstream: a 64-bit sum over the first and last 64 KB of the
file, seeded with the byte size, printed as two 32-bit halves. Files of 64 KB
or less contribute their start chunk only. Keep this in step with the Lua if
that function is ever touched.

One deliberate divergence: where the Lua gives up without a hash if the stream
yields no data, this hashes whatever it reads, so an empty file prints all
zeroes rather than nothing. The extension would never have written a bookmark
file for such a medium in the first place.
"""

import argparse
import os
import sys

CHUNK_SIZE = 65536
WORD_SIZE = 8
OVERFLOW_AT = 4294967296


def media_hash(path):
    """Return (hash, byte_size) for the medium at path."""
    size = os.path.getsize(path)
    with open(path, "rb") as media:
        data = media.read(CHUNK_SIZE)
        if size > CHUNK_SIZE:
            media.seek(size - CHUNK_SIZE)
            data += media.read(CHUNK_SIZE)

    lo, hi = size, 0
    for offset in range(0, len(data), WORD_SIZE):
        word = data[offset:offset + WORD_SIZE].ljust(WORD_SIZE, b"\0")
        lo += int.from_bytes(word[:4], "little")
        hi += int.from_bytes(word[4:], "little")
        if lo > OVERFLOW_AT:
            carry = lo // OVERFLOW_AT
            lo -= carry * OVERFLOW_AT
            hi += carry
        if hi > OVERFLOW_AT:
            hi -= (hi // OVERFLOW_AT) * OVERFLOW_AT

    return "%08x%08x" % (hi, lo), size


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("media", nargs="+", help="media files to hash")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="print the hash alone, without size and path")
    args = parser.parse_args()

    status = 0
    for path in args.media:
        try:
            digest, size = media_hash(path)
        except OSError as err:
            print("%s: %s" % (path, err), file=sys.stderr)
            status = 1
            continue
        if args.quiet:
            print(digest)
        else:
            print("%s\t%d\t%s" % (digest, size, path))
    return status


if __name__ == "__main__":
    sys.exit(main())
