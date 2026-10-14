#!/usr/bin/env python3
"""Diff an ASCII16-X dirty-block .sav (rtl/flash_dirtysave.sv) against the cart ROM.

    tools/nhtest/savdiff.py <rom> <sav>

Format: sector 0 = MAGIC (64'h4D46583136584442, byte i = MAGIC[8*i+:8], so the file
holds "BDX61XFM"), byte 8 = mode (02), bytes 16..31 = 128-bit dirty bitmap (block
b = byte b/8, bit b%8); then every dirty 64 KB block in ascending order from sector 1.
A headerless file of the ROM's size is a legacy full dump.

A block restored from a correct save differs from the ROM only where the game
programmed flash: a flash program can only clear bits (new == old & new), and an
erase sets a 64 KB sector to FF.  Anything else is a bad save or a bad read-back.
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
    bad = [i for i in diff if d[i] & o[i] != d[i]]            # a bit set that the ROM had clear
    bad_total += len(bad)
    print('block %02x (%06x): %d bytes differ, %d bit-clear only (flash program), %d IMPOSSIBLE (bit set)'
          % (b, b * BLK, len(diff), len(legit), len(bad)))
    for i in diff[:12]:
        print('   %06x  rom %02x  sav %02x%s' % (b * BLK + i, o[i], d[i], '' if d[i] & o[i] == d[i] else '  <-- bit set'))
    if len(diff) > 12:
        print('   ... (%d more)' % (len(diff) - 12))
print('RESULT %s: %d byte(s) a flash program cannot produce' % ('PASS' if bad_total == 0 else 'FAIL', bad_total))
