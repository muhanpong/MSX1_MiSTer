#!/usr/bin/env bash
#  almrig -- synthesise ONE module on its own and print what it costs.
#
#      tools/almrig/almrig.sh <top> <file>...        # ~1 min, vs 25 for a build
#      tools/almrig/almrig.sh --diff <tag> <top> <file>...   # also save/compare
#
#  Why: the PCM engine is 6,330 ALM, a third of the machine, and the last two
#  attempts to shrink it (slot header/dyn to MLAB, the word cache to altsyncram)
#  moved 1,263 registers out and changed ALM by +50.  Guessing costs 25 minutes a
#  guess.  This runs quartus_map alone on the module, in the real device, and
#  prints combinational ALUTs / registers / memory bits, so a candidate change is
#  measured before it is believed.
#
#  Map-only numbers are ESTIMATES: the fitter packs ALUTs into ALMs and can do
#  better or worse than 1.0.  Use them to compare VARIANTS of the same module,
#  never as the number that goes in a report -- that one comes from a real fit.
set -eu
cd "$(dirname "$0")/../.."
Q=/run/media/muhanpong/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3/intelFPGA_lite/17.1/quartus/bin
[ -x "$Q/quartus_map" ] || { echo "GATE-FAIL: Quartus volume not mounted at $Q"; exit 3; }

TAG=""
if [ "${1:-}" = "--diff" ]; then TAG=$2; shift 2; fi
TOP=${1:?usage: almrig.sh [--diff <tag>] <top-entity> <file>...}; shift
W=${ALMRIG_DIR:-/tmp/almrig}/$TOP
rm -rf "$W"; mkdir -p "$W"

{
  echo "set_global_assignment -name FAMILY \"Cyclone V\""
  echo "set_global_assignment -name DEVICE 5CSEBA6U23I7"
  echo "set_global_assignment -name TOP_LEVEL_ENTITY $TOP"
  #  Same synthesis settings as the real project, or the numbers do not transfer.
  grep -E 'OPTIMIZATION_(MODE|TECHNIQUE)|AUTO_RAM|ALLOW_ANY_RAM|SYNTH_' MSX1.qsf 2>/dev/null || true
  for f in "$@"; do
     case "$f" in
       *.sv) echo "set_global_assignment -name SYSTEMVERILOG_FILE $PWD/$f";;
       *.v)  echo "set_global_assignment -name VERILOG_FILE $PWD/$f";;
       *)    echo "set_global_assignment -name SOURCE_FILE $PWD/$f";;
     esac
  done
} > "$W/$TOP.qsf"
: > "$W/$TOP.qpf"

( cd "$W" && "$Q/quartus_map" "$TOP" -c "$TOP" ) > "$W/map.log" 2>&1 || {
   echo "MAP FAIL:"; grep -E '^Error' "$W/map.log" | head -10; exit 1; }

R="$W/$TOP.map.rpt"
#  Take the numbers from the resource SUMMARY rows ("; <label> ; <n> ;").  The
#  hierarchy table repeats the same labels as column HEADINGS, so an unanchored
#  grep returns the header text instead of a number.
get() { grep -m1 -E "^; +$1 +;" "$R" | awk -F';' '{gsub(/[ ,]/,"",$3); print $3}'; }
ALUT=$(get 'Combinational ALUT usage for logic')
REG=$(get 'Dedicated logic registers')
MEM=$(get 'Total block memory bits')
DSP=$(get 'Total number of DSP blocks')
echo "$TOP: ALUT=${ALUT:-?} REG=${REG:-?} MEMBITS=${MEM:-?} DSP=${DSP:-?}   ($W)"

if [ -n "$TAG" ]; then
   B=tools/almrig/baseline.$TOP.txt
   line="$TAG ALUT=${ALUT:-?} REG=${REG:-?} MEMBITS=${MEM:-?} DSP=${DSP:-?}"
   if [ -e "$B" ]; then
      echo "--- against $B:"; cat "$B"
      prev=$(head -1 "$B" | grep -oE 'ALUT=[0-9]+' | cut -d= -f2)
      [ -n "${prev:-}" ] && [ -n "${ALUT:-}" ] && echo "    delta ALUT $(( ALUT - prev ))"
   else
      echo "$line" > "$B"; echo "--- baseline written to $B"
   fi
fi
