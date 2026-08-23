#!/usr/bin/env bash
# Predict what tools/yamanooto_savetest.rom will do on hardware, by running its
# exact sequence against the real cart_yamanooto + flash.
#   usage: sim/run_yamanooto_savetest.sh   |   NEGCTL=1 sim/run_yamanooto_savetest.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/yama_savetest_sim}; mkdir -p "$OUT"
DEF=""; SRC="rtl/peripheral/slots/yamanooto.sv"; FL="rtl/peripheral/slots/flash.sv"
# NEGCTL2 re-injects the PRE-FIX sector map: boot_sector forced 0, i.e. the 64KB
# branch that Yamanooto used to take below 0x10000.  T6 must then fail.
if [ "${NEGCTL2:-0}" = "1" ]; then
   mkdir -p "$OUT/neg2"
   sed 's/erase_boot  <= boot_sector & ~(addr > 23.hFFFF);/erase_boot  <= 1'"'"'b0;/' "$FL" > "$OUT/neg2/flash.sv"
   if ! grep -q "erase_boot  <= 1'b0;" "$OUT/neg2/flash.sv"; then
      echo "NEGCTL2 could not force the old 64KB branch"; exit 1; fi
   FL="$OUT/neg2/flash.sv"
fi
if [ "${NEGCTL:-0}" = "1" ]; then
   DEF="+define+NEGCTL"; mkdir -p "$OUT/neg"
   sed 's/ & ~|(enar & (MSTEN | SPIEN)))/)/' "$SRC" > "$OUT/neg/yamanooto.sv"
   if grep -q 'MSTEN | SPIEN' "$OUT/neg/yamanooto.sv"; then
      echo "tb_yamanooto_savetest: NEGCTL could not strip the OFFR guard"; exit 1; fi
   SRC="$OUT/neg/yamanooto.sv"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_yamanooto_savetest \
   -o tb -Mdir "$OUT/tb" rtl/package.sv "$SRC" "$FL" \
   sim/tb_yamanooto_savetest.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED (see $OUT/build.log)"; tail -12 "$OUT/build.log"; exit 1; }
"$OUT/tb/tb" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
