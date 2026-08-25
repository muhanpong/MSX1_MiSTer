#!/usr/bin/env bash
# OSD sub-slot device / expanded cart slot (see the header of sim/tb_subslot_dev.sv).
# NEGCTL=1 forces subslot_dev to 0 (pre-feature); the sub-slot checks MUST then fail.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/subslot_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME $DEF \
   --top-module tb_subslot_dev -o tbsubslot -Mdir "$OUT/v" \
   rtl/package.sv sim/tb_subslot_dev.sv rtl/peripheral/slots/memory_upload.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -25 "$OUT/build.log"; exit 2; }
"$OUT/v/tbsubslot" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
