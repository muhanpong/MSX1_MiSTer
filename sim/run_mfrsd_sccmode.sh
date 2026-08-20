#!/usr/bin/env bash
# mapper_mfrsd1 SCC+ mode stability (see the header of sim/tb_mfrsd_sccmode.sv).
# NEGCTL=1 re-derives the mode the pre-fix way; the stability checks MUST then fail.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/mfrsd_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME $DEF \
   --top-module tb_mfrsd_sccmode -o tbmfrsd -Mdir "$OUT/v" \
   sim/tb_mfrsd_sccmode.sv rtl/package.sv rtl/peripheral/slots/mfrsd.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -20 "$OUT/build.log"; exit 2; }
"$OUT/v/tbmfrsd" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
