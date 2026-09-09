#!/usr/bin/env bash
# NEO-8/NEO-16 mapper + mapper_detect offset-16 signatures. Verilator (the
# package's unpacked structs are beyond iverilog).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/neo_sim}; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-ENUMVALUE \
   --top-module tb_neo -o tbneo -Mdir "$OUT/v" \
   rtl/package.sv sim/tb_neo.sv rtl/peripheral/slots/neo.sv rtl/peripheral/slots/mapper_detect.sv \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; tail -25 "$OUT/build.log"; exit 2; }
"$OUT/v/tbneo" 2>&1 | grep -vE '^- '
exit ${PIPESTATUS[0]}
