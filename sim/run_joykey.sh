#!/usr/bin/env bash
# joykey.sv -- extra pad buttons -> MSX key matrix.  No package dependency, so
# iverilog is enough.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/joykey_sim}; mkdir -p "$OUT"
iverilog -g2012 -o "$OUT/tb" sim/tb_joykey.sv rtl/peripheral/joykey.sv \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; cat "$OUT/build.log"; exit 2; }
"$OUT/tb"
