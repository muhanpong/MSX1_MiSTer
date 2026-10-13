#!/usr/bin/env bash
#  Compare two fullsys runs of the same pack: the branch-target streams after the
#  machine is released, the CPU read latency and the demand lines.
#    sim/fullsys/cmp_streams.sh <reference.log> <candidate.log>
#  RESULT PASS only if the candidate's stream equals the reference over the
#  shorter of the two (timestamps differ: the upload ends at a different time).
#  Written 2026-10-13 for the sdram128 study: sdram_tdm (run_tdm.sh) diverged from
#  sdram.sv (run.sh) at the 5th branch after release, which the timing numbers
#  and the TDM bench did not show.  Compare every TDM change against run.sh.
set -u
A=${1:?reference log}; B=${2:?candidate log}
T=$(mktemp -d)
for x in A B; do
    f=${!x}
    grep -E '^ *[0-9.]+ +BR +[0-9a-f]+' "$f" | awk '{print $3}' > $T/$x
    [ -s $T/$x ] || { echo "RESULT FAIL: no branch stream in $f"; exit 1; }
done
na=$(wc -l < $T/A); nb=$(wc -l < $T/B); n=$(( na < nb ? na : nb ))
head -n $n $T/A > $T/a; head -n $n $T/B > $T/b
for x in A B; do
    echo "$x: $(wc -l < $T/$x) branches, $(sort -u $T/$x | wc -l) unique PCs, $(grep -h 'cpu read latency' ${!x} | sed 's/ hist.*//')"
done
if cmp -s $T/a $T/b; then
    echo "streams equal over $n branches"
    echo "RESULT PASS"; rm -rf $T; exit 0
fi
k=$(cmp $T/a $T/b | awk '{print $NF}')
echo "first difference at branch $k:"
echo "  ref:  $(sed -n "$(( k>3 ? k-3 : 1 )),$((k+3))p" $T/a | tr '\n' ' ')"
echo "  cand: $(sed -n "$(( k>3 ? k-3 : 1 )),$((k+3))p" $T/b | tr '\n' ' ')"
echo "RESULT FAIL"; rm -rf $T; exit 1
