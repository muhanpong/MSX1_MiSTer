#!/usr/bin/env python3
"""
Retunes an OPL4 (YMF278B) VGM recorded at a non-MoonSound chip clock so it
plays at the intended pitch/tempo on real 33.8688 MHz hardware.

The PCM step factor is 2^OCT * (1 + FN/1024); vgmplay does no runtime clock
compensation, so a 28.6 MHz arcade rip plays ~18% sharp/fast.  This rescales
(1 + FN/1024) by clk_src/33868800 (borrowing from OCT when FN underflows),
rewrites the wave-port FN/OCT writes (fields 1/2), and retags the header
clock.  FM writes and data blocks pass through untouched.

Usage: vgm_opl4_retune.py in.vgm out.vgm
"""
import struct, sys

MOON = 33868800

src = open(sys.argv[1], 'rb').read()
d = bytearray(src)
clk = struct.unpack('<I', d[0x60:0x64])[0] & 0x3FFFFFFF
ratio = clk / MOON
print(f"src clock {clk} Hz → ratio {ratio:.5f}")
if abs(ratio - 1.0) < 1e-6:
    sys.exit("already MoonSound clock; nothing to do")

# per-slot shadow of ORIGINAL f1/f2 register values (defaults = reset state)
f1 = [0]*24
f2 = [0]*24

def retune(slot):
    """compensated (f1, f2) byte pair from the slot's original shadow"""
    fn  = ((f2[slot] & 7) << 7) | (f1[slot] >> 1)
    oct_ = (f2[slot] >> 4)
    o = oct_ - 16 if oct_ >= 8 else oct_
    step = (1 + fn/1024) * ratio
    while step < 1.0 and o > -8:
        step *= 2; o -= 1
    nfn = min(1023, max(0, round((step - 1) * 1024)))
    nf1 = ((nfn & 0x7F) << 1) | (f1[slot] & 1)            # keep wave bit8
    nf2 = ((o & 0xF) << 4) | (f2[slot] & 8) | (nfn >> 7)  # keep PRVB
    return nf1, nf2

p = struct.unpack('<I', d[0x34:0x38])[0] + 0x34
n = 0
while p < len(d):
    c = d[p]
    if c == 0x67:
        p += 7 + struct.unpack('<I', d[p+3:p+7])[0]
    elif c == 0xD0:
        if d[p+1] == 2 and 0x20 <= d[p+2] <= 0x4F:
            slot = (d[p+2] - 8) % 24
            if d[p+2] <= 0x37: f1[slot] = d[p+3]          # field 1
            else:              f2[slot] = d[p+3]          # field 2
            nf1, nf2 = retune(slot)
            d[p+3] = nf1 if d[p+2] <= 0x37 else nf2
            n += 1
        p += 4
    elif c == 0x61: p += 3
    elif c in (0x62, 0x63): p += 1
    elif 0x70 <= c <= 0x7F: p += 1
    elif c == 0x66: break
    else: sys.exit(f"unknown cmd {c:02x} at 0x{p:x}")

d[0x60:0x64] = struct.pack('<I', MOON)
open(sys.argv[2], 'wb').write(d)
print(f"{n} FN/OCT writes retuned → {sys.argv[2]}")
