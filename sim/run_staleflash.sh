#!/usr/bin/env bash
#  The end-of-upload restore DMA and a stale flash16x_base: after a no-reset swap away
#  from an ASCII16X/Yamanooto cart, load_sram fires flash_dirtysave.s LOAD with the
#  departed cart's address, over the ROM that was just staged.  See sim/tb_staleflash.sv.
#  The latch and reset chain are extracted from the RTL by sim/mk_uphold_dut.py.
#  FIX=1 models the candidate repair (see the +fix comment in the bench).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/staleflash_sim}; mkdir -p "$OUT"
python3 sim/mk_uphold_dut.py > "$OUT/uphold_dut.sv" || exit 1
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
   -Wno-ENUMVALUE -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD -Wno-ASCRANGE -Wno-UNDRIVEN \
   -Wno-PINMISSING -Wno-CASEINCOMPLETE \
   --top-module tb_staleflash -o tbsf -Mdir "$OUT/v" \
   rtl/package.sv "$OUT/uphold_dut.sv" rtl/flash_dirtysave.sv sim/tb_staleflash.sv \
   > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; grep -E '%Error' "$OUT/build.log" | head -10; exit 2; }
"$OUT/v/tbsf" ${FIX:+ +fix} | grep -vE '^- '
