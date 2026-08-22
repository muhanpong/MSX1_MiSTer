#!/usr/bin/env bash
# Per-source audio trim: entry 0 must be exactly unity, and the sum must saturate.
# usage: sim/run_audio_trim.sh   |   NEGCTL=1 sim/run_audio_trim.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/audio_trim_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_audio_trim \
   -o tb_audio_trim -Mdir "$OUT/tb" sim/tb_audio_trim.sv > "$OUT/build.log" 2>&1 \
   || { echo "tb_audio_trim: COMPILE FAILED (see $OUT/build.log)"; exit 1; }
"$OUT/tb/tb_audio_trim" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
