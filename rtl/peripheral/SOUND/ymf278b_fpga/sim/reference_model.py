#!/usr/bin/env python3
"""
YMF278 PCM Reference Model
Ports openMSX YMF278.cc envelope/interpolation/volume logic to Python.
Used for bit-exact comparison with RTL simulation output.
"""

import struct
import sys

# ── Constants (from YMF278.cc) ────────────────────────────────────────
MAX_ATT_INDEX = 0x280
MIN_ATT_INDEX = 0
TL_SHIFT      = 2
LFO_SHIFT     = 18
LFO_PERIOD    = 1 << LFO_SHIFT

EG_ATT = 4
EG_DEC = 3
EG_SUS = 2
EG_REL = 1
EG_OFF = 0

# ── Lookup tables ─────────────────────────────────────────────────────
RATE_STEPS = 8
eg_inc = [
    0,1, 0,1, 0,1, 0,1,
    0,1, 0,1, 1,1, 0,1,
    0,1, 1,1, 0,1, 1,1,
    0,1, 1,1, 1,1, 1,1,
    1,1, 1,1, 1,1, 1,1,
    1,1, 1,2, 1,1, 1,2,
    1,2, 1,2, 1,2, 1,2,
    1,2, 2,2, 1,2, 2,2,
    2,2, 2,2, 2,2, 2,2,
    2,2, 2,4, 2,2, 2,4,
    2,4, 2,4, 2,4, 2,4,
    2,4, 4,4, 2,4, 4,4,
    4,4, 4,4, 4,4, 4,4,
    8,8, 8,8, 8,8, 8,8,
    0,0, 0,0, 0,0, 0,0,
]

def O(a): return a * RATE_STEPS

eg_rate_select = [
    O(14),O(14),O(14),O(14),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(0),O(1),O(2),O(3),
    O(4),O(5),O(6),O(7),
    O(8),O(9),O(10),O(11),
    O(12),O(12),O(12),O(12),
]

eg_rate_shift = [
    12,12,12,12,
    11,11,11,11,
    10,10,10,10,
    9,9,9,9,
    8,8,8,8,
    7,7,7,7,
    6,6,6,6,
    5,5,5,5,
    4,4,4,4,
    3,3,3,3,
    2,2,2,2,
    1,1,1,1,
    0,0,0,0,
    0,0,0,0,
    0,0,0,0,
    0,0,0,0,
]

lfo_period = [1, 12, 19, 25, 31, 35, 37, 42]
vib_depth  = [0, 2, 3, 4, 6, 12, 24, 48]
am_depth   = [0x00, 0x14, 0x20, 0x28, 0x30, 0x40, 0x50, 0x80]

pan_left  = [0, 8, 16, 24, 32, 40, 48, 255, 255, 0, 0, 0, 0, 0, 0, 0]
pan_right = [0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 48, 40, 32, 24, 16, 8]

