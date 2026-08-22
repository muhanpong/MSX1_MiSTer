#!/usr/bin/env bash
# Yamanooto JEDEC flash programming gates (cart_yamanooto, real RTL instance).
#
# usage: sim/run_yamanooto_flash.sh            # shipped config
#        NEGCTL=1 sim/run_yamanooto_flash.sh   # negative control (MUST fail)
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/yamanooto_flash_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal $DEF --top-module tb_yamanooto_flash \
   -o tb_yamanooto_flash -Mdir "$OUT/tb" \
   rtl/package.sv rtl/peripheral/slots/yamanooto.sv sim/tb_yamanooto_flash.sv \
   > "$OUT/build.log" 2>&1 \
   || { echo "tb_yamanooto_flash: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_yamanooto_flash" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
