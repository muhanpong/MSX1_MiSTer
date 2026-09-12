#!/usr/bin/env bash
# run_vdpcmd7.sh, but the seven commands in parallel instead of one after another.
#
# tb_vdpcmd7 always runs K=0 (HMMV) because it is what fills the source
# rectangle every other command reads, so a single-command run costs
# HMMV + that command.  Sequentially the seven cost their sum (~25 min);
# spread over separate processes they cost the slowest one (HMMV + LMMM).
# GHDL is single-threaded per process, so this is the only parallelism
# available -- and the box has 16 cores for 6 jobs.
#
# usage:  sim/run_vdpcmd7_par.sh
# env:    OUT=<dir>   (default /tmp/vdpcmd7par)
set -eu
OUT=${OUT:-/tmp/vdpcmd7par}
rm -rf "$OUT"; mkdir -p "$OUT"
NAMES=(HMMV HMMM LMMV LMMM YMMM LINE SRCH)

# Every run executes K=0 because it fills the source rectangle, but the TB only
# PRINTS the command that CMDSEL selects -- so HMMV still needs a job of its own.
for K in 0 1 2 3 4 5 6; do
    ( OUT="$OUT/k$K" bash sim/run_vdpcmd7.sh "$K" > "$OUT/k$K.txt" 2>&1 ) &
done
wait

for K in 0 1 2 3 4 5 6; do
    grep -h "^${NAMES[$K]}" "$OUT/k$K.txt" || echo "${NAMES[$K]}: no result -- see $OUT/k$K.txt"
done
