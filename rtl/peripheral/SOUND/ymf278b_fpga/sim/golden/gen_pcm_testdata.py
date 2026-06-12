#!/usr/bin/env python3
"""
Generates the PCM golden-comparison test set:
  mem.bin / mem.hex : sample memory with headers (wavetblhdr=0 layout)
  sc_*.txt          : register-write scripts (frame addr data), frames start at 1

Waves (header @ wave#*12):
  0: 8-bit  64-sample ramp,   loop 0
  1: 16-bit 32-sample square, loop 0
  2: 12-bit 64-sample triangle, loop 16 (loop-seam exercise)
  3: 8-bit  16-sample noise-ish, loop 0
"""
import math, struct, os

MEM = bytearray([0]*0x40000)

def header(wave, bits, start, loop_pos, end_pos, ar=15, d1r=0, dl=0, d2r=0, rc=15, rr=4, am=0, lfovib=0):
    base = wave*12
    MEM[base+0] = (bits << 6) | ((start >> 16) & 0x3F)
    MEM[base+1] = (start >> 8) & 0xFF
    MEM[base+2] = start & 0xFF
    MEM[base+3] = (loop_pos >> 8) & 0xFF
    MEM[base+4] = loop_pos & 0xFF
    end_stored = (0x10000 - end_pos) & 0xFFFF      # 2's-complement form
    MEM[base+5] = (end_stored >> 8) & 0xFF
    MEM[base+6] = end_stored & 0xFF
    MEM[base+7] = lfovib
    MEM[base+8] = (ar << 4) | d1r
    MEM[base+9] = (dl << 4) | d2r
    MEM[base+10] = (rc << 4) | rr
    MEM[base+11] = am

# wave 0: 8-bit ramp, 64 samples @0x1000
header(0, 0, 0x1000, 0, 64)
for i in range(64):
    MEM[0x1000+i] = (i*4 - 128) & 0xFF

# wave 1: 16-bit square, 32 samples @0x2000
header(1, 2, 0x2000, 0, 32)
for i in range(32):
    v = 0x4000 if i < 16 else -0x4000
    MEM[0x2000+2*i]   = (v >> 8) & 0xFF
    MEM[0x2000+2*i+1] = v & 0xFF

# wave 2: 12-bit triangle, 64 samples @0x3000, loop at 16
header(2, 1, 0x3000, 16, 64)
for p in range(0, 64, 2):
    def tri(k):
        x = k % 64
        v = (x*64) if x < 32 else ((63-x)*64)
        return (v - 1024) & 0xFFF
    a, b = tri(p), tri(p+1)
    base = 0x3000 + (p//2)*3
    MEM[base+0] = (a >> 4) & 0xFF
    MEM[base+1] = ((a & 0xF) << 4) | ((b >> 8) & 0xF)
    MEM[base+2] = b & 0xFF

# wave 3: 8-bit pseudo-noise, 16 samples @0x4000
header(3, 0, 0x4000, 0, 16, ar=12, d1r=4, dl=3, d2r=2)
x = 0xA5
for i in range(16):
    x = ((x << 1) ^ (0x1D if x & 0x80 else 0)) & 0xFF
    MEM[0x4000+i] = x

out = os.path.dirname(os.path.abspath(__file__))
open(f"{out}/mem.bin", "wb").write(MEM)
with open(f"{out}/mem.hex", "w") as f:
    for b in MEM:
        f.write(f"{b:02x}\n")

def W(lines, fr, addr, data): lines.append(f"{fr} {addr:02x} {data:02x}")
def slotw(lines, fr, n, field, data): W(lines, fr, 0x08 + field*24 + n, data)

def keyon(lines, fr, n, wave, fn, oct_, tl=0, pan=0, lfo_off=True):
    slotw(lines, fr, n, 0, wave & 0xFF)
    slotw(lines, fr, n, 1, ((fn & 0x7F) << 1) | ((wave >> 8) & 1))
    slotw(lines, fr, n, 2, ((oct_ & 0xF) << 4) | ((fn >> 7) & 7))
    slotw(lines, fr, n, 3, (tl << 1) | 1)                    # TL load-immediate
    slotw(lines, fr, n, 4, 0x80 | (0x20 if lfo_off else 0) | (pan & 0xF))

scripts = {}

# S1: single 8-bit voice, mid pitch, keyoff at 600
L = []
keyon(L, 1, 0, wave=0, fn=0x200, oct_=0)
W(L, 600, 0x08 + 4*24 + 0, 0x20)        # keyoff (lfo still off)
scripts['sc_single8.txt'] = (L, 900)

# S2: 16-bit square + octave sweep
L = []
keyon(L, 1, 1, wave=1, fn=0x155, oct_=1)
for k, fr in enumerate(range(150, 750, 150)):
    slotw(L, fr, 1, 2, (((k - 1) & 0xF) << 4) | ((0x155 >> 7) & 7))
scripts['sc_square16.txt'] = (L, 900)

# S3: 12-bit triangle with loop seam + pan sweep
L = []
keyon(L, 1, 2, wave=2, fn=0x2AA, oct_=2, pan=0)
for k, fr in enumerate(range(100, 800, 100)):
    slotw(L, fr, 2, 4, 0x80 | 0x20 | ((k*2) & 0xF))
scripts['sc_tri12_loop.txt'] = (L, 1000)

# S4: 4 voices, envelopes, re-key, wave change while keyed
L = []
keyon(L, 1, 0, wave=0, fn=0x180, oct_=0,  tl=4,  pan=2)
keyon(L, 1, 5, wave=1, fn=0x200, oct_=-1, tl=8,  pan=14)
keyon(L, 2, 9, wave=3, fn=0x2C0, oct_=1,  tl=0,  pan=0)
W(L, 300, 0x08 + 4*24 + 5, 0x20)                  # keyoff slot 5
W(L, 400, 0x08 + 0*24 + 9, 0x02)                  # wave change while keyed (retrig)
keyon(L, 500, 5, wave=2, fn=0x100, oct_=0, tl=2, pan=8)   # re-key slot 5
scripts['sc_multi.txt'] = (L, 1200)

# S5: LFO vibrato + tremolo (8-bit ramp, slow pitch)
L = []
keyon(L, 1, 3, wave=0, fn=0x100, oct_=-2, lfo_off=False)
slotw(L, 1, 3, 5, (3 << 3) | 5)                   # lfo speed 3, vib depth 5
slotw(L, 1, 3, 9, 4)                              # AM depth 4
scripts['sc_lfo.txt'] = (L, 1500)

for name, (lines, frames) in scripts.items():
    with open(f"{out}/{name}", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{name}: {len(lines)} writes, {frames} frames")
print("mem.bin/mem.hex written")
