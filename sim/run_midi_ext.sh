#!/usr/bin/env bash
#  dev_midi as a cartridge: the E2h enable register, the two port windows, and
#  the built-in variant left alone.  See sim/tb_midi_ext.sv.
#
#      sim/run_midi_ext.sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/midi_ext_tb}
SRC=${MIDI_SRC:-rtl/peripheral/slots/midi.sv}
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   --top-module tb_midi_ext -o tbmidiext -Mdir "$OUT" \
   "$SRC" sim/tb_midi_ext.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
"$OUT/tbmidiext" | grep -E 'PASS|FAIL|RESULT'
