#!/usr/bin/env bash
# dev_midi (GT MSX-MIDI status stub): a plain IN A,(E9h) reads 05h.  See sim/tb_midi_stub.sv.
set -u; cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/midi_stub_sim}; mkdir -p "$OUT"
iverilog -g2012 -o "$OUT/tb" sim/tb_midi_stub.sv rtl/peripheral/slots/midi.sv > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; cat "$OUT/build.log"; exit 2; }
"$OUT/tb" | tee "$OUT/run.log" | tail -2; grep -q '^PASSED' "$OUT/run.log"
