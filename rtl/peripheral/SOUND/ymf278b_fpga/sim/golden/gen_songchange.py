#!/usr/bin/env python3
"""
Song-change (screen transition) golden scenarios — the pattern the original
8 scenarios never cover:

    play N slots  ->  TL fade  ->  mass KEY-OFF  ->  full re-program of every
    slot with a DIFFERENT wave / pitch / TL / envelope  ->  KEY-ON again

Real drivers write the wave number FIRST (field 0, which is what arms the
header load) and the other 11 slot registers immediately after, inside the
same interrupt or the next one.  That is reproduced verbatim here.

Generates (into this directory, alongside the stock sc_*.txt):
  sc_songchange.txt    6 voices, paced writes, fade + transition + new song
  sc_songchange24.txt  all 24 voices, entire re-program crammed into ONE frame
                       (worst case for the engine's per-frame header-fetch
                        budget: 24 stalls x ~110 cycles vs 1948 cycles/frame)
  sc_memwrite.txt      wave-RAM upload (regs 03/04/05/06) interleaved with
                       playback, including an overwrite of the sample data of
                       a wave that is playing (word-cache invalidation), then a
                       key-on of the freshly uploaded wave

Uses the same mem.bin/mem.hex produced by gen_pcm_testdata.py (run that first).
Line format: "<frame> <addr_hex> <data_hex> <apply_cycle>"
"""
import os

OUT = os.path.dirname(os.path.abspath(__file__))

def W(L, fr, addr, data, wc=1000):
    L.append((fr, wc, len(L), f"{fr} {addr:02x} {data:02x} {wc}"))

def slotw(L, fr, n, field, data, wc=1000):
    W(L, fr, 0x08 + field*24 + n, data, wc)

TL_OFF = 0   # global attenuation offset, set per scenario to avoid clipping
             # (a saturated frame compares equal in both models = blind spot)

def prog_wave_pitch(L, fr, n, wave, fn, oct_, tl, wc=1000):
    """Wave number + pitch + TL.  The wave-LSB write (field 0) is what arms the
    header load, so it goes first — the real driver order.  For wave >= 256 the
    bit-8 carrier (field 1) must precede it, exactly like sc_wavehi and every
    real driver, otherwise the load is armed with the wrong wave number (that is
    true of openMSX/hardware too, so it would not be a core bug)."""
    f0 = lambda: slotw(L, fr, n, 0, wave & 0xFF, wc)
    f1 = lambda: slotw(L, fr, n, 1, ((fn & 0x7F) << 1) | ((wave >> 8) & 1), wc)
    if wave >= 256: f1(); f0()
    else:           f0(); f1()
    slotw(L, fr, n, 2, ((oct_ & 0xF) << 4) | ((fn >> 7) & 7), wc)    # OCT + FN hi
    tl = min(tl + TL_OFF, 0x7E)
    slotw(L, fr, n, 3, (tl << 1) | 1, wc)                            # TL, load now

def prog_env(L, fr, n, ar, d1r, dl, d2r, rc, rr, wc=1000):
    """fields 5..9 written AFTER the wave number — they must survive the
    header backfill (openMSX backfills synchronously at the field-0 write; the
    RTL defers the fetch and skips fields the CPU touched since = bf_dirty)."""
    slotw(L, fr, n, 5, 0x00, wc)                                     # LFO/vib off
    slotw(L, fr, n, 6, (ar << 4) | d1r, wc)
    slotw(L, fr, n, 7, (dl << 4) | d2r, wc)
    slotw(L, fr, n, 8, (rc << 4) | rr, wc)
    slotw(L, fr, n, 9, 0x00, wc)                                     # AM off

def prog_tone(L, fr, n, wave, fn, oct_, tl, pan, ar, d1r, dl, d2r, rc, rr, wc=1000):
    prog_wave_pitch(L, fr, n, wave, fn, oct_, tl, wc)
    prog_env(L, fr, n, ar, d1r, dl, d2r, rc, rr, wc)
    return pan

def pan_ok(pan):
    # pan == 8 is "output to DO1 pin" = both channels -inf dB on a real YMF278
    # (YMF278.cc case 4).  A muted voice contributes nothing, so never use it in
    # a comparison scenario — it would silently remove a voice from the test.
    return 7 if (pan & 0xF) == 8 else (pan & 0xF)

def keyon(L, fr, n, pan, wc=1000):
    slotw(L, fr, n, 4, 0x80 | 0x20 | pan_ok(pan), wc)   # key-on, LFO disabled

def keyoff(L, fr, n, pan=0, wc=1000):
    slotw(L, fr, n, 4, 0x20 | pan_ok(pan), wc)

