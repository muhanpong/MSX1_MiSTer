#!/usr/bin/env python3
"""flashsave -- convert a flash-cart save between openMSX and the MiSTer MSX1 core.

The core does not store a memory dump.  A `.sav` for an ASCII16X / Yamanooto cart
is a SPARSE PATCH over the 8 MB flash chip, written by `rtl/flash_dirtysave.sv`:

    sector 0 (512 B)  bytes 0..7   magic
                      byte  8      mode, 0x02 = dirty-block
                      bytes 16..31 128-bit dirty bitmap, LSB-first, bit i = block i
    sectors 1..       the dirty 64 KB blocks, ascending block index, 128 sectors each

  => file size == 512 + popcount(bitmap) * 65536

*** The magic on disk reads "BDX61XFM". ***  The RTL constant is
`64'h4D_46_58_31_36_58_44_42` ("MFX16XDB") and the writer emits `MAGIC[8*i +: 8]`,
i.e. little-endian, so the bytes land reversed.  The source comment says
"MFX16XDB" and is about the constant, not the file.  Confirmed against a save
written by the core on real hardware.

openMSX stores the other extreme: `AmdFlash` keeps the WHOLE 8 MB chip in
`~/.openMSX/persistent/roms/<rom>/<rom>.SRAM`.

Both sides share one reference point -- how the core stages the cart:
the ROM at offset 0, then 0xFF ("erased") to the end of the chip
(`memory_upload.sv` x16_pad, pattern 3'd1).  Diffing against that gives the save.

Usage
    flashsave.py extract --rom BASE.ROM --image <rom>.SRAM  -o OUT.sav
    flashsave.py apply   --rom BASE.ROM --sav   OUT.sav     -o <rom>.SRAM
    flashsave.py info    --sav OUT.sav

Note on scope: this marks a block dirty whenever it differs from the padded ROM.
The core marks only blocks the game *programmed*, so a block the game merely
erased is caught here and not there.  Harmless -- restore just writes it back.
"""

import argparse
import sys

BLOCK = 65536
NBLOCKS = 128
FLASH = BLOCK * NBLOCKS          # 8 MiB
SECTOR = 512
MAGIC = bytes([0x42, 0x44, 0x58, 0x36, 0x31, 0x58, 0x46, 0x4D])   # "BDX61XFM"
MODE_DIRTY_BLOCK = 0x02


def padded_base(rom: bytes) -> bytearray:
    """The chip as the core stages it: ROM at 0, 0xFF to the end."""
    if len(rom) > FLASH:
        sys.exit(f"ROM is {len(rom):,} bytes, larger than the {FLASH:,}-byte chip.")
    base = bytearray(b"\xFF" * FLASH)
    base[:len(rom)] = rom
    return base


def parse_sav(data: bytes):
    if len(data) < SECTOR:
        sys.exit(f".sav is {len(data)} bytes, shorter than one 512-byte sector.")
    if data[:8] != MAGIC:
        got = "".join(chr(c) if 32 <= c < 127 else "." for c in data[:8])
        sys.exit(f'.sav magic is "{got}", expected "BDX61XFM".')
    bm = int.from_bytes(data[16:32], "little")
    dirty = [i for i in range(NBLOCKS) if bm >> i & 1]
    want = SECTOR + len(dirty) * BLOCK
    if len(data) != want:
        sys.exit(f"bitmap names {len(dirty)} block(s) = {want:,} bytes, file is {len(data):,}.")
    return dirty, data[8]


def build_sav(image: bytes, dirty) -> bytearray:
    out = bytearray(SECTOR)
    out[0:8] = MAGIC
    out[8] = MODE_DIRTY_BLOCK
    bm = 0
    for b in dirty:
        bm |= 1 << b
    out[16:32] = bm.to_bytes(16, "little")
    for b in dirty:
        out += image[b * BLOCK:(b + 1) * BLOCK]
    return out


def cmd_extract(a):
    rom = open(a.rom, "rb").read()
    img = open(a.image, "rb").read()
    if len(img) != FLASH:
        sys.exit(f"flash image must be exactly {FLASH:,} bytes (8 MB); this is {len(img):,}.")
    base = padded_base(rom)
    dirty = [i for i in range(NBLOCKS)
             if base[i * BLOCK:(i + 1) * BLOCK] != img[i * BLOCK:(i + 1) * BLOCK]]
    if not dirty:
        sys.exit("no block differs from the padded ROM -- this image holds no save.")
    for b in dirty:
        x, y = base[b * BLOCK:(b + 1) * BLOCK], img[b * BLOCK:(b + 1) * BLOCK]
        diffs = [i for i, (p, q) in enumerate(zip(x, y)) if p != q]
        print(f"  block {b:3d} @0x{b*BLOCK:06X}  {len(diffs):,} bytes changed "
              f"(0x{diffs[0]:04X}-0x{diffs[-1]:04X})")
    out = build_sav(img, dirty)
    open(a.o, "wb").write(out)
    print(f"-> {a.o}  {len(out):,} bytes  ({len(dirty)} block(s))")


def cmd_apply(a):
    rom = open(a.rom, "rb").read()
    sav = open(a.sav, "rb").read()
    dirty, _ = parse_sav(sav)
    img = padded_base(rom)
    for n, b in enumerate(dirty):
        img[b * BLOCK:(b + 1) * BLOCK] = sav[SECTOR + n * BLOCK: SECTOR + (n + 1) * BLOCK]
    open(a.o, "wb").write(img)
    print(f"-> {a.o}  {len(img):,} bytes  ({len(dirty)} block(s) applied)")


def cmd_info(a):
    sav = open(a.sav, "rb").read()
    dirty, mode = parse_sav(sav)
    print(f"{a.sav}: {len(sav):,} bytes, mode 0x{mode:02X}, {len(dirty)} dirty block(s)")
    for b in dirty:
        print(f"  block {b:3d} @0x{b*BLOCK:06X}-0x{(b+1)*BLOCK-1:06X}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    s = p.add_subparsers(dest="cmd", required=True)

    e = s.add_parser("extract", help="openMSX 8 MB image -> MiSTer .sav")
    e.add_argument("--rom", required=True)
    e.add_argument("--image", required=True)
    e.add_argument("-o", required=True)
    e.set_defaults(fn=cmd_extract)

    y = s.add_parser("apply", help="MiSTer .sav -> openMSX 8 MB image")
    y.add_argument("--rom", required=True)
    y.add_argument("--sav", required=True)
    y.add_argument("-o", required=True)
    y.set_defaults(fn=cmd_apply)

    i = s.add_parser("info", help="describe a .sav")
    i.add_argument("--sav", required=True)
    i.set_defaults(fn=cmd_info)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
