#!/usr/bin/env python3
"""Render /tmp/aztrace_dump.txt (az80_trace ring) as one line per az80_clk edge."""
import sys
path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/aztrace_dump.txt"
words = [int(l.strip(), 16) for l in open(path) if l.strip()]
def b(w, i): return (w >> i) & 1
print("idx  edg  A     DI DO  MREQ IORQ RD WR M1 RFSH | WAIT sdce rnw pace m1w hit tog rst t80")
last = None
for i, w in enumerate(words):
    row = (w & 0xFFFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF,
           b(w,32), b(w,33), b(w,34), b(w,35), b(w,36), b(w,37), b(w,38), b(w,39),
           b(w,40), b(w,41), b(w,42), b(w,43), b(w,44), b(w,45), b(w,46), b(w,47))
    a, di, do, mreq, iorq, rd, wr, m1, rfsh, wait, edge, sdce, rnw, pace, m1w, hit, tog, rst, t80 = row
    print(f"{i:4d}  {'R' if edge else 'F'}  {a:04X}  {di:02X} {do:02X}  "
          f"{'m' if not mreq else '.'}    {'i' if not iorq else '.'}    {'r' if not rd else '.'}  "
          f"{'w' if not wr else '.'}  {'1' if not m1 else '.'}  {'f' if not rfsh else '.'}    | "
          f"{'W' if not wait else '.'}    {sdce}    {rnw}   {'P' if not pace else '.'}    "
          f"{'M' if not m1w else '.'}   {hit}   {tog}   {rst}   {t80}")
