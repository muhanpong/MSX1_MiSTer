#!/usr/bin/env python3
"""Fail when two OSD options claim overlapping status bits.

    tools/confstr/check_status_overlap.py [MSX1.sv rtl/msx_config.sv ...]

Reads every O[..] / T[..] / R[..] token in the CONF_STR string literals of the
given files (default: MSX1.sv and rtl/msx_config.sv -- the sub-slot pages live
in the second).  Two ranges that INTERSECT without being EQUAL are a defect:
that is how the R800 VDP wait dial (O[77:75], 2026-09-20) landed inside slot
A's sub-slot fields (O[75:73] / O[78:76], 2026-08-26) and the two wrote each
other's bits for two weeks (seen on hardware 2026-10-05: Sub-slot 0 read 7).
Equal ranges are allowed -- the same field shown on two pages, or the H/h
alternatives of one row -- but are listed when their labels differ, so a reuse
of the same bits under a new name is still visible.  Exit 1 on a partial
overlap, 0 otherwise.
"""
import re, sys

files = sys.argv[1:] or ["MSX1.sv", "rtl/msx_config.sv"]
tok = re.compile(r'(?:^|[;"])\s*((?:[HhDd][0-9A-F])*)(?:P\d+)?([OTR])\[(\d+)(?::(\d+))?\],([^,;"]*)')
opts = []
for f in files:
    for n, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        code = line.split("//", 1)[0]
        for lit in re.findall(r'"([^"]*)"', code):
            for m in tok.finditer(";" + lit):
                hi = int(m.group(3)); lo = int(m.group(4)) if m.group(4) else hi
                if hi < lo: hi, lo = lo, hi
                opts.append((lo, hi, m.group(2), m.group(5).strip() or "(no label)", f"{f}:{n}"))
            #  legacy form: O/T/R + one or two of 0-9A-V (bits 0..31), e.g. "H0T9,Tape Rewind"
            for m in re.finditer(r'(?:^|;)\s*(?:[HhDd][0-9A-F])*(?:P\d+)?([OTR])([0-9A-V]{1,2}),([^,;"]*)', ";" + lit):
                bits = [int(c, 32) for c in m.group(2)]
                opts.append((min(bits), max(bits), m.group(1), m.group(3).strip() or "(no label)", f"{f}:{n}"))
bad = 0
seen_eq = set()
for i, a in enumerate(opts):
    for b in opts[i + 1:]:
        if a[1] < b[0] or b[1] < a[0]:
            continue
        if (a[0], a[1]) == (b[0], b[1]):
            if a[3] != b[3] and (a[0], a[1], a[3], b[3]) not in seen_eq:
                seen_eq.add((a[0], a[1], a[3], b[3]))
                print(f"same bits [{a[1]}:{a[0]}]: '{a[3]}' ({a[4]}) and '{b[3]}' ({b[4]})")
            continue
        bad += 1
        print(f"OVERLAP: {a[2]}[{a[1]}:{a[0]}] '{a[3]}' ({a[4]})  x  {b[2]}[{b[1]}:{b[0]}] '{b[3]}' ({b[4]})")
print(f"{len(opts)} option tokens read, {bad} partial overlap(s)")
print("STATUS BITS: " + ("PASS" if bad == 0 and len(opts) > 50 else "FAIL"))
sys.exit(1 if bad or len(opts) <= 50 else 0)
