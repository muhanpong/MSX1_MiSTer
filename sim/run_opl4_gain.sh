#!/usr/bin/env bash
# OPL4 per-path output gain verification (ymf278b_top).
#
# Ships with a negative control: NEGCTL=1 forces every step to unity and the
# per-step dB check MUST then fail.  If the negative control also passes, the
# TB is not measuring anything and its PASS means nothing.
#
# usage: sim/run_opl4_gain.sh            # shipped config
#        NEGCTL=1 sim/run_opl4_gain.sh   # negative control
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/opl4_gain_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal $DEF --top-module tb_opl4_gain \
   -o tb_opl4_gain -Mdir "$OUT/tb" sim/tb_opl4_gain.sv > "$OUT/build.log" 2>&1 \
   || { echo "tb_opl4_gain: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_opl4_gain" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
