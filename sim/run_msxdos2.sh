#!/usr/bin/env bash
# MSX-DOS 2 ROM mapper vs openMSX RomMSXDOS2.cc.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/msxdos2_sim}; mkdir -p "$OUT"
iverilog -g2012 -o "$OUT/tb" sim/tb_msxdos2.sv rtl/peripheral/slots/msxdos2.sv \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; cat "$OUT/build.log"; exit 2; }
"$OUT/tb"
