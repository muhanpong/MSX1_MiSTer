#!/usr/bin/env bash
# CPU turbo verification (docs/cpu_turbo_review.md).
#
#   tb_turbo_clock    ce_cpu_p/n divider: ratios, ce_3m58 invariance, mode-switch fuzz
#   tb_turbo_guard    bus guard: no hang (incl. the interrupt-acknowledge cycle),
#                     stock 12/6 clk21m windows preserved, every window contains a
#                     ce_3m58_p, SDRAM ch2 deadline met.  Carries its own negative
#                     control: with the guard bypassed, turbo MUST measurably drop
#                     ce_3m58_p windows and break the deadline.
#   tb_turbo_slowdev  write loss for SCC/OPLL (level capture) and FDC (edge capture)
#   tb_fdc_edge       wd1793 edge front end: proves a pacer is NOT enough and that
#                     clocking it from ce_cpu_p is
#
# Every TB now returns a real exit code.  This script gates on that -- an earlier
# version reported the last printed line instead, and that line was a hardcoded
# string, so the suite could not fail.
#
# usage: sim/run_turbo.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/turbo_sim}; mkdir -p "$OUT"
rc=0
for tb in tb_turbo_clock tb_turbo_guard tb_turbo_slowdev tb_fdc_edge; do
   verilator --binary --timing -Wno-fatal --top-module $tb -o $tb \
      -Mdir "$OUT/$tb" sim/$tb.sv rtl/peripheral/clock.sv > "$OUT/$tb.build" 2>&1 \
      || { echo "$tb: COMPILE FAILED (see $OUT/$tb.build)"; rc=1; continue; }
   "$OUT/$tb/$tb" > "$OUT/$tb.log" 2>&1
   trc=$?
   grep -vE '^- ' "$OUT/$tb.log" | tail -3
   if [ $trc -eq 0 ]; then echo "  -> $tb PASS"; else echo "  -> $tb FAIL (exit $trc)"; rc=1; fi
   echo
done
[ $rc -eq 0 ] && echo "run_turbo: ALL PASS" || echo "run_turbo: FAILURES PRESENT"
exit $rc
