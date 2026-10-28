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

MEM = bytearray([0]*0x80100)     # 0x80000+: wave-table header bank 1 (sc_tblhdr)

def header(wave, bits, start, loop_pos, end_pos, ar=15, d1r=0, dl=0, d2r=0, rc=15, rr=4, am=0, lfovib=0,
           base=None):
    if base is None: base = wave*12
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

# wave 386 in wave-table header bank 1 (reg 2 bits 4:2 = 1 -> 0x80000), for
# sc_tblhdr; 386*12 = 0x1218 is left zero, so a base computed without the bank
# loads an all-zero header (AR=0: silent)
header(386, 2, 0x2000, 0, 32, ar=13, d1r=5, dl=2, d2r=2, base=0x80000 + 2*12)

# waves 5 and 6 play from the RAM half (sc_memtype1): 8-bit, 64 samples, full loop.
# Their data is not in mem.bin -- the scenario uploads it through reg 6.
header(5, 0, 0x200000, 0, 64)
header(6, 0, 0x380000, 0, 64)

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

# S5b: a whole LFO period.  sc_lfo's speed 3 reaches only lfo_cnt 37,500 of 262,144 in
# 1,500 frames, so the vibrato fold (bit 16), its sign and the tremolo fold (bit 17)
# never run there.  Speed 7 (42 per frame) passes bit 17 at frame 3,121; slot 8 at
# speed 6 with other depths runs alongside.
L = []
keyon(L, 1, 3, wave=0, fn=0x100, oct_=-2, lfo_off=False)
slotw(L, 1, 3, 5, (7 << 3) | 7)                   # lfo speed 7, vib depth 7
slotw(L, 1, 3, 9, 7)                              # AM depth 7
keyon(L, 1, 8, wave=1, fn=0x1C0, oct_=-1, tl=6, pan=12, lfo_off=False)
slotw(L, 1, 8, 5, (6 << 3) | 4)
slotw(L, 1, 8, 9, 5)
scripts['sc_lfo_long.txt'] = (L, 3400)

# S5c: long envelopes.  Every other scenario ends by frame 3,400, so the EG counter's
# bits 12-14 (slow rates: shift 11-12, phase bits up to 14) and the LFO counter's
# wrap at 2^18 (frame 6,242 at speed 7) never ran.  Slot 2: slow decay to DL 15,
# then a slow sustain decay, LFO speed 7 with vibrato and tremolo, key-off at 7,000
# into a slow release.  Slot 9: AR 15, D1R 1 with RC 1 at octave 0, F-Num < 200h:
# decay rate 4 + 2 = 6 (shift 11, increment row {0,1,1,1,0,1,1,1}), so the EG phase
# at frame 4,096 is 2, not the 0 a 12-bit counter would give; released at 8,000.
L = []
keyon(L, 1, 2, wave=1, fn=0x200, oct_=0, tl=4, pan=3, lfo_off=False)
slotw(L, 1, 2, 5, (7 << 3) | 3)                   # lfo speed 7, vib depth 3
slotw(L, 1, 2, 6, (15 << 4) | 2)                  # AR 15, D1R 2
slotw(L, 1, 2, 7, (15 << 4) | 1)                  # DL 15, D2R 1
slotw(L, 1, 2, 8, (15 << 4) | 1)                  # RC 15, RR 1
slotw(L, 1, 2, 9, 3)                              # AM depth 3
W(L, 7000, 0x08 + 4*24 + 2, 0x03)                 # key-off (LFO stays on)
keyon(L, 100, 9, wave=0, fn=0x180, oct_=0, tl=2, pan=13)
slotw(L, 100, 9, 6, (15 << 4) | 1)
slotw(L, 100, 9, 7, (8 << 4) | 0)
slotw(L, 100, 9, 8, (1 << 4) | 2)                # RC 1, RR 2
W(L, 8000, 0x08 + 4*24 + 9, 0x2D)                 # key-off
scripts['sc_eg_long.txt'] = (L, 9000)

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

