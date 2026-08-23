#!/usr/bin/env bash
# Per-source audio trim: entry 0 must be exactly unity, and the sum must saturate.
# usage: sim/run_audio_trim.sh   |   NEGCTL=1 sim/run_audio_trim.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/audio_trim_sim}; mkdir -p "$OUT"

# The TB reimplements the datapath rather than instantiating msx_slots, so it can
# only show that a COPY is self-consistent.  Check the shipped RTL first -- this is
# the same guard check_opl4_gain_consts.py provides for the OPL4 tables.
if [ "${NEGCTL:-0}" != "1" ]; then
   python3 sim/check_audio_trim_consts.py || exit 1
fi
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_audio_trim \
   -o tb_audio_trim -Mdir "$OUT/tb" sim/tb_audio_trim.sv > "$OUT/build.log" 2>&1 \
   || { echo "tb_audio_trim: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_audio_trim" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
