#!/usr/bin/env python3
"""Zero the archive bit on a 720KB MSX FAT12 image's root directory entries.

    normalize_attrs.py IN.DSK OUT.DSK

mtools sets attr=0x20 on files it writes; the stock SCMD disk has 0x00 on every
entry.  This rewrites ONLY the attribute byte (+11) of each root entry, so file
data, FAT and cluster chains are untouched -- it removes the archive-bit
variable from hardware experiments without altering the payload.
"""
import sys, struct

src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, 'rb').read())
bps  = struct.unpack('<H', d[11:13])[0]
res  = struct.unpack('<H', d[14:16])[0]
nfat = d[16]
nroot= struct.unpack('<H', d[17:19])[0]
spf  = struct.unpack('<H', d[22:24])[0]
root = res*bps + nfat*spf*bps
touched = []
for i in range(nroot):
    o = root + i*32
    if d[o] == 0: break
    if d[o] == 0xE5: continue
    if d[o+11] & 0x20:
        print(f"  {d[o:o+11].decode('latin1')}  0x{d[o+11]:02X} -> 0x{d[o+11]&~0x20:02X}  @0x{o+11:04X}")
        d[o+11] &= ~0x20
        touched.append(o+11)
orig = open(src, 'rb').read()
diff = [i for i in range(len(orig)) if orig[i] != d[i]]
assert sorted(diff) == sorted(touched), f"unexpected byte changes: {diff}"
open(dst, 'wb').write(bytes(d))
print(f"{dst}: {len(diff)} byte(s) changed, all in root-dir attribute fields")
