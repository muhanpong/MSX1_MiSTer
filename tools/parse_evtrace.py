#!/usr/bin/env python3
"""Render the evt_trace ring (rtl/evt_trace.sv) oldest -> newest, one CPU event per line.

usage: parse_evtrace.py [/tmp/evtrace_dump.txt]
Time is in ticks of 16 clk21m (0.745 us); dt is the gap to the previous event.
"""
import sys
path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/evtrace_dump.txt"
raw = [int(l.strip(), 16) for l in open(path) if l.strip()]
raw = raw[::-1]          # read_content_from_memory returns the HIGHEST address first
MARK = (1 << 80) - 1
mk = [i for i, w in enumerate(raw) if w == MARK]
if mk:
    m = mk[0]; words = raw[m+1:] + raw[:m]
    print(f"# marker at {m}: ring unrolled, {len(words)} events oldest->newest (trigger = 10 nested acceptances, +384 after)")
else:
    words = raw; print("# no marker: ring not stopped (trigger never fired) -- raw order, newest is somewhere inside")
KIND = {1: "INTA", 2: "IOR ", 3: "IOW ", 4: "SWAP", 5: "IFF ", 6: "R38 ", 7: "RST ", 8: "BR  "}
prev_t = None
print("   n  t(ms)      dt(us)  kind port data  PC   SP   cpu iff vdp ms")
for n, w in enumerate(words):
    if w == 0: continue
    pc = w & 0xFFFF; sp = (w >> 16) & 0xFFFF; data = (w >> 32) & 0xFF; port = (w >> 40) & 0xFF
    kind = (w >> 48) & 0xF; nz = (w >> 52) & 1; iff = (w >> 53) & 1; vdp = (w >> 54) & 1; ms = (w >> 55) & 1
    t = (w >> 56) & 0xFFFFFF
    dt = "" if prev_t is None else f"{((t - prev_t) & 0xFFFFFF) * 0.745:10.1f}"
    prev_t = t
    k = KIND.get(kind, f"?{kind:X}  ")
    p = f"{port:02X}" if kind in (2, 3) else "--"
    if kind in (6, 8): p = "  "
    note = ""
    if kind == 1: note = "  <- src:" + ("" if vdp else " VDP") + ("" if ms else " OPL")
    if kind == 4: note = "  -> " + ("R800" if data & 1 else "Z80")
    if kind == 6: note = f"  <- runaway fetching at {(port << 8) | data:04X}"
    if kind == 8: note = f"  -> fetch {(port << 8) | data:04X}"
    print(f"{n:4d} {t*0.000745:9.3f} {dt:>10}  {k} {p}   {data:02X}  {pc:04X} {sp:04X}  {'nz ' if nz else 't80'}  {iff}   {'-' if vdp else 'A'}   {'-' if ms else 'A'}{note}")
