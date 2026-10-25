#!/usr/bin/env python3
"""CPU-visible lockstep check: tb_cpuvis.sv log vs an openMSX YMF278B model.

    cpuvis_check.py <cpuvis.log> <mem.bin> [--dev D1,D2,...|--dev none] [--quiet]

The model is openMSX (~/data/openmsx_v9968) src/sound/YMF278B.cc (port decode,
BUSY/LD times), YMF278.cc (writeRegDirect / readReg / peekReg / reset) and
YMF262.cc (the NEW2 one-shot, register read-back).  Each access is replayed at
the clock cycle the RTL performed it, so the comparison is per access, not per
schedule.

The RTL differs from openMSX on purpose or by known defect in the ways listed
in DEVIATIONS (docs/opl4_scratch/SPEC.md section D).  --dev selects which of
them the model applies; the gate runs with all of them.  A new engine that
removes a deviation must drop its flag here in the same commit.

Checks per access:
  data   every read (wave/FM data port, status): exact.  A status bit within 4
         clk of its expected change is not compared (bridge/CDC pipeline), nor a
         BUSY bit inside the window of an engine-paced memory operation.
  ack    cycles from request to io_ack: <= 4, or the documented hold (D2).
  busy   when the BUSY bit falls after the access (status_export transitions).
  ld     when status bit 1 falls after the access (LD and the NEW2 one-shot).

Exit 0 = every check passed AND every deviation flag in use changes at least
one observation of this op script (otherwise the script no longer tests it).
"""
import os, sys, math

MASTER_HZ = 33868800
# YMF278B.cc:14-39 (master clocks)
FM_REG_SELECT_DELAY = 56
FM_REG_WRITE_DELAY = 56
WAVE_REG_SELECT_DELAY = 88
WAVE_REG_WRITE_DELAY = 88
MEM_READ_DELAY = 38
MEM_WRITE_DELAY = 28
LOAD_DELAY = 10000
# reg 6 write BUSY/WAIT floor in clk_sdram cycles: ymf278b_regs MEM_WRITE_DELAY as the top
# sets it (1024 with engine2, 107 = openMSX's 28 master clocks with engine3); run_cpuvis.sh
RTL_MEM_WRITE_DELAY = int(os.environ.get('CPUVIS_MEMW', '1024'))

DEVIATIONS = {
    'D1': "BUSY/LD delays counted in clk_sdram cycles, not master clocks (ymf278b_regs.sv:52-83)",
    'D2': "a write to the wave data port with latch 3..6 holds the CPU (io_ack) until BUSY clears; "
          f"BUSY = {RTL_MEM_WRITE_DELAY} clk (ymf278b_regs.sv MEM_WRITE_DELAY, set by ymf278b_top.sv)",
    'D3': "reg 6 reads/writes ignore reg 2 bit 0 (memory access mode) (ymf278_pcm_engine2.sv:1666-1722)",
    'D4': "reg 3/4 writes change the memory address at once; openMSX latches it only on reg 5 "
          "(ymf278_pcm_engine2.sv:1683-1684)",
    'D5': "the NEW2 one-shot (status 02h) is re-armed on every NEW2 0->1, not once per reset "
          "(ymf278b_regs.sv:166-169,307-312)",
    'D6': "reg F8h reads 00h after reset (openMSX 1Bh) (ymf278_pcm_engine2.sv:1542-1547)",
    'D7': "a reg 6 read returns the byte prefetched at the last reg 5 write / reg 6 read, "
          "stale after reg 6 writes (ymf278_pcm_engine2.sv:1702,1716-1721)",
    'D8': "after a reg 5/6 write or a reg 6 read BUSY also waits for the engine's memory op "
          "(<= 1 frame) (ymf278b_regs.sv:141; ymf278_pcm_engine2.sv:1722)",
    'D9': "a warm reset clears NEW2 (openMSX keeps reg 105h) (ymf278b_top.sv:90-102)",
    'D10': "after reset the field-4 registers 68h-7Fh read 20h (engine2 stores bit 5 inverted); "
           "openMSX's reset writes 0 to them (YMF278.cc reset, case 4) (ymf278_pcm_engine2.sv:1454-1456)",
    'D11': "after reset fields 5-9 read 0; openMSX's reset ends with wave number 0 on every slot, "
           "which loads wave 0's header into them (YMF278.cc reset -> writeRegDirect case 0)",
    'D12': "a wave number written again within 64 clk of the previous one on the same slot keeps "
           "the previous number's header in fields 5-9 (engine2 fetches the number it saw first and "
           "clears the request when it stores; characterized only at the op script's 20-clk spacing) "
           "(ymf278_pcm_engine2.sv:1277-1278, 1590-1591)",
}
# Flags an engine does not have: run_cpuvis.sh drops them from the default list for it.
ENGINE_DROPS = {'ymf278_pcm_engine3': {'D10', 'D11', 'D12'}}

