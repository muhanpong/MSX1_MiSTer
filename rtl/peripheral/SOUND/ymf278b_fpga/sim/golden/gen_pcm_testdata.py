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

# wave 300 (bit8 set): reuses wave-1 square samples, distinct envelope so a
# spurious header reload from a field-1 write is audible in the diff
header(300, 2, 0x2000, 0, 32, ar=10, d1r=6, dl=2, d2r=3)

# wave 4: 16-bit at an ODD start address (real arcade rips do this — Strikers
# wave 402 starts at 0x2F40AF).  Catches word-coverage bugs in the fetch path
# that even-aligned waves can never expose (need_b / pick_byte).
header(4, 2, 0x5001, 0, 24)
for i in range(24):
    v = (i * 2730 - 32768) & 0xFFFF
    MEM[0x5001+2*i]   = (v >> 8) & 0xFF
    MEM[0x5001+2*i+1] = v & 0xFF

# direction-dependency waves: distinct 8-bit full-loop ramps (AR=15 hold) so a
# stale (previous-wave) playback is obvious in the diff.  122 ascends, 123 descends.
header(122, 0, 0x6000, 0, 64)
for i in range(64): MEM[0x6000+i] = (i*4 - 128) & 0xFF
header(123, 0, 0x7000, 0, 64)
for i in range(64): MEM[0x7000+i] = (128 - i*4) & 0xFF

out = os.path.dirname(os.path.abspath(__file__))
open(f"{out}/mem.bin", "wb").write(MEM)
with open(f"{out}/mem.hex", "w") as f:
    for b in MEM:
        f.write(f"{b:02x}\n")

# wc = TB apply cycle within the PREVIOUS frame (4th column).  1000 = mid
# service window (header fetch resolves same frame); 1780 = past the fetch
# start deadline (CPU_RESERVE_AT-130), so any hf_pending raised there starves
# until the NEXT frame's window — the worst-case real-hardware write timing.
def W(lines, fr, addr, data, wc=1000): lines.append((fr, wc, f"{fr} {addr:02x} {data:02x} {wc}"))
def slotw(lines, fr, n, field, data, wc=1000): W(lines, fr, 0x08 + field*24 + n, data, wc)

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

# S6: pitch-bend bombardment — vgmplay clock-compensation pattern: keyed slot
# gets field-1 (FN low) writes every few frames.  Field 1 must NOT reload the
# header (openMSX case 1); the old RTL reloaded+muted on every write.
# Bend writes land at wc=1780, past the header-fetch start deadline: a
# spurious hf_pending from field 1 then mutes the slot for the whole next
# frame (ld_run gate) — the worst-case timing every real vgmplay write can
# hit.  FN-only updates need no fetch, so the fixed RTL is unaffected.
L = []
keyon(L, 1, 4, wave=2, fn=0x200, oct_=0)
for fr in range(5, 800, 3):
    fn = 0x180 + ((fr * 37) % 0x100)
    slotw(L, fr, 4, 1, ((fn & 0x7F) << 1) | 0, wc=1780)   # FN low, wave bit8=0
    if fr % 30 == 5:
        slotw(L, fr, 4, 2, (0 << 4) | ((fn >> 7) & 7), wc=1780)
scripts['sc_pitchbend.txt'] = (L, 1000)

# S7: wave >= 256 — field-1 sets bit8 first, field-0 LSB triggers the load;
# then mid-play field-1 writes (no reload) and a field-0 rewrite (reload+retrig)
L = []
slotw(L, 1, 6, 1, ((0x155 & 0x7F) << 1) | 1)              # bit8=1 + FN low
slotw(L, 1, 6, 0, 300 & 0xFF)                             # LSB → load wave 300
slotw(L, 1, 6, 2, (0 << 4) | ((0x155 >> 7) & 7))
slotw(L, 1, 6, 3, (0 << 1) | 1)
slotw(L, 1, 6, 4, 0x80 | 0x20)
for fr in range(120, 400, 40):
    slotw(L, fr, 6, 1, (((0x100 + fr) & 0x7F) << 1) | 1)  # bend, keep bit8
