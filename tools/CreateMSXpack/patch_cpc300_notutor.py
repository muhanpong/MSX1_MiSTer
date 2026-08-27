#!/usr/bin/env python3
"""Rebuild cpc-300_hangul_notutor.rom from the stock Daewoo CPC-300 Hangul ROM.

ROMs are gitignored, so the Daewoo_CPC-300{,E}_no_tutor packs cannot ship their
input.  Run this once and CreateMSXpack picks the result up by SHA1.

    ./patch_cpc300_notutor.py            # ROM/machines/daewoo/, in place
    ./patch_cpc300_notutor.py -i SRC -o DST

What it does -- one byte, 0x7F00: 0xC3 -> 0xC9.

cpc-300_hangul.rom carries TWO cartridge headers:

  file 0x0000 -> 0x4000   "AB" INIT=0x4244 STATEMENT=0x4383   Hangul driver
  file 0x4000 -> 0x8000   "AB" INIT=0xBF00                    IQ-CLASS tutor

The page-1 header is the driver: its INIT installs the six Hangul hooks
(H.CHPH/H.CHGE/H.QINL/H.INLIN/H.ONGO and 0xFFB6) and its STATEMENT serves
CALL HANON / HANOFF / ADJUST.  Untouched by this patch.

The page-2 header is the tutor and nothing else.  Its INIT (0xBF00 -> 0xBF0C)
compares an "IQ-CLASS:" signature at 0xF378; on a mismatch it hooks H.KEYA to
0xBF66, points TXTTAB at the tokenised BASIC program in ROM at 0x8011, and jumps
to 0x7E14 -- that is the tutor.  On a match it erases the signature and RETs,
which is the machine's own escape path (H.KEYA writes the signature and resets).

Making INIT an immediate RET takes that escape path unconditionally.  0xBF0C is
reachable only through the header vector at file 0x4002, so nothing else is
affected -- verified in openMSX: the patched ROM reaches BASIC with TXTTAB=0x8001
and all six Hangul hooks installed, byte-identical in behaviour to the stock ROM
after its own escape.
"""

import argparse
import hashlib
import os
import sys

OFF = 0x7F00
STOCK_SHA1 = "47a9d9a24e4fc6f9467c6e7d61a02d45f5a753ef"
PATCHED_SHA1 = "0c3dace2e3748486973b1d037147601fd49ce78a"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "ROM", "machines", "daewoo")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-i", default=os.path.join(DEFAULT_DIR, "cpc-300_hangul.rom"))
    p.add_argument("-o", default=os.path.join(DEFAULT_DIR, "cpc-300_hangul_notutor.rom"))
    p.add_argument("-f", "--force", action="store_true", help="overwrite the output")
    a = p.parse_args()

    d = bytearray(open(a.i, "rb").read())
    got = hashlib.sha1(d).hexdigest()
    if got != STOCK_SHA1:
        sys.exit(f"{a.i}\n  sha1 {got}\n  expected {STOCK_SHA1} (stock CPC-300 Hangul ROM)")

    # belt and braces: both headers must be where we think they are
    assert len(d) == 32768
    assert d[0x0000:0x0006] == b"AB\x44\x42\x83\x43", "page-1 header moved"
    assert d[0x4000:0x4004] == b"AB\x00\xBF", "page-2 header moved"
    assert d[OFF:OFF + 3] == b"\xC3\x0C\xBF", "0xBF00 is not JP 0BF0CH"

    d[OFF] = 0xC9

    out = hashlib.sha1(d).hexdigest()
    assert out == PATCHED_SHA1, f"unexpected result {out}"

    if os.path.exists(a.o) and not a.force:
        if hashlib.sha1(open(a.o, "rb").read()).hexdigest() == PATCHED_SHA1:
            print(f"{a.o} already correct")
            return
        sys.exit(f"{a.o} exists and differs; pass -f to overwrite")

    open(a.o, "wb").write(d)
    print(f"{a.o}\n  0x{OFF:04X}: C3 -> C9   sha1 {out}")


if __name__ == "__main__":
    main()
