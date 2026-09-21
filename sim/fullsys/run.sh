#!/usr/bin/env bash
#  Build and run the whole-machine bench.
#
#      sim/fullsys/prep.sh                       # once, and after any RTL change
#      sim/fullsys/run.sh <pack.MSX> [ms]        # default 60 ms of MSX time
#
#  Output is the branch-target stream, the same rule rtl/evt_trace.sv uses on
#  hardware, so a board capture and this can be diffed line for line.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD
GEN=$ROOT/sim/fullsys/gen
OUT=${OUT:-/tmp/fullsys_sim}
PACK=${1:?usage: run.sh <pack.MSX> [ms]}
MS=${2:-60}

[ -s "$GEN/filelist.txt" ] || { echo "run: sim/fullsys/prep.sh first"; exit 2; }

#  The real sdram.sv drives a bidirectional SDRAM_DQ, which Verilator cannot
#  do procedurally; tb/mkshim.py's copy replaces it and defines the same module
#  name, so the original has to come OUT of the list or it wins by being first.
FILES=$(grep -v 'rtl/peripheral/sdram\.sv$' "$GEN/filelist.txt" | tr '\n' ' ')

mkdir -p "$OUT"
verilator --binary --timing --public-flat-rw \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
   -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
   -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK \
   -Wno-TIMESCALEMOD \
   --top-module tb -o tbmsx -Mdir "$OUT/v" \
   "+incdir+$GEN" $FILES "$GEN/sdram_sim.sv" sim/fullsys/tb_msx.sv \
   > "$OUT/build.log" 2>&1 || { echo "BUILD FAIL:"; grep -E '%Error' "$OUT/build.log" | head -20; exit 1; }

echo "built -> $OUT/v/tbmsx"
"$OUT/v/tbmsx" +pack="$PACK" +ms=$MS
