#!/usr/bin/env bash
#  Does upload_hold actually hold the OPL4 through an OSD upload?  flash16x_active is
#  a set-only latch, so one ASCII16X or Yamanooto access defeats the hold for every
#  later upload.  See sim/tb_uphold.sv.  The DUT is extracted from the shipped RTL by
#  sim/mk_uphold_dut.py, so this bench cannot drift from the source silently.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/uphold_sim}; mkdir -p "$OUT"
python3 sim/mk_uphold_dut.py > "$OUT/uphold_dut.sv" || exit 1
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
   -Wno-ENUMVALUE -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD -Wno-ASCRANGE -Wno-UNDRIVEN \
   --top-module tb_uphold -o tbup -Mdir "$OUT/v" \
   rtl/package.sv "$OUT/uphold_dut.sv" sim/tb_uphold.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; grep -E '%Error' "$OUT/build.log" | head -10; exit 2; }
"$OUT/v/tbup"
