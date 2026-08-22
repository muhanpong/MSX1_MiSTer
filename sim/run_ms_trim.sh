#!/usr/bin/env bash
# MoonSound +3 dB output trim verification.
#
#   tb_ms_trim   replicates ymf278b_top's stage-2 expressions verbatim and
#                checks gain, no-wrap, monotonicity and saturation endpoints.
#
# The TB ships with a negative control: NEGCTL=1 forces the multiplier to
# unity and the +3 dB check MUST then fail.  A run where the negative control
# also passes means the TB is not measuring anything.
#
# usage: sim/run_ms_trim.sh          # shipped config
#        NEGCTL=1 sim/run_ms_trim.sh # negative control
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/ms_trim_sim}; mkdir -p "$OUT"
DEF=""
[ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"

verilator --binary --timing -Wno-fatal $DEF --top-module tb_ms_trim \
   -o tb_ms_trim -Mdir "$OUT/tb_ms_trim" sim/tb_ms_trim.sv > "$OUT/build.log" 2>&1 \
   || { echo "tb_ms_trim: COMPILE FAILED (see $OUT/build.log)"; exit 1; }

"$OUT/tb_ms_trim/tb_ms_trim" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}
echo "rc=$rc"
exit $rc