def dump(name, L, frames):
    lines = [t[3] for t in sorted(L, key=lambda t: (t[0], t[1], t[2]))]
    with open(f"{OUT}/{name}", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{name}: {len(lines)} writes, {frames} frames")

# ══════════════════════════════════════════════════════════════════════════
# S9 — sc_songchange: 6 voices, realistic pacing
# ══════════════════════════════════════════════════════════════════════════
# (slot, wave, fn, oct, tl, pan, ar,d1r, dl,d2r, rc,rr)
SONG_A = [
    (0,   0, 0x200,  0,  0,  0, 15, 0,  0, 0, 15, 7),
    (1,   1, 0x155,  1,  4, 14, 15, 2,  2, 1, 15, 6),
    (2,   2, 0x2AA, -1,  8,  2, 14, 3,  4, 2, 15, 8),
    (3,   3, 0x180,  1,  2,  8, 12, 4,  3, 2, 15, 5),
    (4, 122, 0x100,  0, 12,  4, 15, 0,  0, 0, 15, 9),
    (5,   1, 0x0C0,  2,  6, 12, 13, 1,  1, 1, 15, 4),
]
# new song: every voice gets a DIFFERENT wave, pitch, TL and envelope
SONG_B = [
    (0,   2, 0x0C0,  1, 10, 12, 13, 5,  5, 3, 15, 10),
    (1,   4, 0x300, -1,  0,  1, 15, 0,  0, 0, 15, 4),
    (2, 123, 0x1C0,  2,  6,  6, 11, 6,  6, 4, 14, 12),
    (3, 300, 0x240,  0,  3, 10, 10, 6,  2, 3, 15, 7),   # backfill-only
    (4,   3, 0x3C0, -2, 14,  9, 12, 4,  3, 2, 15, 5),   # backfill-only
    (5,   0, 0x1A0,  1,  1, 15, 15, 0,  0, 0, 15, 8),
]

TL_OFF = 34
L = []
# --- song A starts: 2 voices per frame (a real driver's per-interrupt budget)
for i, v in enumerate(SONG_A):
    fr = 1 + i // 2
    prog_tone(L, fr, v[0], v[1], v[2], v[3], v[4], v[5], *v[6:])
    keyon(L, fr + 1, v[0], v[5])
# --- normal in-song note changes: wave rewrite WHILE keyed = re-trigger
for k, fr in enumerate(range(60, 300, 40)):
    n = k % 3
    w = [0, 1, 2, 3, 122][(k + 1) % 5]
    slotw(L, fr, n, 0, w & 0xFF)                       # retrig to new wave
    slotw(L, fr, n, 1, (((0x100 + k * 23) & 0x7F) << 1) | 0)
    slotw(L, fr, n, 2, ((k % 3) << 4) | (((0x100 + k * 23) >> 7) & 7))
# --- transition begins: TL fade-out (target only, no load-immediate → ramp)
for v in SONG_A:
    slotw(L, 300, v[0], 3, (min(0x3F + TL_OFF, 0x7E) << 1) | 0)
# --- mass key-off, all six in one interrupt
for v in SONG_A:
    keyoff(L, 340, v[0], v[5])
# --- full re-program of every slot: wave first, then the rest.
#     fields 0..3 in one frame, the envelope block in the next — the realistic
#     split of a 12-register-per-voice re-program across two interrupts.
#     Slots 3 and 4 deliberately get NO envelope block: they inherit the new
#     wave's own envelope through the header backfill (openMSX does it at the
#     field-0 write, the RTL at the deferred header store).
BACKFILL_ONLY = {3, 4}
for v in SONG_B:
    n, wave, fn, oct_, tl = v[0], v[1], v[2], v[3], v[4]
    prog_wave_pitch(L, 350, n, wave, fn, oct_, tl)
    if n not in BACKFILL_ONLY:
        prog_env(L, 351, n, *v[6:])
# --- new song keys on
for v in SONG_B:
    keyon(L, 352, v[0], v[5])
# --- new song plays: further note changes
for k, fr in enumerate(range(400, 900, 40)):
    n  = k % 6
    w  = [2, 4, 123, 300, 0, 3][k % 6]
    fn = 0x140 + k * 31
    prog_wave_pitch(L, fr, n, w, fn, (k + 1) % 3, SONG_B[n][4])
dump('sc_songchange.txt', L, 1000)

# ══════════════════════════════════════════════════════════════════════════
# S10 — sc_songchange24: all 24 voices, whole transition crammed per frame
# ══════════════════════════════════════════════════════════════════════════
TL_OFF = 62
WAVES_A = [0, 1, 2, 3, 122, 123, 4, 1]
WAVES_B = [2, 3, 0, 123, 4, 122, 1, 300]

L = []
for n in range(24):
    fr = 1 + n // 2
    w = WAVES_A[n % 8]
    prog_tone(L, fr, n, w, 0x100 + n * 17, (n % 4) - 1, (n * 5) % 40, n % 16,
              15 - (n % 4), n % 5, n % 8, n % 4, 15, 4 + (n % 8))
    keyon(L, fr + 1, n, n % 16)
# mass key-off — every voice, one frame
for n in range(24):
    keyoff(L, 300, n, n % 16)
# full re-program, ALL 24 voices' fields 0..3 in ONE frame (96 writes)
for n in range(24):
    prog_wave_pitch(L, 310, n, WAVES_B[n % 8], 0x080 + n * 23,
                    (n % 5) - 2, (n * 3) % 48)
for n in range(24):
    if n % 4 != 3:          # every 4th voice inherits the wave's own envelope
        prog_env(L, 311, n, 13 - (n % 4), n % 6, n % 7, n % 3, 15, 5 + (n % 7))
for n in range(24):
    keyon(L, 312, n, (n + 3) % 16)
dump('sc_songchange24.txt', L, 700)

# ══════════════════════════════════════════════════════════════════════════
# S11 — sc_memwrite: wave-RAM upload interleaved with playback
# ══════════════════════════════════════════════════════════════════════════
# Reg 03/04/05 = 24-bit address (05 last), reg 06 = data with auto-increment.
# All upload bytes are placed LATE in the frame (wc >= 1750) so every slot of
# that frame has already been serviced — this keeps the RTL's "applied during
# frame N-1" and the model's "applied before frame N" semantics identical.
TL_OFF = 26
UPLOAD_WC = [1750, 1790, 1830, 1870]

def upload(L, fr0, addr, data):
    """Stream `data` from `addr`, 4 bytes per frame, with the address set once."""
    L2 = []
    W(L2, fr0, 0x03, (addr >> 16) & 0xFF, 1700)
    W(L2, fr0, 0x04, (addr >> 8) & 0xFF, 1720)
    W(L2, fr0, 0x05, addr & 0xFF, 1740)
    fr = fr0
    for i, b in enumerate(data):
        if i and i % 4 == 0:
            fr += 1
        W(L2, fr, 0x06, b, UPLOAD_WC[i % 4])
    L.extend(L2)
    return fr + 1

# new wave 5 = 8-bit 32-sample down-ramp @ 0x8000, AR=15 D1R=0 RC=15 RR=6
hdr5 = [
    (0 << 6) | ((0x8000 >> 16) & 0x3F), (0x8000 >> 8) & 0xFF, 0x8000 & 0xFF,
    0x00, 0x00,                                        # loop 0
    ((0x10000 - 32) >> 8) & 0xFF, (0x10000 - 32) & 0xFF,
    0x00, (15 << 4) | 0, (0 << 4) | 0, (15 << 4) | 6, 0x00,
]
smp5 = [(120 - i * 8) & 0xFF for i in range(32)]

L = []
# two voices playing throughout
prog_tone(L, 1, 0, 0,   0x180,  0, 0,  0, 15, 0, 0, 0, 15, 7)
prog_tone(L, 1, 1, 2,   0x200, -1, 6, 14, 14, 2, 2, 1, 15, 6)
keyon(L, 2, 0, 0)
keyon(L, 2, 1, 14)
# 1) upload the header of wave 5 (12 bytes -> 3 frames)
nxt = upload(L, 40, 5 * 12, hdr5)
# 2) upload its 32 samples
nxt = upload(L, nxt + 2, 0x8000, smp5)
# 3) key slot 2 on with the freshly uploaded wave
prog_tone(L, nxt + 4, 2, 5, 0x140, 0, 2, 3, 15, 0, 0, 0, 15, 7)
keyon(L, nxt + 5, 2, 3)
# 4) OVERWRITE the sample data of wave 0 WHILE slot 0 is playing it
#    (word-cache invalidation test: the engine caches fetched words per slot)
nxt2 = upload(L, 300, 0x1000, [((i * 9 + 40) ^ 0x55) & 0xFF for i in range(64)])
# 5) and overwrite wave 2's 12-bit data while slot 1 plays it
upload(L, nxt2 + 4, 0x3000, [((i * 13) ^ 0xA3) & 0xFF for i in range(48)])
# 6) after the overwrites, retrigger slot 0 so the new data is heard from pos 0
slotw(L, 420, 0, 0, 0)
dump('sc_memwrite.txt', L, 700)
