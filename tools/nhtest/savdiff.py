#!/usr/bin/env python3
"""Diff an ASCII16-X dirty-block .sav (rtl/flash_dirtysave.sv) against the cart ROM.

    tools/nhtest/savdiff.py <rom> <sav>

Format: sector 0 = MAGIC (64'h4D46583136584442, byte i = MAGIC[8*i+:8], so the file
holds "BDX61XFM"), byte 8 = mode (02), bytes 16..31 = 128-bit dirty bitmap (block
b = byte b/8, bit b%8); then every dirty 64 KB block in ascending order from sector 1.
A headerless file of the ROM's size is a legacy full dump.

A flash program can only clear bits, so a byte with a bit set that the ROM has
clear needs an ERASE of its sector first (64 KB, or an 8 KB boot sector below
10000h on this part).  Games erase and rewrite their save sector, so such bytes
are normal there.  The script reports, per sector, which kind of change it holds;
it cannot tell a game's save from a bad read-back -- that needs the game's own
save layout (2026-10-15: first version called every set bit IMPOSSIBLE and was
wrong for Neon Horizon's 8 KB save sector at 00C000h).
"""
import sys

rom = open(sys.argv[1], 'rb').read()
sav = open(sys.argv[2], 'rb').read()
MAGIC = (0x4D46583136584442).to_bytes(8, 'little')
BLK = 0x10000

if sav[:8] == MAGIC:
    mode = sav[8]
    bm = int.from_bytes(sav[16:32], 'little')
    blocks = [b for b in range(128) if bm >> b & 1]
    print('dirty-block save, mode %02x, %d block(s): %s' % (mode, len(blocks), ' '.join('%02x' % b for b in blocks)))
    data = {b: sav[512 + i * BLK: 512 + (i + 1) * BLK] for i, b in enumerate(blocks)}
    need = 512 + len(blocks) * BLK
    if len(sav) < need:
        print('WARNING: file is %d bytes, header implies %d' % (len(sav), need))
elif len(sav) == len(rom):
    print('headerless full dump (legacy)')
    data = {b: sav[b * BLK:(b + 1) * BLK] for b in range(len(rom) // BLK)}
else:
    sys.exit('unknown .sav format: %d bytes, first bytes %s' % (len(sav), sav[:16].hex(' ')))

bad_total = 0
for b, d in sorted(data.items()):
    o = rom[b * BLK:(b + 1) * BLK]
    if len(d) < BLK:
        print('block %02x: truncated (%d bytes)' % (b, len(d))); continue
    diff = [i for i in range(BLK) if d[i] != o[i]]
    if d == b'\xff' * BLK:
        print('block %02x: erased (all FF), %d bytes differ from ROM' % (b, len(diff))); continue
    legit = [i for i in diff if d[i] & o[i] == d[i]]          # bits only cleared
    bad = [i for i in diff if d[i] & o[i] != d[i]]            # a bit set: needs an erase first
    sect = lambda a: (a & ~0x1FFF) if a < 0x10000 else (a & ~0xFFFF)
    secs = sorted({sect(b * BLK + i) for i in bad})
    bad_total += len(bad)
    print('block %02x (%06x): %d bytes differ, %d bit-clear only, %d need an erase (sectors %s)'
          % (b, b * BLK, len(diff), len(legit), len(bad), ' '.join('%06x' % x for x in secs) or '-'))
    for i in diff[:12]:
        print('   %06x  rom %02x  sav %02x%s' % (b * BLK + i, o[i], d[i], '' if d[i] & o[i] == d[i] else '  (bit set: erased sector)'))
    if len(diff) > 12:
        print('   ... (%d more)' % (len(diff) - 12))
print('SUMMARY: %d byte(s) need an erased sector; judge them against the game\'s save layout' % bad_total)