# Of those, the ones where openMSX follows a "Verified on real YMF278" comment (or, for
# D7, plain read-time semantics) are RTL defects the gate tolerates until they are fixed,
# not accepted behaviour.  The rest are RTL choices: D1/D2/D6 have no hardware basis either
# way, D8 is structural (S-BOUND), D9 is a software fix (GoFigure).
DEFECTS = {
    'D3': "YMF278.cc:744-747 (write) and 784-786 (read), 'Verified on real YMF278'",
    'D4': "YMF278.cc:717-736, 'Verified on real YMF278'",
    'D5': "YMF262.cc:1101-1110, 'Verified on real YMF278'",
    'D7': "YMF278.cc:780-782 (read-time memory; no hardware note either way)",
    'D12': "YMF278.cc:594-615 (the header of the number written, synchronously)",
}

TOL = 4


class Model:
    def __init__(self, mem, dev, clk_hz, cpf):
        self.dev = dev
        self.clk_hz = clk_hz
        self.cpf = cpf
        self.mem = bytearray(mem) + bytearray(max(0, 0x400000 - len(mem)))
        self.fmreg = [0] * 512                 # YMF262 reg[] (zero at construction)
        self.already_new2 = False
        self.status2 = 0
        self.rtl_new2_prev = False
        self.power_up()

    # ── time ─────────────────────────────────────────────────────────────
    def delay(self, master):
        if 'D1' in self.dev:
            return master
        return math.ceil(master * self.clk_hz / MASTER_HZ)

    # ── YMF278 / YMF278B state (YMF278B.cc:51-67, YMF278.cc:829-848) ─────
    def power_up(self):
        self.regs = [0] * 256
        self.reset(0, power=True)

    def reset(self, t, power=False):
        # YMF262::reset (YMF262.cc:1398-): alreadySignaledNEW2 = false, reg 105h kept
        self.already_new2 = False
        self.status2 = 0
        if 'D9' in self.dev or power:
            self.fmreg[0x105] = 0
        self.rtl_new2_prev = self.new2()
        self.regs = [0] * 256
        if 'D10' in self.dev:
            for n in range(24):
                self.regs[0x68 + n] = 0x20
        if 'D11' not in self.dev:
            # YMF278::reset writes 0 to F7h..08h in that order: each slot's wave number
            # (field 0) comes after its fields 5-9, so wave 0's header backfills them
            for n in range(24):
                for i in range(7, 12):
                    self.regs[8 + n + (i - 2) * 24] = self.mem[i]
        self.regs[0xF8] = 0x00 if 'D6' in self.dev else 0x1B
        self.mem_adr = 0
        self.wave_t = {}            # slot -> (time, header) of its last wave-number write (D12)
        self.opl4latch = 0
        self.opl3latch = 0
        self.busy = (t, t)          # BUSY until (lo, hi): exact when lo == hi
        self.load = t
        self.prefetch = self.mem[0]

    def new2(self):
        return bool(self.fmreg[0x105] & 0x02)

    def set_busy(self, t, master, engine=False):
        d = RTL_MEM_WRITE_DELAY if master == 'memw' else self.delay(master)
        lo = t + d
        hi = t + max(d, self.cpf + 64) if (engine and 'D8' in self.dev) else lo
        self.busy = (lo, hi)

    def mem_access_on(self):
        return 'D3' in self.dev or (self.regs[2] & 1)

    # ── YMF262 (YMF262.cc:1036-1110, 1474-1484) ──────────────────────────
    def fm_write(self, r, v):
        opl3_mode = self.fmreg[0x105] & 1
        if not opl3_mode and r != 0x105:
            r &= ~0x100
        self.fmreg[r] = v
        if r == 0x105:
            if 'D5' in self.dev:
                n2 = bool(v & 2)
                if n2 and not self.rtl_new2_prev:
                    self.status2 = 0x02
                self.rtl_new2_prev = n2
            elif (v & 0x02) and not self.already_new2:
                self.status2 = 0x02
                self.already_new2 = True

    # ── YMF278::writeRegDirect (YMF278.cc:587-757) ───────────────────────
    def wave_write(self, reg, data, t):
        if 0x08 <= reg <= 0xF7:
            n = (reg - 8) % 24
            f = (reg - 8) // 24
            if f == 0:
                wave = ((self.regs[0x08 + 24 + n] & 1) << 8) | data
                tbl = (self.regs[2] >> 2) & 7
                base = wave * 12 if (wave < 384 or not tbl) else tbl * 0x80000 + (wave - 384) * 12
                buf = [self.mem[(base + i) & 0x3FFFFF] for i in range(12)]
                last = self.wave_t.get(n)
                if 'D12' in self.dev and last is not None and t - last[0] < 64:
                    buf = last[1]
                self.wave_t[n] = (t, buf)
                self.regs[reg] = data
                for i in range(7, 12):               # YMF278.cc:610-615 backfill
                    self.regs[8 + n + (i - 2) * 24] = buf[i]
                return
            self.regs[reg] = data
            return
        if reg == 0x03:
            data &= 0x3F                             # YMF278.cc:726
            if 'D4' in self.dev:
                self.mem_adr = (data << 16) | (self.mem_adr & 0xFFFF)
        elif reg == 0x04:
            if 'D4' in self.dev:
                self.mem_adr = (self.mem_adr & 0xFF00FF) | (data << 8)
        elif reg == 0x05:
            self.mem_adr = (self.regs[3] << 16) | (self.regs[4] << 8) | data
            self.prefetch = self.mem[self.mem_adr & 0x3FFFFF]
        elif reg == 0x06:
            if self.mem_access_on():
                self.mem[self.mem_adr & 0x3FFFFF] = data
                self.mem_adr += 1
        self.regs[reg] = data

    # ── YMF278::readReg / peekReg (YMF278.cc:759-791) ────────────────────
    def wave_read(self, reg):
        if reg == 2:
            return (self.regs[2] & 0x1F) | 0x20
        if reg == 6:
            if 'D7' in self.dev:
                v = self.prefetch
                self.mem_adr += 1
                self.prefetch = self.mem[self.mem_adr & 0x3FFFFF]
                return v
            if self.mem_access_on():
                v = self.mem[self.mem_adr & 0x3FFFFF]
                self.mem_adr += 1
                return v
            return 0xFF
        return self.regs[reg]

    # ── YMF278B::writeIO / readIO (YMF278B.cc:69-199) ────────────────────
    def io_write(self, port, v, t):
        """returns 'hold' when the RTL holds the CPU until BUSY clears (D2)"""
        hold = False
        if (port & 0xFF) < 0xC0:
            if self.new2():
                if not (port & 1):
                    self.set_busy(t, WAVE_REG_SELECT_DELAY)
                    self.opl4latch = v
                else:
                    if 0x08 <= self.opl4latch <= 0x1F:
                        self.load = t + self.delay(LOAD_DELAY)
                    if 3 <= self.opl4latch <= 6:
                        if 'D2' in self.dev:
                            self.set_busy(t, 'memw', engine=self.opl4latch in (5, 6))
                            hold = True
                        else:
                            self.set_busy(t, MEM_WRITE_DELAY)
                    else:
                        self.set_busy(t, WAVE_REG_WRITE_DELAY)
                    self.wave_write(self.opl4latch, v, t)
        else:
            p = port & 3
            if p == 0:
                self.opl3latch = v
                self.set_busy(t, FM_REG_SELECT_DELAY)
            elif p == 2:
                self.opl3latch = v | 0x100
                self.set_busy(t, FM_REG_SELECT_DELAY)
            else:
                self.set_busy(t, FM_REG_WRITE_DELAY)
                self.fm_write(self.opl3latch, v)
        return hold

    def io_read(self, port, t):
        if (port & 0xFF) < 0xC0:
            if not (port & 1):
                return 0xFF
            if 3 <= self.opl4latch <= 6:
                self.set_busy(t, MEM_READ_DELAY, engine=(self.opl4latch == 6))
            return self.wave_read(self.opl4latch)
        p = port & 3
        if p in (1, 3):
            return self.fmreg[self.opl3latch]
        raise ValueError("status reads go through status()")

    def status_bits(self, t):
        """{bit: True/False/None}; None = inside a tolerance window"""
        lo, hi = self.busy
        if t < lo - TOL:
            b0 = True
        elif t > hi + TOL:
            b0 = False
        else:
            b0 = None
        if self.status2:
            b1 = True
        elif abs(t - self.load) <= TOL:
            b1 = None
        else:
            b1 = t < self.load
        return b0, b1

    def status_read(self, t):
        b0, b1 = self.status_bits(t)
        sig = self.status2
        self.status2 = 0                              # YMF262::readStatus
        return b0, b1, sig


