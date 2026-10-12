#!/usr/bin/env python3
"""Adapt rtl/peripheral/sdram_tdm.sv for Verilator the way mkshim.py adapts
sdram.sv: split the inout SDRAM_DQ into out/oe/in, and model an M10K
read-during-write collision in the ch2 cache adversarially (valid line, matching
tag, wrong data).  Nothing else changes."""
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
def rep(a, b):
    global s
    if s.count(a) != 1:
        sys.exit(f"mkshim_tdm: expected one '{a.strip()[:60]}', found {s.count(a)}")
    s = s.replace(a, b)
rep("    inout      [15:0] SDRAM_DQ,",
    "    output     [15:0] SDRAM_DQ_o,\n    output            SDRAM_DQ_oe,\n    input      [15:0] SDRAM_DQ_i,")
rep("assign SDRAM_DQ = dq_oe_o ? dq_o_r : 16'bz;",
    "assign SDRAM_DQ_o = dq_o_r;\nassign SDRAM_DQ_oe = dq_oe_o;")
rep("always @(posedge clk) dq_p <= SDRAM_DQ;", "always @(posedge clk) dq_p <= SDRAM_DQ_i;")
rep("    c_rdata   <= cmem[ch2_caddr[CW:1]];",
    "    c_rdata   <= (c_we && c_waddr == ch2_caddr[CW:1])\n"
    "               ? {1'b1, ch2_caddr[26:CW+1], ~cmem[ch2_caddr[CW:1]][15:0]}\n"
    "               : cmem[ch2_caddr[CW:1]];")
import re
left = re.findall(r"SDRAM_DQ(?![_a-zA-Z0-9])", s)
if left:
    sys.exit(f"mkshim_tdm: {len(left)} unconverted SDRAM_DQ reference(s)")
open(dst, "w").write(s)
print("mkshim_tdm: ok", file=sys.stderr)
