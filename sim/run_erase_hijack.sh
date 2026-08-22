#!/usr/bin/env bash
# A CPU write during a flash erase must not retarget the 0xFF fill.
#
# usage: sim/run_erase_hijack.sh            # shipped config
#        NEGCTL=1 sim/run_erase_hijack.sh   # drop the ~erase guard; MUST hijack
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/erase_hijack_sim}; mkdir -p "$OUT"
DEF=""; FL="rtl/peripheral/slots/flash.sv"
if [ "${NEGCTL:-0}" = "1" ]; then
   DEF="+define+NEGCTL"; mkdir -p "$OUT/neg"
   sed 's/& we & ~old_we & ce & ~erase)/\& we \& ~old_we \& ce)/' "$FL" > "$OUT/neg/flash.sv"
   if ! grep -q '& we & ~old_we & ce)' "$OUT/neg/flash.sv"; then
      echo "tb_erase_hijack: NEGCTL could not strip the ~erase guard — check the pattern"; exit 1
   fi
   FL="$OUT/neg/flash.sv"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_erase_hijack \
   -o tb_erase_hijack -Mdir "$OUT/tb" \
   rtl/package.sv rtl/peripheral/slots/yamanooto.sv "$FL" sim/tb_erase_hijack.sv \
   > "$OUT/build.log" 2>&1 \
   || { echo "tb_erase_hijack: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_erase_hijack" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