# MEM-HIT: CPU sample-RAM writes INTO the words two playing voices have cached.
# Until 2026-10-12 no scenario did: sc_memwrite's writes never matched a cached
# word, so the invalidate sweep compared but never cleared an entry (its PIPE
# split, the clear a cycle after the compare, had nothing to check).  Low pitch
# keeps each voice inside the same words for many frames (pos stays near 0); the
# writes cycle over the first two words of
# the 8-bit ramp (wave 0, 0x1000) and the 16-bit square (wave 1, 0x2000) and change
# the data, so a stale cached word is a sample difference, not just a flag.
L = []
W(L, 1, 0x02, 0x01)                             # memory access mode: openMSX ignores reg 6 without it
keyon(L, 1, 0, wave=0, fn=0x010, oct_=0x9)     # oct -7: < 1 sample per frame
keyon(L, 1, 5, wave=1, fn=0x010, oct_=0x9)
for k, fr in enumerate(range(20, 380, 3)):
    a = (0x1000 + (k // 2) % 4) if k % 2 == 0 else (0x2000 + (k // 2) % 4)
    W(L, fr, 0x03, (a >> 16) & 0x3F, 1000)
    W(L, fr, 0x04, (a >> 8) & 0xFF, 1020)
    W(L, fr, 0x05, a & 0xFF, 1040)
    W(L, fr, 0x06, (MEM[a] ^ 0x5A) & 0xFF, 1060)
scripts['sc_memhit.txt'] = (L, 400)

# ── 2026-10-24 (opl4_scratch P1): scenarios for behaviour the 12 above never
# exercised.  Each one exists because a mutant of the engine passed every other
# scenario (.claude/skills/opl4-harness/mutants/make_engine2_mutants.py).

# EG decay -> sustain exactly at DL (mut_eg_dl_gt).  RC=15 (no key scaling), so
# D1R=10 is rate 40: +1 per update, env lands on DL exactly; D2R=0 then holds it.
# Slot 1: a faster decay (rate 52, increments > 1) onto another DL.
L = []
keyon(L, 1, 0, wave=0, fn=0x200, oct_=0)
slotw(L, 1, 0, 6, 0xF0 | 10)          # AR=15 (instant), D1R=10
slotw(L, 1, 0, 7, (1 << 4) | 0)       # DL=1, D2R=0
slotw(L, 1, 0, 8, 0xF4)               # RC=15, RR=4
keyon(L, 1, 1, wave=1, fn=0x155, oct_=0, pan=3)
slotw(L, 1, 1, 6, 0xF0 | 13)
slotw(L, 1, 1, 7, (2 << 4) | 1)
slotw(L, 1, 1, 8, 0xF4)
scripts['sc_eg_dl.txt'] = (L, 900)

# DAMP and pseudo-reverb (mut_eg_nodamp, mut_eg_noprvb).  Slot 0: a sustained
# square, damped at frame 200 (field 4 bit 6 with key still on).  Slot 3: PRVB
# (field 2 bit 3) on a fast release: rate 52 down to dl_tab[6], then rate 20.
# Slot 5: damp written together with the key-off.
L = []
keyon(L, 1, 0, wave=1, fn=0x155, oct_=0)
slotw(L, 1, 0, 6, 0xF0 | 2); slotw(L, 1, 0, 7, 0xF1); slotw(L, 1, 0, 8, 0xF6)
W(L, 200, 0x08 + 4*24 + 0, 0x80 | 0x40 | 0x20)
keyon(L, 1, 3, wave=2, fn=0x2AA, oct_=1, pan=4)
slotw(L, 1, 3, 2, (1 << 4) | 0x08 | ((0x2AA >> 7) & 7))
slotw(L, 1, 3, 6, 0xF0); slotw(L, 1, 3, 7, 0x00); slotw(L, 1, 3, 8, 0xF0 | 13)
W(L, 150, 0x08 + 4*24 + 3, 0x20 | 4)
keyon(L, 1, 5, wave=0, fn=0x180, oct_=0, pan=12)
slotw(L, 1, 5, 6, 0xF0); slotw(L, 1, 5, 7, 0x00); slotw(L, 1, 5, 8, 0xF2)
W(L, 300, 0x08 + 4*24 + 5, 0x40 | 0x20 | 12)
scripts['sc_eg_damp.txt'] = (L, 1000)

# TL interpolation (field 3 bit 0 = 0): down toward 0x40, later back up toward
# 0x08 (mut_eg_tlramp2).  Every other scenario loads TL immediately.
L = []
keyon(L, 1, 2, wave=1, fn=0x200, oct_=0)
slotw(L, 100, 2, 3, (0x40 << 1) | 0)
slotw(L, 600, 2, 3, (0x08 << 1) | 0)
scripts['sc_tlramp.txt'] = (L, 1000)

# LFO reset (field 4 bit 5) mid-note, then LFO active again: the counter must
# restart from 0 (mut_lfo_noreset).  Vibrato and tremolo both on.
L = []
keyon(L, 1, 4, wave=0, fn=0x100, oct_=-2, lfo_off=False)
slotw(L, 1, 4, 5, (5 << 3) | 6)
slotw(L, 1, 4, 9, 3)
W(L, 400, 0x08 + 4*24 + 4, 0x80 | 0x20)
W(L, 410, 0x08 + 4*24 + 4, 0x80)
scripts['sc_lfo_reset.txt'] = (L, 1500)

# Every pan value 0..15, DO1 output select (field 4 bit 4 = muted on MoonSound),
# and the reg F9h PCM mix level (mut_pan_do1, mut_mix_f9).
L = []
keyon(L, 1, 6, wave=1, fn=0x155, oct_=0)
keyon(L, 1, 7, wave=0, fn=0x200, oct_=0, tl=8)
for p in range(16):
    W(L, 50 + 50*p, 0x08 + 4*24 + 6, 0x80 | 0x20 | p)
W(L, 830, 0x08 + 4*24 + 6, 0x80 | 0x20 | 0x10 | 3)
W(L, 870, 0x08 + 4*24 + 6, 0x80 | 0x20 | 5)
W(L, 900, 0xF9, (2 << 3) | 1)
W(L, 950, 0xF9, (7 << 3) | 5)
W(L, 1000, 0xF9, (0 << 3) | 6)
W(L, 1050, 0xF9, 0x00)
scripts['sc_pan_mix.txt'] = (L, 1100)

# Wave-table header bank (reg 2 bits 4:2 = 1 -> 0x80000) for wave >= 384, and a
# wave < 384 that must ignore it (mut_hdr_tblhdr).  Wave 386's header sits at
# 0x80000 + 2*12 (written with the other headers above).
L = []
W(L, 1, 0x02, 1 << 2)
slotw(L, 1, 8, 1, ((0x155 & 0x7F) << 1) | 1)
slotw(L, 1, 8, 0, 386 & 0xFF)
slotw(L, 1, 8, 2, (0 << 4) | ((0x155 >> 7) & 7))
slotw(L, 1, 8, 3, 1)
slotw(L, 1, 8, 4, 0x80 | 0x20 | 2)
slotw(L, 1, 9, 1, ((0x100 & 0x7F) << 1) | 1)
slotw(L, 1, 9, 0, 300 & 0xFF)
slotw(L, 1, 9, 2, (0 << 4) | ((0x100 >> 7) & 7))
slotw(L, 1, 9, 3, 1)
slotw(L, 1, 9, 4, 0x80 | 0x20 | 13)
scripts['sc_tblhdr.txt'] = (L, 600)

# LFO of a silent slot (SPEC I2): slot 6 plays with vibrato + tremolo, releases fast
# to EG_OFF, stays off ~300 frames and is keyed again.  openMSX keeps its LFO running
# while off; the RTL does not, so the re-keyed note starts at another LFO phase.
# Slot 7 plays quietly throughout, so some slot is always active (keeps I7 out).
L = []
keyon(L, 1, 7, wave=1, fn=0x100, oct_=-1, tl=0x30, pan=3)
keyon(L, 1, 6, wave=0, fn=0x100, oct_=-2, lfo_off=False)
slotw(L, 1, 6, 5, (7 << 3) | 7)
slotw(L, 1, 6, 9, 7)
slotw(L, 1, 6, 8, 0xFF)                          # RC=15, RR=15: off within a few frames
W(L, 150, 0x08 + 4*24 + 6, 0x00)                 # key-off, LFO stays active
keyon(L, 460, 6, wave=0, fn=0x100, oct_=-2, lfo_off=False)
slotw(L, 460, 6, 5, (7 << 3) | 7)                # the wave write reloaded fields 5-9
slotw(L, 460, 6, 9, 7)
scripts['sc_lfo_off.txt'] = (L, 900)

# Every slot silent (SPEC I7): openMSX generateChannels returns before advance() when
# no slot is active, so eg_cnt, the TL ramp and the LFOs stop; the RTL keeps counting.
# A note, release (RR=15: 4 steps a frame, off by frame ~180), ~80 silent frames, then a slow attack + decay + TL ramp + LFO
# whose step pattern depends on the eg_cnt phase.
L = []
keyon(L, 1, 3, wave=1, fn=0x155, oct_=0)
slotw(L, 1, 3, 8, 0xFF)
W(L, 20, 0x08 + 4*24 + 3, 0x20)
keyon(L, 260, 4, wave=0, fn=0x180, oct_=0, lfo_off=False)
slotw(L, 260, 4, 6, (9 << 4) | 9)               # AR=9, D1R=9 (RC=15 from the header)
slotw(L, 260, 4, 7, (3 << 4) | 5)               # DL=3, D2R=5
slotw(L, 260, 4, 5, (4 << 3) | 3)
slotw(L, 260, 4, 9, 2)
slotw(L, 340, 4, 3, (0x30 << 1) | 0)            # TL ramp
scripts['sc_silence.txt'] = (L, 900)

# MEMORY TYPE 1 (R#2 bit 1).  openMSX's MoonSound (MSXMoonSound.cc setupMemPtrs) maps
# RAM only at 0x380000 in mode 1 and leaves 0x200000-0x37FFFF unmapped (0xFF, writes
# ignored); the RTL keeps the flat mode-0 map (SPEC I8).  Upload two different ramps
# in mode 0, to 0x200000 (wave 5) and 0x380000 (wave 6), switch to mode 1, play both,
# write into 0x380000 in mode 1, then go back to mode 0.
L = []
W(L, 1, 0x02, 0x01)                             # mode 0, memory access on
def upload(L, fr0, a, data):
    W(L, fr0, 0x03, (a >> 16) & 0x3F, 1000)
    W(L, fr0, 0x04, (a >> 8) & 0xFF, 1020)
    W(L, fr0, 0x05, a & 0xFF, 1040)
    for k, d in enumerate(data):
        W(L, fr0 + 1 + k, 0x06, d, 1000)
upload(L, 2, 0x200000, [(i * 4 - 128) & 0xFF for i in range(64)])
upload(L, 70, 0x380000, [(96 - i * 3) & 0xFF for i in range(64)])
W(L, 140, 0x02, 0x03)                           # mode 1
keyon(L, 150, 0, wave=5, fn=0x200, oct_=0)
keyon(L, 150, 1, wave=6, fn=0x180, oct_=0)
upload(L, 250, 0x380000, [(i * 7) & 0xFF for i in range(32)])
W(L, 400, 0x02, 0x01)                           # back to mode 0
scripts['sc_memtype1.txt'] = (L, 600)

for name, (lines, frames) in scripts.items():
    lines = [t[2] for t in sorted(lines, key=lambda t: (t[0], t[1]))]
    with open(f"{out}/{name}", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{name}: {len(lines)} writes, {frames} frames")
print("mem.bin/mem.hex written")
