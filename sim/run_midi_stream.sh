#!/usr/bin/env bash
#  Push a byte stream out of the MSX-MIDI UART and read it back off the wire.
#
#      sim/run_midi_stream.sh <bytes-in> [decoded-out]
#
#  <bytes-in> is what software writes to E8h; [decoded-out] is what the decoder
#  recovered from midi_tx, so it can be diffed against the same stream captured
#  from openMSX.  See sim/tb_midi_stream.sv.
set -eu
cd "$(dirname "$0")/.."
IN=${1:?usage: run_midi_stream.sh <bytes-in> [decoded-out]}
DEC=${2:-/tmp/midi_stream_out.bin}
OUT=${OUT:-/tmp/midi_stream_tb}
SRC=${MIDI_SRC:-rtl/peripheral/slots/midi.sv}
mkdir -p "$OUT"
#  Reuse the binary when it is newer than both sources: a sweep over many
#  streams should build once, not once per stream.
if [ -x "$OUT/tbmidistream" ] \
   && [ "$OUT/tbmidistream" -nt "$SRC" ] \
   && [ "$OUT/tbmidistream" -nt sim/tb_midi_stream.sv ]; then
   "$OUT/tbmidistream" +bytes="$IN" +out="$DEC" | grep -E 'PASS|FAIL|RESULT|stream:|wrote'
   exit 0
fi
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   --top-module tb_midi_stream -o tbmidistream -Mdir "$OUT" \
   "$SRC" sim/tb_midi_stream.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
"$OUT/tbmidistream" +bytes="$IN" +out="$DEC" | grep -E 'PASS|FAIL|RESULT|stream:|wrote'