def parse(log):
    ops, st, hdr = [], [], {}
    for ln in open(log):
        a = ln.split()
        if not a:
            continue
        if a[0] == 'op':
            ops.append(dict(n=int(a[1]), k=a[2], port=int(a[3], 16), din=int(a[4], 16),
                            t=int(a[5]), tack=int(a[6]), dout=int(a[7], 16)))
        elif a[0] == 'st':
            st.append((int(a[1]), int(a[2])))
        elif a[0] in ('clk_hz', 'cpf', 'end'):
            hdr[a[0]] = int(a[1])
    return hdr, ops, st


def bit_at(st, t, bit):
    v = 0
    for c, s in st:
        if c > t:
            break
        v = s
    return (v >> bit) & 1


def fall_after(st, t0, t1, bit):
    """first cycle in (t0, t1] at which the bit is 0, None if it stays 1"""
    if not bit_at(st, t0, bit):
        return t0
    for c, s in st:
        if c <= t0:
            continue
        if c > t1:
            break
        if not (s >> bit) & 1:
            return c
    return None


def run(hdr, ops, st, mem, dev):
    m = Model(mem, dev, hdr['clk_hz'], hdr['cpf'])
    obs = []                     # (key, expected, actual, ok)
    tend = hdr.get('end', ops[-1]['t'] + 10000)
    for i, o in enumerate(ops):
        t, k = o['t'], o['k']
        tnext = ops[i + 1]['t'] if i + 1 < len(ops) else tend
        key = f"op{o['n']} {k} {o['port']:02x}"
        if k == 'X':
            m.reset(o['tack'])
            continue
        if k == 'S':
            b0, b1, sig = m.status_read(t)
            act = o['dout']
            ok = (act & 0xFC) == 0
            ok &= b0 is None or bool(act & 1) == b0
            ok &= b1 is None or bool(act & 2) == b1
            exp = f"{'?' if b0 is None else int(b0)}{'?' if b1 is None else int(b1)}"
            obs.append((key + " status", exp, f"{act & 1}{(act >> 1) & 1}+{act & 0xFC:02x}", ok))
            continue
        if k == 'W':
            hold = m.io_write(o['port'], o['din'], t)
            lat = o['tack'] - t if o['tack'] >= 0 else None
            if hold:
                lo, hi = m.busy
                fall = fall_after(st, t + 2, t + 100000, 0)
                ok = lat is not None and fall is not None and abs(o['tack'] - fall) <= TOL \
                    and lo - TOL <= fall <= hi + TOL
                obs.append((key + " ack", f"hold to BUSY end [{lo - t},{hi - t}]", f"{lat}", ok))
            else:
                obs.append((key + " ack", "<=4", f"{lat}", lat is not None and lat <= TOL))
        elif k == 'R':
            exp = m.io_read(o['port'], t)
            obs.append((key + " data", f"{exp:02x}", f"{o['dout']:02x}", exp == o['dout']))
            lat = o['tack'] - t if o['tack'] >= 0 else None
            obs.append((key + " ack", "<=4", f"{lat}", lat is not None and lat <= TOL))
        # BUSY / bit-1 fall after this access, inside (t, tnext]
        lo, hi = m.busy
        lo, hi = max(lo, t), max(hi, t)
        fall = fall_after(st, t + 2, tnext, 0)
        if hi + TOL < tnext:
            ok = fall is not None and lo - TOL <= fall <= hi + TOL
        elif lo - TOL > tnext:
            ok = fall is None
        else:
            ok = None           # the next access starts inside the window
        if ok is None:
            # The fall itself cannot be seen, but BUSY must not drop before the window opens
            # (back-to-back accesses, e.g. R800 OTIR: a BUSY that never rises lives here)
            early = min(lo - TOL, tnext)
            if early > t + 2:
                f2 = fall_after(st, t + 2, early, 0)
                obs.append((key + " busy-held", f"no fall before {early - t}",
                            f"{None if f2 is None else f2 - t}", f2 is None))
            else:
                obs.append((key + " busy", f"[{lo - t},{hi - t}] (unjudged)", "-", True))
        else:
            obs.append((key + " busy", f"[{lo - t},{hi - t}]", f"{None if fall is None else fall - t}", ok))
        if not m.status2:
            ld = max(m.load, t)
            fall = fall_after(st, t + 2, tnext, 1)
            if ld + TOL < tnext:
                ok = fall is not None and abs(fall - ld) <= TOL
                obs.append((key + " ld", f"{ld - t}", f"{None if fall is None else fall - t}", ok))
            elif fall is not None:
                obs.append((key + " ld", f"{ld - t}", f"{fall - t}", abs(fall - ld) <= TOL))
            elif ld - TOL > t + 2:
                f2 = fall_after(st, t + 2, min(ld - TOL, tnext), 1)
                obs.append((key + " ld-held", f"no fall before {min(ld - TOL, tnext) - t}",
                            f"{None if f2 is None else f2 - t}", f2 is None))
            else:
                obs.append((key + " ld", f"{ld - t} (unjudged)", "-", True))
    return obs


