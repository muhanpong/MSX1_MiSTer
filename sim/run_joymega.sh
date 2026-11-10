#!/usr/bin/env bash
# joymega.sv vs the openMSX JoyMega.cc phase table (tb_joymega), and the
# 3-/6-button cycle rule of JoyMega.cc write()/checkTime() on random pin-8
# sequences with idle gaps around the timeout (tb_kinds).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/joymega_sim}; mkdir -p "$OUT"
rc=0
for tb in tb_joymega tb_kinds; do
   iverilog -g2012 -s $tb -o "$OUT/$tb" sim/$tb.sv rtl/peripheral/joymega.sv \
      > "$OUT/$tb.log" 2>&1 || { echo "$tb: COMPILE FAILED"; cat "$OUT/$tb.log"; exit 2; }
   echo "== $tb"; "$OUT/$tb" | tee "$OUT/$tb.out" | tail -3
   grep -q '^PASSED' "$OUT/$tb.out" || rc=1
done
exit $rc
