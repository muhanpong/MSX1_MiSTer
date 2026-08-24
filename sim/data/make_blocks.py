#!/usr/bin/env python3
"""Extract the 8KB blocks tb_opfxsd_block replays, from local image files.

The blocks themselves are slices of commercial software, so they are not
committed -- same policy as tools/scmd_mfrsd/.gitignore.  Regenerate them here.

    python3 sim/data/make_blocks.py

Why these blocks.  OPFXSD writes an image in 8KB blocks; the defect fixed in
flash.sv triggers on a data byte in {50,56,AA} landing at block offset 0x0AAA /
0x0AAB / 0x1AAA / 0x1AAB, where addr[11:1] aliases the unlock address 0x555.

    dsk_blk45  SCMD110A.DSK block 45 -- 0x50 at 0x1AAB.  This is the block the
               hardware died on ("Flash write error!" after 45 'o'), for BOTH
               disk slots, because flash_addr[11:0] == cpu_addr[11:0] makes the
               trigger offset independent of the slot base.
    dsk_blk44  the block before it: clean, must stay clean.
    dsk_blk12  0x56 at 0x0AAA -- an opener at the OTHER aliased offset that does
               NOT break anything.  Pins that the trigger is narrower than
               "any opener at any aliased offset".
    mg2_blk45  clean control from a different image.
    mg2_blk03  0xAA at 0x0AAB -- lost 4 bytes SILENTLY before the fix: the
               dropped verify byte's bit 7 matched the erased 0xFF, so OPFXSD's
               DQ7 data-poll could not see it.  Only the TB's full compare can.

Sources default to the paths used during the investigation; override with
--dsk / --rom if yours live elsewhere.
"""
import argparse
import os
import sys

BLOCK = 0x2000

WANTED = [
    ("dsk", 45, "dsk_blk45.hex"),
    ("dsk", 44, "dsk_blk44.hex"),
    ("dsk", 12, "dsk_blk12.hex"),
    ("rom", 45, "mg2_blk45.hex"),
    ("rom",  3, "mg2_blk03.hex"),
]

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

DEFAULT_DSK = os.path.join(REPO, "tools", "scmd_mfrsd", "SCMD110A_original.DSK")
DEFAULT_ROM = os.path.expanduser(
    "~/msx_archive/mfrsd_scmd_20260823/binaries/Metal Gear 2 - Solid Snake (1990) (Konami) (J).rom")


def load(path, what):
    if not os.path.isfile(path):
        sys.exit("missing %s image: %s\n"
                 "  (not committed on purpose -- see tools/scmd_mfrsd/.gitignore)\n"
                 "  pass the right path with --%s" % (what, path, what))
    with open(path, "rb") as fh:
        return fh.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsk", default=DEFAULT_DSK, help="SCMD110A .DSK image (737280 bytes)")
    ap.add_argument("--rom", default=DEFAULT_ROM, help="Metal Gear 2 .rom (524288 bytes)")
    args = ap.parse_args()

    images = {"dsk": load(args.dsk, "dsk"), "rom": load(args.rom, "rom")}

    for which, index, name in WANTED:
        data = images[which]
        start = index * BLOCK
        blk = data[start:start + BLOCK]
        if len(blk) != BLOCK:
            sys.exit("%s: block %d is past the end of the image (%d bytes)"
                     % (name, index, len(data)))
        with open(os.path.join(HERE, name), "w") as fh:
            fh.write("\n".join("%02x" % b for b in blk) + "\n")
        print("%-16s block %2d  offset 0x%06X" % (name, index, start))


if __name__ == "__main__":
    main()