def main():
    args = sys.argv[1:]
    quiet = '--quiet' in args
    args = [a for a in args if a != '--quiet']
    dev = set(DEVIATIONS) - ENGINE_DROPS.get(os.environ.get('CPUVIS_ENGINE', ''), set())
    if '--dev' in args:
        i = args.index('--dev')
        dev = set() if args[i + 1] == 'none' else set(args[i + 1].split(','))
        del args[i:i + 2]
    log, memf = args
    hdr, ops, st = parse(log)
    mem = open(memf, 'rb').read()
    if not ops:
        print("CPUVIS FAIL: no ops in log"); sys.exit(1)
    obs = run(hdr, ops, st, mem, dev)
    bad = [o for o in obs if not o[3]]
    unj = sum(1 for o in obs if '(unjudged)' in o[1])
    # the judged check keys, next to the log: the harness compares them with a committed
    # baseline, so a change cannot keep the count while dropping or relabelling checks
    with open(os.path.join(os.path.dirname(os.path.abspath(log)), 'checks.txt'), 'w') as f:
        f.writelines(o[0] + '\n' for o in obs if '(unjudged)' not in o[1])
    acc = sorted(dev - set(DEFECTS)); dfx = sorted(dev & set(DEFECTS))
    print(f"cpuvis: {len(ops)} accesses, {len(obs) - unj} checks, {len(bad)} failed, "
          f"{unj} unjudged (model: openMSX + deviations {','.join(acc) or 'none'}"
          f" + tolerated RTL defects {','.join(dfx) or 'none'})")
    for key, e, a, ok in bad[:25]:
        print(f"  BAD {key}: expected {e} got {a}")
    # coverage of each deviation: does dropping it change what this script observes?
    uncovered = []
    for d in sorted(dev):
        alt = run(hdr, ops, st, mem, dev - {d})
        n = sum(1 for x, y in zip(obs, alt) if x[1] != y[1] or x[3] != y[3])
        if not quiet:
            tag = f" [RTL DEFECT vs {DEFECTS[d]}]" if d in DEFECTS else ""
            print(f"  {d}: {n} checks depend on it -- {DEVIATIONS[d]}{tag}")
        if n == 0:
            uncovered.append(d)
    if uncovered:
        print(f"  deviations not exercised by the op script: {' '.join(uncovered)}")
    if not quiet:
        pure = run(hdr, ops, st, mem, set())
        pj = [o for o in pure if '(unjudged)' not in o[1]]
        n = sum(1 for o in pj if not o[3])
        print(f"  vs pure openMSX (no deviations): {n} of {len(pj)} judged checks differ")
    ok = not bad and not uncovered
    print("CPUVIS " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
