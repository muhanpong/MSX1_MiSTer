#!/usr/bin/env bash
#  Build tb_kanji once, then run it on both CPUs and print the two byte rows.
#
#      sim/fullsys/prep.sh                        # once, and after any RTL change
#      sim/fullsys/run_kanji.sh <pack.MSX> [z80|r800|both] [ms]
#
#  Same file list and flags as run.sh; only the bench differs (tb_kanji.sv).
#  WAVE=N prints N clk_sdram of every bus/guard/cache signal from the first D9h
#  read (+wave).  The upload alone is ~195 ms of machine time (~16 min of wall
#  clock), so `both` runs the two CPUs as two processes side by side.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD
GEN=$ROOT/sim/fullsys/gen
OUT=${OUT:-/tmp/fullsys_kanji}
WAVE=${WAVE:-0}
PACK=${1:?usage: run_kanji.sh <pack.MSX> [z80|r800|both] [ms]}
CPU=${2:-both}
MS=${3:-40}

[ -s "$GEN/filelist.txt" ] || { echo "run: sim/fullsys/prep.sh first"; exit 2; }
FILES=$(grep -v 'rtl/peripheral/sdram\.sv$' "$GEN/filelist.txt" | tr '\n' ' ')

mkdir -p "$OUT"
verilator --binary --timing --public-flat-rw \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
   -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
   -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK \
   -Wno-TIMESCALEMOD \
   --top-module tb -o tbkanji -Mdir "$OUT/v" \
   "+incdir+$GEN" $FILES "$GEN/sdram_sim.sv" sim/fullsys/tb_kanji.sv \
   > "$OUT/build.log" 2>&1 || { echo "BUILD FAIL:"; grep -E '%Error' "$OUT/build.log" | head -20; exit 1; }
echo "built -> $OUT/v/tbkanji"

run_one() {
   "$OUT/v/tbkanji" +pack="$PACK" +cpu=$1 +ms=$MS +wave=$WAVE > "$OUT/$1.log" 2>&1
}
show_one() {
   echo "=== cpu=$1 ==="
   grep -E 'probe:|IN |OUT |RESULT|x32|timeout|FATAL|BR  00' "$OUT/$1.log"
}
case "$CPU" in
   both) run_one z80 & P1=$!; run_one r800 & P2=$!; wait $P1 $P2; show_one z80; show_one r800 ;;
   *)    run_one "$CPU"; show_one "$CPU" ;;
esac