def SC(dB): return (dB // 3) * 0x20
dl_tab = [SC(0),SC(3),SC(6),SC(9),SC(12),SC(15),SC(18),SC(21),
          SC(24),SC(27),SC(30),SC(33),SC(36),SC(39),SC(42),SC(93)]


# ── Slot state ────────────────────────────────────────────────────────
class Slot:
    def __init__(self):
        self.reset()

    def reset(self):
        self.wave = self.FN = self.TLdest = self.TL = self.pan = 0
        self.vib = self.AM = 0
        self.OCT = 0
        self.DL = 0
        self.AR = self.D1R = self.D2R = self.RC = self.RR = 0
        self.PRVB = self.keyon = self.DAMP = False
        self.stepPtr = 0
        self.bits = 0
        self.startAddr = 0
        self.loopAddr = self.endAddr = 0
        self.env_vol = MAX_ATT_INDEX
        self.lfo_active = False
        self.lfo_cnt = 0
        self.lfo = 0
        self.state = EG_OFF
        self.pos = 0
        self.step = calc_step(0, 0)


def calc_step(oct, fn, vib=0):
    """Returns step as an unsigned 32-bit value."""
    if oct == -8:
        return 0
    # sign-extend 4-bit oct
    if oct & 8:
        oct = oct - 16
    t = (fn + 1024 + vib) << (8 + oct)
    return (t >> 3) & 0xFFFFFFFF


def sign_extend_4(x):
    x = x & 0xF
    return x - 16 if x & 8 else x


def compute_rate(slot, val):
    if val == 0:  return 0
    if val == 15: return 63
    res = val * 4
    if slot.RC != 15:
        clamped = max(0, min(15, slot.OCT + slot.RC))
        res += 2 * clamped
        if slot.FN & 0x200:
            res += 1
    return max(0, min(63, res))


def compute_decay_rate(slot, val):
    if slot.DAMP:
        return 48 if slot.env_vol < dl_tab[4] else 63
    if slot.PRVB:
        if slot.env_vol >= dl_tab[6]:
            return 20
    return compute_rate(slot, val)


def compute_vib(slot):
    lfo_fm = (slot.lfo_cnt // (LFO_PERIOD // 0x40)) & 0x3F
    if lfo_fm & 0x10: lfo_fm ^= 0x1F
    if lfo_fm & 0x20: lfo_fm = -(lfo_fm & 0x0F)
    return (lfo_fm * vib_depth[slot.vib]) // 12


def compute_am(slot):
    lfo_am = (slot.lfo_cnt // (LFO_PERIOD // 0x100)) & 0xFF
    if lfo_am >= 0x80: lfo_am ^= 0xFF
    return (lfo_am * am_depth[slot.AM]) >> 7


def vol_factor(x, env_vol):
    """Apply volume attenuation. x is signed 16-bit."""
    if env_vol >= MAX_ATT_INDEX:
        return 0
    vol_mul   = 0x80 - (env_vol & 0x3F)
    vol_shift = 7 + (env_vol >> 6)
    scaled = (0x8000 * vol_mul) >> vol_shift
    result = (x * scaled) >> 15
    # clamp to int16
    return max(-32768, min(32767, result))


def next_pos(slot, pos, increment):
    pos = (pos + increment) & 0xFFFF
    if (pos + slot.endAddr) >= 0x10000:
        pos = (pos + slot.endAddr + slot.loopAddr) & 0xFFFF
    return pos


def get_sample(memory, slot, pos):
    if slot.bits == 0:  # 8-bit
        b = memory[slot.startAddr + pos] if (slot.startAddr + pos) < len(memory) else 0xFF
        v = (b << 8)
        return struct.unpack('<h', struct.pack('<H', v & 0xFFFF))[0]
    elif slot.bits == 1:  # 12-bit
        addr = slot.startAddr + (pos // 2) * 3
        def rb(a): return memory[a] if a < len(memory) else 0xFF
        if pos & 1:
            v = (rb(addr+2) << 8) | (rb(addr+1) & 0xF0)
        else:
            v = (rb(addr+0) << 8) | ((rb(addr+1) << 4) & 0xF0)
        return struct.unpack('<h', struct.pack('<H', v & 0xFFFF))[0]
    else:  # 16-bit
        addr = slot.startAddr + pos * 2
        def rb(a): return memory[a] if a < len(memory) else 0xFF
        v = (rb(addr) << 8) | rb(addr+1)
        return struct.unpack('<h', struct.pack('<H', v & 0xFFFF))[0]


def advance(slots, eg_cnt):
    """Update all 24 slots' envelopes. Called once per sample."""
    eg_cnt += 1

    tl_int_cnt  =  eg_cnt % 9
    tl_int_step = (eg_cnt // 9) % 3

    for slot in slots:
        # TL interpolation
        if tl_int_cnt == 0:
            if tl_int_step == 0:
                if slot.TL < slot.TLdest: slot.TL += 1
            else:
                if slot.TL > slot.TLdest: slot.TL -= 1

        # LFO
        if slot.lfo_active:
            slot.lfo_cnt = (slot.lfo_cnt + lfo_period[slot.lfo]) % LFO_PERIOD

        # EG
        if slot.state == EG_ATT:
            rate = compute_rate(slot, slot.AR)
            if rate < 63:
                shift = eg_rate_shift[rate]
                if not (eg_cnt & ((1 << shift) - 1)):
                    sel = eg_rate_select[rate]
                    inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                    slot.env_vol += (~slot.env_vol * inc) >> 4  # signed: ~ev is negative
                    slot.env_vol &= 0x3FF
                    if slot.env_vol <= MIN_ATT_INDEX:
                        slot.env_vol = MIN_ATT_INDEX
                        slot.state = EG_DEC if slot.DL else EG_SUS

        elif slot.state == EG_DEC:
            rate  = compute_decay_rate(slot, slot.D1R)
            shift = eg_rate_shift[rate]
            if not (eg_cnt & ((1 << shift) - 1)):
                sel = eg_rate_select[rate]
                inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                slot.env_vol += inc
                if slot.env_vol >= slot.DL:
                    slot.state = EG_SUS if slot.env_vol < MAX_ATT_INDEX else EG_OFF

        elif slot.state == EG_SUS:
            rate  = compute_decay_rate(slot, slot.D2R)
            shift = eg_rate_shift[rate]
            if not (eg_cnt & ((1 << shift) - 1)):
                sel = eg_rate_select[rate]
                inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                slot.env_vol += inc
                if slot.env_vol >= MAX_ATT_INDEX:
                    slot.env_vol = MAX_ATT_INDEX
                    slot.state = EG_OFF

        elif slot.state == EG_REL:
            rate  = compute_decay_rate(slot, slot.RR)
            shift = eg_rate_shift[rate]
            if not (eg_cnt & ((1 << shift) - 1)):
                sel = eg_rate_select[rate]
                inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                slot.env_vol += inc
                if slot.env_vol >= MAX_ATT_INDEX:
                    slot.env_vol = MAX_ATT_INDEX
                    slot.state = EG_OFF

    return eg_cnt


def generate_sample(memory, slots, eg_cnt):
    """Generate one stereo sample from all 24 slots. Returns (left, right, eg_cnt)."""
    left = right = 0.0
    for slot in slots:
        if slot.state == EG_OFF:
            continue
        sA = get_sample(memory, slot, slot.pos)
        sB = get_sample(memory, slot, next_pos(slot, slot.pos, 1))
        sample = (sA * (0x10000 - slot.stepPtr) + sB * slot.stepPtr) >> 16
        # clamp to int16
        sample = max(-32768, min(32767, sample))

        env_vol = min(slot.env_vol + (compute_am(slot) if slot.lfo_active and slot.AM else 0),
                      MAX_ATT_INDEX)
        smpl = vol_factor(vol_factor(sample, env_vol), slot.TL << TL_SHIFT)

        vl = pan_left[slot.pan]
        vr = pan_right[slot.pan]
        vol_l = (0x20 - (vl & 0x0F)) >> (vl >> 4) if vl != 255 else 0
        vol_r = (0x20 - (vr & 0x0F)) >> (vr >> 4) if vr != 255 else 0
        left  += (smpl * vol_l) >> 5
        right += (smpl * vol_r) >> 5

        step = calc_step(slot.OCT, slot.FN,
                         compute_vib(slot) if slot.lfo_active and slot.vib else 0)
        slot.stepPtr = (slot.stepPtr + step) & 0xFFFFFFFF
        if slot.stepPtr >= 0x10000:
            slot.pos = next_pos(slot, slot.pos, slot.stepPtr >> 16)
            slot.stepPtr &= 0xFFFF

    eg_cnt = advance(slots, eg_cnt)
    return int(left), int(right), eg_cnt


# ── Verification against RTL ──────────────────────────────────────────
def verify_envelope_sequence(ar=8, d1r=5, d2r=2, rr=5, dl_idx=6,
                              n_attack=100, n_sustain=200, n_release=200):
    """
    Simulate envelope for one slot and print the trajectory.
    Compare expected behaviour with RTL VCD output.
    """
    slot = Slot()
    slot.AR  = ar
    slot.D1R = d1r
    slot.D2R = d2r
    slot.RR  = rr
    slot.DL  = dl_tab[dl_idx]
    slot.FN  = 512
    slot.OCT = 0
    slot.RC  = 15
    eg = 0

    # Key on
    slot.env_vol = MAX_ATT_INDEX
    rate = compute_rate(slot, slot.AR)
    if rate < 63:
        slot.state = EG_ATT
    else:
        slot.env_vol = MIN_ATT_INDEX
        slot.state   = EG_DEC if slot.DL else EG_SUS
    slot.keyon = True

    print("Sample, State, env_vol")
    history = []
    for s in range(n_attack + n_sustain):
        print(f"{s:5d}, {slot.state}, 0x{slot.env_vol:03X}")
        history.append((s, slot.state, slot.env_vol))
        eg = advance([slot], eg)

    # Key off
    slot.state = EG_REL
    slot.keyon = False
    for s in range(n_release):
        print(f"{n_attack+n_sustain+s:5d}, {slot.state}, 0x{slot.env_vol:03X}")
        history.append((n_attack+n_sustain+s, slot.state, slot.env_vol))
        eg = advance([slot], eg)
        if slot.state == EG_OFF:
            print(f"  -> Reached EG_OFF at sample {n_attack+n_sustain+s}")
            break
    return history


if __name__ == "__main__":
    print("=== YMF278 Reference Model: Envelope Trace ===")
    verify_envelope_sequence()