W(L, 500, 0x08 + 0*24 + 6, 300 & 0xFF)                    # f0 rewrite → retrig
scripts['sc_wavehi.txt'] = (L, 800)

# S8: 16-bit wave at odd start address, slow pitch sweep crossing all word
# alignments (pos2/posb phase combinations)
L = []
keyon(L, 1, 7, wave=4, fn=0x100, oct_=-1)
for k, fr in enumerate(range(100, 700, 100)):
    slotw(L, fr, 7, 2, (((k - 2) & 0xF) << 4) | ((0x100 >> 7) & 7))
scripts['sc_odd16.txt'] = (L, 900)

# DIR-DEP: faithful replay of the hardware-captured BASIC tester order —
# KEY-ON first (with the previous note's wave still in the register = stale),
# THEN the wave-number write WHILE keyed (must retrigger to the new wave, like
# openMSX writeRegDirect case0).  Alternates 123/122 like the capture.  Two
# variants isolate intra-frame write timing: good (wc=1000, fetch resolves same
# frame) vs bad (wc=1780, past the fetch deadline → starves to next frame).
def dirdep(wc):
    L = []
    slotw(L, 1, 0, 2, (4 << 4) | 0)        # field2: octave 4
    slotw(L, 1, 0, 3, (0 << 1) | 1)        # field3: TL=0, load-immediate
    slotw(L, 1, 0, 0, 122)                 # field0: initial wave 122 (loads header)
    slotw(L, 1, 0, 1, (0x40 << 1) | 0)     # field1: FN-low, MSB=0
    fr = 30
    for w in [123, 122, 123, 122, 123, 122]:
        slotw(L, fr,   0, 4, 0x80 | 0x20)              # KEY-ON (wave reg = stale prev)
        slotw(L, fr+3, 0, 0, w, wc=wc)                 # wave -> w WHILE keyed (retrig)
        slotw(L, fr+3, 0, 1, (0x40 << 1) | 0, wc=wc)   # field1 (FN), as captured
        slotw(L, fr+95, 0, 4, 0x20)                    # key-off
        fr += 110
    return L
scripts['sc_dirdep_good.txt'] = (dirdep(1000), 700)
scripts['sc_dirdep_bad.txt']  = (dirdep(1780), 700)

# release-during-wave-change — the REAL captured hardware order KEYOFF->wave->KEYON
# (dirdep above uses keyon->wave-while-keyed = retrig = clean, missing the bug).
# Play 122, KEY-OFF, write wave-123 WHILE RELEASING (keyon=0 → NO retrig → stale
# pos), then KEY-ON.  The data-proven "찍": during the release window the slot
# reads the stale-pos wrong address; audible only if the release env stays loud.
# Model (release decays) vs engine (freeze?) → divergence localizes the bug.
L = []
slotw(L, 1,   0, 2, (4 << 4) | 0)        # octave 4
slotw(L, 1,   0, 3, (0 << 1) | 1)        # TL=0 load-immediate
slotw(L, 1,   0, 0, 122)                 # wave 122 (loads header)
slotw(L, 1,   0, 1, (0x40 << 1) | 0)     # FN
slotw(L, 30,  0, 4, 0x80 | 0x20)         # KEY-ON 122
slotw(L, 90,  0, 4, 0x20)                # KEY-OFF (release begins)
slotw(L, 100, 0, 0, 123)                 # wave-123 WHILE RELEASING (no retrig)
slotw(L, 100, 0, 1, (0x40 << 1) | 0)     # FN
slotw(L, 160, 0, 4, 0x80 | 0x20)         # KEY-ON 123 (re-trigger)
scripts['sc_relwave.txt'] = (L, 300)

for name, (lines, frames) in scripts.items():
    lines = [t[2] for t in sorted(lines, key=lambda t: (t[0], t[1]))]
    with open(f"{out}/{name}", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{name}: {len(lines)} writes, {frames} frames")
print("mem.bin/mem.hex written")
