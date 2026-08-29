#!/usr/bin/env bash
# Panasonic switched I/O device (manufacturer ID 8), ports 40H/41H -- the 5.37MHz turbo.
# NEGCTL=1 holds cs low ("this machine has no Matsushita device"); the presence
# checks MUST then fail.  See the header of sim/tb_matsushita.sv.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/matsushita_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME $DEF \
   --top-module tb_matsushita -o tbmatsu -Mdir "$OUT/v" \
   sim/tb_matsushita.sv rtl/peripheral/slots/matsushita.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -25 "$OUT/build.log"; exit 2; }
"$OUT/v/tbmatsu" 2>&1 | grep -vE '^- '
exit ${PIPESTATUS[0]}
