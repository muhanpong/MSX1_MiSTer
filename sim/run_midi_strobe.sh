#!/usr/bin/env bash
#  dev_midi under W-clock CPU strobes at random phase.  See sim/tb_midi_strobe.sv.
#      sim/run_midi_strobe.sh [seed ...]      (default: seeds 1 2 3)
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/midi_strobe_tb}
SRC=${MIDI_SRC:-rtl/peripheral/slots/midi.sv}
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   --top-module tb_midi_strobe -o tbmidistrobe -Mdir "$OUT" \
   "$SRC" sim/tb_midi_strobe.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
rc=0
for seed in ${@:-1 2 3}; do
   log="$OUT/seed$seed.log"
   "$OUT/tbmidistrobe" +seed="$seed" > "$log" 2>&1 || true
   grep -E 'seed=|PASS|FAIL|INVALID|NOEXPOSURE|RESULT|B W=' "$log"
   #  no RESULT line = the run did not finish, which is not a pass
   grep -q '^RESULT PASS' "$log" || rc=1
done
[ $rc -eq 0 ] && echo "ALL SEEDS PASS" || echo "NOT ALL SEEDS PASS"
exit $rc
