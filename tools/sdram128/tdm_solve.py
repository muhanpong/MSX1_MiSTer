#!/usr/bin/env python3
"""Search 12-cycle TDM frames for the SDRAM at 128.86 MHz (CL3, BL2, write burst on).

One VRAM access (V, always bank 3, its rows have A12:A11 = 00) and two general
accesses (G1, G2, any other bank, row bits A12:A11 arbitrary) per frame.  Each
access has an ACT cycle and separate READ and WRITE command cycles (whichever the
request needs).  The frame repeats, so everything is modulo 12, and every one of
the 8 read/write combinations must be legal.

Board fact assumed: DQM == A[12:11] at every cycle (MiSTer SDRAM modules; this
core and X68000 both drive DQM from the address bits).  So a cycle's A12:A11 is
  - the DQM for read data two cycles later (latency 2), which must be 00, and
  - the DQM for write data in the same cycle (latency 0): V = its byte mask,
    G word1 = 11 (G writes one word; the burst's second word is masked).
A general ACT carries arbitrary row bits, so it may not sit in a cycle with any
such requirement.  V's ACT carries 00: fine for reads, not for a V/G write mask.

Bus rules: read data at r+3, r+4.  Write data at w (and w+1 for V).  A WRITE no
earlier than one idle cycle after read data (w >= r+6 for any earlier READ in
flight).  A READ after a WRITE: r >= w+2 (V) / w+1 (G; its word1 is masked).
Commands one per cycle.  tRCD >= 3 cycles (23.3 ns), tRRD >= 2.
"""
import itertools
N = 12
TRCD = 3

def d(a, b):            # cycles from a forward to b, modulo the frame
    return (b - a) % N

def legal(sched, modes):
    # sched: name -> (act, rd, wr); modes: name -> 'R' or 'W'
    cmd = {}
    for n, (a, r, w) in sched.items():
        c = r if modes[n] == 'R' else w
        for t in (a, c):
            if t in cmd: return False
            cmd[t] = n
    req = {}            # cycle -> required A12:A11 ('00', 'M' mask, '11')
    bus = {}            # cycle -> who drives DQ ('chip'/'fpga', name)
    for n, (a, r, w) in sched.items():
        if modes[n] == 'R':
            for t in ((r + 1) % N, (r + 2) % N):
                if req.get(t, '00') != '00': return False
                req[t] = '00'
            for t in ((r + 3) % N, (r + 4) % N):
                if t in bus: return False
                bus[t] = ('chip', n)
        else:
            words = (w % N, (w + 1) % N)
            need = ('M', 'M') if n == 'V' else ('M', '11')
            for t, v in zip(words, need):
                if t in req and req[t] != v: return False
                req[t] = v
            for t in (words if n == 'V' else words[:1]):
                if t in bus: return False
                bus[t] = ('fpga', n)
    # A12:A11 driven by each command must agree with the requirement
    for t, n in cmd.items():
        a, r, w = sched[n]
        if t == a:
            if n == 'V':
                if t in req and req[t] != '00': return False
            elif t in req: return False                 # general row bits
        elif modes[n] == 'W' and t == w:
            if t in req and req[t] != 'M': return False
        # READ command: its A12:A11 are free, carries whatever req[t] is
    # turnaround: an FPGA-driven cycle may not directly follow a chip-driven one
    for t, (who, n) in bus.items():
        if who == 'fpga' and bus.get((t - 1) % N, ('', ''))[0] == 'chip': return False
    # a READ must not cut a write burst it follows (V's word1 is real data)
    for n, (a, r, w) in sched.items():
        if modes[n] != 'W' or n != 'V': continue
        for m, (a2, r2, w2) in sched.items():
            if m != n and modes[m] == 'R' and r2 % N == (w + 1) % N: return False
    return True

def access_options(is_v):
    for a in range(N):
        for r in range(N):
            if d(a, r) < TRCD or d(a, r) > 5: continue
            for w in range(N):
                if d(a, w) < TRCD or d(a, w) > 5: continue
                yield (a, r, w)

results = []
vopts = [o for o in access_options(True) if o[0] == 0]      # V's ACT anchors the frame
gopts = list(access_options(False))
for v in vopts:
    for g1 in gopts:
        if not (d(v[0], g1[0]) >= 2 and d(g1[0], v[0]) >= 2): continue
        for g2 in gopts:
            if g2[0] <= g1[0]: continue
            acts = [v[0], g1[0], g2[0]]
            if any(d(x, y) < 2 for x in acts for y in acts if x != y): continue
            s = {'V': v, 'G1': g1, 'G2': g2}
            if all(legal(s, dict(zip(('V', 'G1', 'G2'), m)))
                   for m in itertools.product('RW', repeat=3)):
                results.append(s)
print(f"frames legal for all 8 R/W combinations: {len(results)}")
for s in results[:20]:
    print("  ", "  ".join(f"{k}: ACT {a:2d} RD {r:2d} WR {w:2d}" for k, (a, r, w) in s.items()))
