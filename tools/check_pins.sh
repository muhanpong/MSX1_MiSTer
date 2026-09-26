#!/usr/bin/env bash
#  Catch a port that was added to a module and never connected at its instance.
#
#      tools/check_pins.sh            # fail on any NEW unconnected port under rtl/
#      BLESS=1 tools/check_pins.sh    # accept what is there now as the baseline
#
#  This exists because of e6e7e1c: `midi_int_n`, `midi_rx` and `midi_tx` were
#  added to msx_slots and the instance in msx.sv connected none of them.  The
#  machine hung at its first EI -- Quartus ties an undriven net to GND and that
#  net was an active-low interrupt -- and a bitstream went to a board before
#  anyone noticed.  Nothing caught it: the MIDI benches instantiate dev_midi
#  directly, no bench builds msx.sv's instance list, and the lint that should
#  have said so was run with -Wno-PINMISSING (mine, silencing the deliberate
#  ones below).
#
#  Verilator's PINMISSING is the right detector, but 25 of them are intended --
#  unused debug outputs, optional pins on shared modules -- so this compares
#  against a blessed list and fails only on additions.  Adding a legitimate one
#  means running BLESS=1 and saying why in the commit.
set -eu
cd "$(dirname "$0")/.."
[ -s sim/fullsys/gen/filelist.txt ] || sim/fullsys/prep.sh > /dev/null

BASE=tools/pinmissing_baseline.txt
OUT=${OUT:-/tmp/check_pins}
mkdir -p "$OUT"

verilator --lint-only -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
   -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-IMPLICIT \
   -Wno-BLKANDNBLK -Wno-LATCH -Wno-SIDEEFFECT -Wno-TIMESCALEMOD \
   -Wno-ASCRANGE -Wno-SELRANGE \
   --top-module msx +incdir+sim/fullsys/gen \
   $(cat sim/fullsys/gen/filelist.txt) > "$OUT/lint.log" 2>&1 || true

grep '%Warning-PINMISSING' "$OUT/lint.log" \
  | sed "s/.*: \(rtl\/[^:]*\):[0-9]*:[0-9]*: .*missing pin: '\([^']*\)'.*/\1 \2/" \
  | grep '^rtl/' | sort -u > "$OUT/now.txt" || true

if [ "${BLESS:-0}" = 1 ]; then
   cp "$OUT/now.txt" "$BASE"
   echo "blessed $(wc -l < "$BASE") unconnected ports as the baseline"
   exit 0
fi
[ -e "$BASE" ] || { echo "RESULT FAIL: no $BASE -- run BLESS=1 tools/check_pins.sh once"; exit 1; }

NEW=$(comm -13 "$BASE" "$OUT/now.txt")
if [ -n "$NEW" ]; then
   echo "RESULT FAIL: a port was added to a module and left unconnected at its instance:"
   echo "$NEW" | sed 's/^/   /'
   echo "   (connect it, or BLESS=1 tools/check_pins.sh if it is meant to float)"
   exit 1
fi
GONE=$(comm -23 "$BASE" "$OUT/now.txt")
[ -n "$GONE" ] && { echo "note: these are now connected -- re-bless when convenient:"; echo "$GONE" | sed 's/^/   /'; }
echo "pin check: no new unconnected ports ($(wc -l < "$OUT/now.txt") known)"
