#!/usr/bin/env python3
"""
PCM golden comparator driver.

Feeds a register-write script + sample memory into a Python model that mirrors
the RTL engine's *frame semantics exactly* (v3 ymf278_pcm_engine2):
  - writes take effect for the NEXT frame (the RTL TB applies them in the
    previous frame's service window)
  - eg_cnt: frame N is processed with eg_cnt == N (RTL increments at the END
    of a frame; openMSX increments at the START — off by one vs YMF278.cc)
  - LFO/EG only advance for slots that are dispatched (not EG_OFF), matching
    the RTL skip; TL ramp ticks for every slot every frame
  - per-frame order per slot: vib(step) -> pos advance -> sample/interp ->
    EG rate/step -> AM -> gains -> pan -> accumulate; key-on edge resets
    pos/stepPtr and restarts the envelope (always, incl. re-key)

Tables/primitives are imported from ../reference_model.py (YMF278.cc port).

Usage: golden_pcm.py <script.txt> <mem.bin> <frames> <out.txt>
Script line: <frame> <addr_hex> <data_hex>   (# comments allowed)
Output line per frame: <L> <R>   (signed decimal)
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from reference_model import (
    MAX_ATT_INDEX, MIN_ATT_INDEX, EG_ATT, EG_DEC, EG_SUS, EG_REL, EG_OFF,
    LFO_PERIOD, eg_inc, eg_rate_select, eg_rate_shift, dl_tab,
    lfo_period, vib_depth, am_depth, pan_left, pan_right,
    Slot, calc_step, compute_rate, compute_decay_rate,
    compute_vib, compute_am, vol_factor, next_pos, get_sample,
)

def sign_extend_4(x):
    x &= 0xF
    return x - 16 if x & 8 else x

def compute_vib_rtl(s):
    # RTL: triangle fold -> |fm|*depth -> exact /12 via *43691>>19 on the
    # MAGNITUDE, then negate (truncation toward zero — python // would floor)
    fm6 = (s.lfo_cnt >> 12) & 0x3F
    if fm6 & 0x10: fm6 ^= 0x1F
    neg = bool(fm6 & 0x20)
    mag_fm = fm6 & 0x0F
    mag = mag_fm * vib_depth[s.vib]
    q = ((mag * 43691) >> 16) >> 3
    return -q if neg else q

def calc_step_signed(oct_, fn, vib=0):
    # RTL calc_step: t = (fn+1024+vib) << (8+oct) (negative oct = right shift), >>3
    if oct_ == -8:
        return 0
    sh = 8 + oct_
    t = (fn + 1024 + vib)
    t = (t << sh) if sh >= 0 else (t >> -sh)
    return (t >> 3) & 0xFFFFFFFF

class Engine:
    def __init__(self, memory):
        self.mem = memory
        self.slots = [Slot() for _ in range(24)]
        self.retrig = [False]*24
        self.wavetblhdr = 0
        self.pcm_mix_l = 0
        self.pcm_mix_r = 0
        self.frame = 0           # == RTL eg_cnt during this frame

    # ── register decode (mirrors RTL CPU decode + HF backfill) ──────────
    def load_header(self, s):
        w = s.wave
        if w < 384 or self.wavetblhdr == 0:
            base = w * 12
        else:
            base = (self.wavetblhdr << 19) + (w - 384) * 12
        rb = lambda a: self.mem[a] if a < len(self.mem) else 0xFF
        h = [rb(base+i) for i in range(12)]
        s.bits      = (h[0] >> 6) & 3
        s.startAddr = ((h[0] & 0x3F) << 16) | (h[1] << 8) | h[2]
        s.loopAddr  = (h[3] << 8) | h[4]
        s.endAddr   = (h[5] << 8) | h[6]
        # backfill (header bytes 7..11)
        s.lfo  = (h[7] >> 3) & 7
        s.vib  = h[7] & 7
        s.AR   = h[8] >> 4
        s.D1R  = h[8] & 0xF
        s.DL   = dl_tab[h[9] >> 4]
        s.D2R  = h[9] & 0xF
        s.RC   = h[10] >> 4
        s.RR   = h[10] & 0xF
        s.AM   = h[11] & 7

    def write(self, addr, data):
        if addr == 0x02:
            self.wavetblhdr = (data >> 2) & 7
            return
        if addr == 0xF9:
            self.pcm_mix_l = data & 7
            self.pcm_mix_r = (data >> 3) & 7
            return
        if not (0x08 <= addr <= 0xF7):
            return
        n = (addr - 8) % 24
        f = (addr - 8) // 24
        s = self.slots[n]
        if f == 0:
            if s.keyon:                      # wave overwrite while keyed → re-trigger
                self.retrig[n] = True
            s.wave = (s.wave & 0x100) | data
            self.load_header(s)
        elif f == 1:
            s.wave = (s.wave & 0xFF) | ((data & 1) << 8)
            s.FN = (s.FN & 0x380) | (data >> 1)
            self.load_header(s)
        elif f == 2:
            s.FN = (s.FN & 0x07F) | ((data & 7) << 7)
            s.PRVB = bool(data & 8)
            s.OCT = sign_extend_4(data >> 4)
        elif f == 3:
            tl = data >> 1
            tl = 0xFF if tl == 0x7F else tl
            s.TLdest = tl
            if data & 1:
                s.TL = tl                    # load immediate
        elif f == 4:
            s.pan = 8 if (data & 0x10) else (data & 0xF)
            s.DAMP = bool(data & 0x40)
            if (data & 0x80) and not s.keyon:
                self.retrig[n] = True        # key-on edge (write-time, like RTL)
            s.keyon = bool(data & 0x80)
            s.lfo_active = not bool(data & 0x20)
        elif f == 5:
            s.lfo = (data >> 3) & 7
            s.vib = data & 7
        elif f == 6:
            s.AR = data >> 4; s.D1R = data & 0xF
        elif f == 7:
            s.DL = dl_tab[data >> 4]; s.D2R = data & 0xF
        elif f == 8:
            s.RC = data >> 4; s.RR = data & 0xF
        elif f == 9:
            s.AM = data & 7

    # ── one frame, RTL-faithful ──────────────────────────────────────────
    def gen_frame(self):
        eg_cnt = self.frame            # RTL: frame N runs with eg_cnt == N
        tl_int_cnt  = eg_cnt % 9
        tl_int_step = (eg_cnt // 9) % 3
        left = right = 0

        for n, s in enumerate(self.slots):
            # TL ramp ticks every slot turn regardless of dispatch
            if tl_int_cnt == 0:
                if tl_int_step == 0:
                    if s.TL < s.TLdest: s.TL += 1
                else:
                    if s.TL > s.TLdest: s.TL -= 1

            edge = self.retrig[n] or (s.keyon and getattr(s, '_kprev', False) is False and s.keyon and not getattr(s, '_kprev', False))
            edge = self.retrig[n]      # RTL: write-time retrig latch covers all edges
            run = (s.state != EG_OFF) or edge
            if not run:
                continue
            self.retrig[n] = False

            # vib & step (uses lfo_cnt as stored = advanced in previous frames)
            vib = compute_vib_rtl(s) if (s.lfo_active and s.vib) else 0
            step = calc_step_signed(s.OCT, s.FN, vib)

            # pos advance (or key-on restart)
            if edge:
                s.pos = 0
                s.stepPtr = 0
            else:
                sp = s.stepPtr + (step & 0xFFFF)
                inc = (step >> 16) + (1 if sp > 0xFFFF else 0)
                s.stepPtr = sp & 0xFFFF
                if inc:
                    s.pos = next_pos(s, s.pos, inc)

            # sample + interp at (pos, stepPtr)
            sA = get_sample(self.mem, s, s.pos)
            sB = get_sample(self.mem, s, next_pos(s, s.pos, 1))
            sample = (sA * (0x10000 - s.stepPtr) + sB * s.stepPtr) >> 16

            # EG step (rate uses pre-update env_vol; key-on restarts envelope)
            if edge:
                rate = compute_rate(s, s.AR)
                if rate < 63:
                    s.env_vol = MAX_ATT_INDEX
                    s.state = EG_ATT
                else:
                    s.env_vol = MIN_ATT_INDEX
                    s.state = EG_DEC if s.DL else EG_SUS
            elif (not s.keyon) and s.state not in (EG_OFF, EG_REL):
                s.state = EG_REL
            else:
                if s.state == EG_ATT:
                    rate = compute_rate(s, s.AR)
                    if rate < 63:
                        shift = eg_rate_shift[rate]
                        if not (eg_cnt & ((1 << shift) - 1)):
                            sel = eg_rate_select[rate]
                            inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                            s.env_vol += (~s.env_vol * inc) >> 4
                            s.env_vol &= 0x3FF
                            if s.env_vol <= MIN_ATT_INDEX:
                                s.env_vol = MIN_ATT_INDEX
                                s.state = EG_DEC if s.DL else EG_SUS
                elif s.state == EG_DEC:
                    rate = compute_decay_rate(s, s.D1R)
                    shift = eg_rate_shift[rate]
                    if not (eg_cnt & ((1 << shift) - 1)):
                        sel = eg_rate_select[rate]
                        inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                        s.env_vol = min(s.env_vol + inc, 0x3FF)
                        if s.env_vol >= s.DL:
                            s.state = EG_SUS if s.env_vol < MAX_ATT_INDEX else EG_OFF
                elif s.state in (EG_SUS, EG_REL):
                    rate = compute_decay_rate(s, s.D2R if s.state == EG_SUS else s.RR)
                    shift = eg_rate_shift[rate]
                    if not (eg_cnt & ((1 << shift) - 1)):
                        sel = eg_rate_select[rate]
                        inc = eg_inc[sel + ((eg_cnt >> shift) & 7)]
                        s.env_vol += inc
                        if s.env_vol >= MAX_ATT_INDEX:
                            s.env_vol = MAX_ATT_INDEX
                            s.state = EG_OFF

            # AM + two-stage gain + pan + accumulate
            env = min(s.env_vol + (compute_am(s) if (s.lfo_active and s.AM) else 0),
                      MAX_ATT_INDEX)
            smpl = vol_factor(vol_factor(sample, env), s.TL << 2)
            vl, vr = pan_left[s.pan], pan_right[s.pan]
            gl = (0x20 - (vl & 0xF)) >> (vl >> 4) if vl != 255 else 0
            gr = (0x20 - (vr & 0xF)) >> (vr >> 4) if vr != 255 else 0
            left  += (smpl * gl) >> 5
            right += (smpl * gr) >> 5

            # LFO advance (dispatched slots only, like RTL writeback)
            if s.lfo_active:
                s.lfo_cnt = (s.lfo_cnt + lfo_period[s.lfo]) % LFO_PERIOD
            else:
                s.lfo_cnt = 0

        self.frame += 1
        sat = lambda v: max(-32768, min(32767, v))
        return sat(left), sat(right)


def main():
    script_f, mem_f, frames, out_f = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    mem = list(open(mem_f, 'rb').read())
    eng = Engine(mem)
    writes = {}
    for ln in open(script_f):
        ln = ln.split('#')[0].strip()
        if not ln: continue
        fr, ad, da = ln.split()
        writes.setdefault(int(fr), []).append((int(ad, 16), int(da, 16)))
    with open(out_f, 'w') as out:
        for fr in range(frames):
            for ad, da in writes.get(fr, []):
                eng.write(ad, da)
            l, r = eng.gen_frame()
            out.write(f"{l} {r}\n")
    print(f"golden: {frames} frames -> {out_f}")

if __name__ == "__main__":
    main()
