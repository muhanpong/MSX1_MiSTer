#!/usr/bin/env bash
# cart_yamanooto + flash.sv seam: the mapper must not walk the SHARED flash
# command FSM into CFI / autoselect / erase while WREN is clear.
#
# usage: sim/run_flash_seam.sh            # shipped config
#        NEGCTL=1 sim/run_flash_seam.sh   # strip the WREN gate; MUST fire
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/flash_seam_sim}; mkdir -p "$OUT"
DEF=""; YAM="rtl/peripheral/slots/yamanooto.sv"
if [ "${NEGCTL:-0}" = "1" ]; then
   DEF="+define+NEGCTL"; mkdir -p "$OUT/neg"
   sed 's/^\( *\)& (cpu_rd | flash_wr_en);/\1;/' "$YAM" > "$OUT/neg/yamanooto.sv"
   if ! grep -qE '^\s*;\s*$' "$OUT/neg/yamanooto.sv"; then
      echo "tb_flash_seam: NEGCTL could not strip the WREN gate — check the pattern"; exit 1
   fi
   YAM="$OUT/neg/yamanooto.sv"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_flash_seam \
   -o tb_flash_seam -Mdir "$OUT/tb" \
   rtl/package.sv "$YAM" rtl/peripheral/slots/flash.sv sim/tb_flash_seam.sv \
   > "$OUT/build.log" 2>&1 \
   || { echo "tb_flash_seam: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_flash_seam" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
