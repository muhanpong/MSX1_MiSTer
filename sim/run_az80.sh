#!/usr/bin/env bash
# A-Z80 gate: clock generator, wrapper bring-up, and the clk21m domain crossing.
# usage: sim/run_az80.sh    env: OUT=<dir> (default /tmp/az80_sim)
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/az80_sim}; mkdir -p "$OUT"
INC="+incdir+rtl/cpu/az80/toplevel +incdir+rtl/cpu/az80/control"
W="-Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-PINMISSING
   -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT"
CORE="rtl/cpu/az80/*/*.v rtl/cpu/az80/az80_wrapper.sv rtl/cpu/az80/az80_bridge.sv rtl/peripheral/az80_clkgen.sv"
rc=0
run() {  # $1 = top, $2... = extra sources
   local tb=$1; shift
   verilator --binary --timing $W --top-module $tb -Mdir "$OUT/$tb" -o $tb $INC $@ \
      > "$OUT/$tb.build" 2>&1 || { echo "$tb: COMPILE FAILED (see $OUT/$tb.build)"; rc=1; return; }
   "$OUT/$tb/$tb" > "$OUT/$tb.log" 2>&1
   grep -vE '^- ' "$OUT/$tb.log" | tail -8
   grep -q ': PASS' "$OUT/$tb.log" && echo "  -> $tb PASS" || { echo "  -> $tb FAIL"; rc=1; }
   echo
}
run tb_az80_clkgen   rtl/peripheral/az80_clkgen.sv sim/tb_az80_clkgen.sv
run tb_az80_bringup  $CORE rtl/cpu/az80/sim/tb_az80_bringup.sv
run tb_az80_domain   $CORE rtl/cpu/az80/sim/tb_az80_domain.sv
run tb_az80_m1wait   $CORE rtl/cpu/az80/sim/tb_az80_m1wait.sv
[ $rc -eq 0 ] && echo "run_az80: ALL PASS" || echo "run_az80: FAILURES PRESENT"
exit $rc
