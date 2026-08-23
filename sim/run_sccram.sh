#!/usr/bin/env bash
# SCC+ RAM mode must actually write, not merely stop banking.
# usage: sim/run_sccram.sh   |   NEGCTL=1 sim/run_sccram.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/sccram_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_sccram \
   -o tb -Mdir "$OUT/tb" rtl/package.sv rtl/peripheral/slots/konami_scc.sv \
   sim/tb_sccram.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -12 "$OUT/build.log"; exit 1; }
"$OUT/tb/tb" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
