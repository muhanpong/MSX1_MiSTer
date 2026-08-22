#!/usr/bin/env bash
# 0x7FFE: a MOFFR (MSTEN) or SPICON (SPIEN) write must not destroy OFFR.
# usage: sim/run_offr.sh            |  NEGCTL=1 sim/run_offr.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/offr_sim}; mkdir -p "$OUT"
DEF=""; SRC="rtl/peripheral/slots/yamanooto.sv"
if [ "${NEGCTL:-0}" = "1" ]; then
   DEF="+define+NEGCTL"; mkdir -p "$OUT/neg"
   sed 's/ & ~|(enar & (MSTEN | SPIEN)))/)/' "$SRC" > "$OUT/neg/yamanooto.sv"
   if grep -q 'MSTEN | SPIEN' "$OUT/neg/yamanooto.sv"; then
      echo "tb_offr: NEGCTL could not strip the guard"; exit 1; fi
   SRC="$OUT/neg/yamanooto.sv"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_offr \
   -o tb_offr -Mdir "$OUT/tb" rtl/package.sv "$SRC" sim/tb_offr.sv > "$OUT/build.log" 2>&1 \
   || { echo "tb_offr: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_offr" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
