#!/usr/bin/env bash
# flash.sv erase sector geometry (uniform-sector vs bottom-boot).
#
# usage: sim/run_flash_erase.sh            # shipped config
#        NEGCTL=1 sim/run_flash_erase.sh   # negative control (MUST fail)
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/flash_erase_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
SRC="rtl/peripheral/slots/flash.sv"
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_flash_erase \
   -o tb_flash_erase -Mdir "$OUT/tb" "$SRC" sim/tb_flash_erase.sv > "$OUT/build.log" 2>&1 \
   || { echo "tb_flash_erase: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_flash_erase" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
