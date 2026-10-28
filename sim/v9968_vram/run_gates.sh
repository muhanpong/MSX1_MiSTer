#!/usr/bin/env bash
#  Every V9968 VRAM gate in one run; PASS only if all pass.  Run it after any change under
#  rtl/video/v9968, v9968_link.sv or sdram_tdm.sv, before a seed sweep.
#    sim/v9968_vram/run_gates.sh   OUT=<dir>
#  run.sh MS=20   exactly one RELEASE_PH (5) serves CPU + display traffic
#  run_irq.sh     FH survives to the S#1 read (ASO 224), mutant must fail
#  run_mix.sh     CPU 98h writes during a command land once (SUPER CAT), mutant must fail
#  run_fhoff.sh   FH stays 0 while IE1 is off (Knightmare 224 v2), mutant must fail
#  Each gate is the board's failing condition in the bench, with its own negative control.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
O=${OUT:-/tmp/v9968_gates.$$}; mkdir -p "$O"
fail=0
for g in "run.sh MS=20" run_irq.sh run_mix.sh run_fhoff.sh; do
    s=${g%% *}; n=${s%.sh}
    env OUT="$O/$n" ${g#$s} bash "$HERE/$s" > "$O/$n.txt" 2>&1
    r=$(grep -E '^RESULT' "$O/$n.txt" | tail -1)
    echo "$n: ${r:-RESULT missing}"
    echo "$r" | grep -q '^RESULT PASS' || fail=1
done
[ $fail -eq 0 ] && echo "GATES PASS" || echo "GATES FAIL (see $O)"
