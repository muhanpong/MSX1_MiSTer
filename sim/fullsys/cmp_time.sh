#!/usr/bin/env bash
#  Compare two fullsys runs' branch PCs TIME-ALIGNED, up to the shorter run.
#    sim/fullsys/cmp_time.sh <reference.log> <candidate.log>
#  Why not cmp_streams.sh: a simulator log occasionally LOSES a stretch of stdout
#  (2026-10-14: 279 lines in one run, ~10 ms in another).  The loss shows as one
#  cut line carrying two timestamps ("1085.7    1091.016  BR  7d60"); counted by
#  index, every branch after it is misaligned and cmp_streams reports a false
#  split.  Here the window of every cut line, in either log, is skipped in BOTH.
#  Since 2026-10-14 BR lines carry "#n" (tb_msx nev): a jump in n is a loss too.
#  RESULT PASS = equal PC sequences outside the lost windows.  Timing differences
#  (equal PCs, shifted times) pass up to where the program flow itself changes.
set -u
A=${1:?reference log}; B=${2:?candidate log}
T0=$(mktemp -d)
cut_re='^ *[0-9]+\.[0-9]*( +BR +| +)[0-9]+\.[0-9]+ +BR'
ok() { grep -a ' BR ' "$1" | grep -avE "$cut_re" | awk 'NF>=3 && $3 ~ /^[0-9a-f]+$/ && length($3)==4 {print $1, $3}'; }
ok "$A" > $T0/a; ok "$B" > $T0/b
grep -ahE "$cut_re" "$A" "$B" | awk '{n=0; for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]*$/) t[++n]=$i; printf "%s %s ", t[1], t[n]}' > $T0/gaps
ta=$(tail -n1 $T0/a | awk '{print $1}'); tb=$(tail -n1 $T0/b | awk '{print $1}')
T=$(echo "$ta $tb" | awk '{print ($1<$2)?$1:$2}')
#  the last line of a live log may be half written: stop one line short of T
#  (gaps passed as a variable: with an empty gaps FILE, awk's NR==FNR is true for
#   the log too and every line was skipped -- "0 vs 0 branches", a silent PASS)
filt() { awk -v T=$T -v G="$(cat $T0/gaps)" 'BEGIN {n=split(G,g," ")} {t=$1; if (t>=T) next; for(i=1;i<n;i+=2) if (t>=g[i]-0.05 && t<=g[i+1]+0.05) next; print $2}' "$1"; }
filt $T0/a > $T0/a2; filt $T0/b > $T0/b2
echo "up to $T ms: $(wc -l < $T0/a2) vs $(wc -l < $T0/b2) branches (lost windows: $(cat $T0/gaps))"
[ -s $T0/a2 ] || { echo "TIME-ALIGNED RESULT FAIL: no branches compared"; rm -rf $T0; exit 1; }
if cmp -s $T0/a2 $T0/b2; then echo "TIME-ALIGNED RESULT PASS"; rm -rf $T0; exit 0; fi
k=$(cmp $T0/a2 $T0/b2 | awk '{print $NF}')
echo "first difference at $k (ref | cand):"
paste <(sed -n "$((k>3?k-3:1)),$((k+3))p" $T0/a2) <(sed -n "$((k>3?k-3:1)),$((k+3))p" $T0/b2)
echo "TIME-ALIGNED RESULT FAIL"; rm -rf $T0; exit 1
