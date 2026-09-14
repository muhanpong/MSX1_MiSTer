#!/usr/bin/env python3
"""Render the az80_trace ring (pre-trigger capture) oldest -> newest, one bus cycle per line."""
import sys
path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/aztrace_dump.txt"
raw = [int(l.strip(), 16) for l in open(path) if l.strip()]
MARK = 0xFFFF0000FFFF
mk = [i for i, w in enumerate(raw) if w == MARK]
if mk:
    m = mk[0]; words = raw[m+1:] + raw[:m]; print(f"# marker at {m}: ring unrolled, {len(words)} samples oldest->newest (trigger = M1@0038, +512 after)")
else:
    words = raw; print("# no marker: ring not stopped (trigger never fired) -- raw order")
b = lambda w, i: (w >> i) & 1
rows = []; prev = None
for i, w in enumerate(words):
    a = w & 0xFFFF; di = (w >> 16) & 0xFF; do = (w >> 24) & 0xFF
    mreq, iorq, rd, wr, m1, rf, wait = (b(w, k) for k in (32, 33, 34, 35, 36, 37, 38))
    edge, sdce, rnw, pace, m1w, hit, tog, rst, t80 = (b(w, k) for k in (39, 40, 41, 42, 43, 44, 45, 46, 47))
    if rst:
        rows.append([i, "RST", a, di, do, 0, 0, sdce, pace, hit]); prev = None; continue
    kind = ("IOR" if not rd else "IOW" if not wr else None) if not iorq else \
           (("M1 " if not m1 else "RD ") if not rd else "WR " if not wr else ("RFS" if not rf else None)) if not mreq else None
    if kind is None: prev = None; continue
    key = (kind, a)
    if key != prev: rows.append([i, kind, a, di, do, 1, int(not wait), sdce, int(not pace), hit])
    else:
        r = rows[-1]; r[5] += 1; r[6] += int(not wait); r[3] = di; r[4] = do
    prev = key
print("smp  kind addr  DI DO  edges waits sdce pace hit")
for r in rows:
    if r[1] == "RST": print(f"{r[0]:4d}  ---- RESET ----"); continue
    print(f"{r[0]:4d}  {r[1]} {r[2]:04X}  {r[3]:02X} {r[4]:02X}   {r[5]:2d}    {r[6]:2d}    {r[7]}    {r[8]}   {r[9]}")
