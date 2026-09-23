#!/usr/bin/env bash
#  MSX-MIDI (FS-A1GT built-in): the i8251 + i8254 device, driven the way the GT
#  BIOS drives it.  See sim/tb_midi.sv for where that sequence comes from.
#
#      sim/run_midi.sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/midi_tb}
SRC=${MIDI_SRC:-rtl/peripheral/slots/midi.sv}
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   --top-module tb_midi -o tbmidi -Mdir "$OUT" \
   "$SRC" sim/tb_midi.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
[ -x "$OUT/tbmidi" ] || { echo "RESULT FAIL: no binary"; exit 1; }
"$OUT/tbmidi" | grep -E 'PASS|FAIL|RESULT'
