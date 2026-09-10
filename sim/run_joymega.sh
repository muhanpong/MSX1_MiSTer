#!/usr/bin/env bash
# joymega.sv vs the openMSX JoyMega.cc phase table.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/joymega_sim}; mkdir -p "$OUT"
iverilog -g2012 -o "$OUT/tb" sim/tb_joymega.sv rtl/peripheral/joymega.sv \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; cat "$OUT/build.log"; exit 2; }
"$OUT/tb"
