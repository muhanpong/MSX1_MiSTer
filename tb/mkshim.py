#!/usr/bin/env python3
"""Mechanically adapt rtl/peripheral/sdram.sv for Verilator simulation:
split the bidirectional SDRAM_DQ into out/oe/in, and hoist the `state`
declaration to module scope (Verilator supports neither procedural tristate
on an inout nor the mixed blocking/non-blocking assignment that an
in-block initialised declaration creates). The latch logic under test is
byte-identical to the repo file."""
import sys, re

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
n = s.count("SDRAM_DQ")

s = s.replace("    inout  reg [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus",
              "    output reg [15:0] SDRAM_DQ_o,\n"
              "    output reg        SDRAM_DQ_oe,\n"
              "    input      [15:0] SDRAM_DQ_i,")
s = s.replace("                SDRAM_DQ <= saved_data;",
              "                SDRAM_DQ_o <= saved_data;\n"
              "                SDRAM_DQ_oe <= 1'b1;")
s = s.replace("    SDRAM_DQ <= 16'bz;", "    SDRAM_DQ_oe <= 1'b0;")
s = re.sub(r"<= SDRAM_DQ;", "<= SDRAM_DQ_i;", s)
s = s.replace(", SDRAM_DQ};", ", SDRAM_DQ_i};")          # cache fill concatenation
s = s.replace("from the same SDRAM_DQ word", "from the same SDRAM_DQ_i word")  # comment

# M10K read-during-write to the SAME address has no defined result in hardware,
# but a Verilog array is perfectly well defined (it returns old data), so a
# simulation built straight from the RTL cannot tell whether the read-edge arm
# of c_hazard is load-bearing -- delete it and nothing changes.  Model the
# collision adversarially instead: return a line that is VALID with a MATCHING
# TAG and wrong data, i.e. the worst thing the block could hand back.  With
# this in place, removing that arm turns into a visible false hit.
old = "    c_rdata  <= cmem[ch2_caddr[CW:1]];   // registered index -- see note above"
new = ("    c_rdata  <= (c_we && c_waddr == ch2_caddr[CW:1])\n"
       "              ? {1'b1, ch2_caddr[26:CW+1], ~cmem[ch2_caddr[CW:1]][15:0]}\n"
       "              : cmem[ch2_caddr[CW:1]];")
if old not in s:
    sys.exit("mkshim: read-during-write model could not be inserted")
s = s.replace(old, new, 1)

s = s.replace("    reg  [3:0] state = STATE_STARTUP;\n", "")
s = s.replace("reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;",
              "reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;\n"
              "reg  [3:0] state = STATE_STARTUP;")

left = re.findall(r"SDRAM_DQ(?![_a-zA-Z0-9])", s)
if left:
    sys.exit(f"mkshim: {len(left)} unconverted SDRAM_DQ reference(s)")
print(f"mkshim: converted {n} SDRAM_DQ references", file=sys.stderr)
open(dst, "w").write(s)
