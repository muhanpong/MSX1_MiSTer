#!/usr/bin/env bash
#  Three-way comparison of the MSX-MIDI transmit stream.
#
#      tools/midi_stream/run_compare.sh [bytes.bin]
#
#  1. what software writes to E8h            (generated, or the file given)
#  2. what our RTL puts on midi_tx           (sim/run_midi_stream.sh, decoded)
#  3. what openMSX's MSX-MIDI puts out       (midi-out-logger)
#
#  All three must match.  (1) vs (3) says openMSX passes the bytes through, so
#  it is the reference; (2) vs (3) is the comparison that matters.
set -eu
cd "$(dirname "$0")/../.."
WORK=${WORK:-/tmp/midi_compare}
mkdir -p "$WORK"
SENT=${1:-$WORK/sent.bin}
[ -f "$SENT" ] || python3 tools/midi_stream/gen_stream.py "$SENT" --notes 24

echo "--- our RTL ---"
sim/run_midi_stream.sh "$SENT" "$WORK/wire.bin"

echo
echo "--- openMSX ---"
rm -f "$WORK/omsx.bin"
OMSX_STREAM=$SENT OMSX_LOG=$WORK/omsx.bin OMSX_DBG=$WORK/omsx.log \
   openmsx -machine Panasonic_FS-A1GT -script tools/midi_stream/omsx_capture.tcl \
   >/dev/null 2>&1 || true
[ -s "$WORK/omsx.bin" ] || { echo "RESULT FAIL: openMSX wrote nothing"; cat "$WORK/omsx.log"; exit 1; }
cat "$WORK/omsx.log"

echo
echo "--- written vs openMSX ---"
python3 tools/midi_stream/cmp_stream.py "$SENT" "$WORK/omsx.bin" --label-a written --label-b openMSX
echo "--- our wire vs openMSX ---"
python3 tools/midi_stream/cmp_stream.py "$WORK/wire.bin" "$WORK/omsx.bin" --label-a wire --label-b openMSX
