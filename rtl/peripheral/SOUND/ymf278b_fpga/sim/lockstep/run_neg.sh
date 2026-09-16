#!/bin/bash
# negative controls must FAIL (mismatch>0); reset runs on the real engine must PASS
run() { vvp -n $1 +script=../golden/$2.txt +mem=../golden/mem.hex +frames=$3 +lat=$4 +out=/dev/null $5 2>&1 | grep LOCKSTEP | while read -r l; do echo "$1 $2 lat=$4 $5 :: $l"; done; }
export -f run
cat <<J | xargs -P 6 -L1 bash -c 'run $0 $1 $2 $3 "$4"'
mut_m1_hdrlate.vvp sc_dirdep_bad 700 1
mut_m1_hdrlate.vvp sc_st04 2500 20
mut_m3_dbglate.vvp sc_single8 200 1
mut_m2_nodynmask.vvp sc_songchange 600 20 +reset_at=500000
mut_m2_nodynmask.vvp sc_st04 2500 20 +reset_at=2000000
ls.vvp sc_songchange 600 20 +reset_at=500000
ls.vvp sc_st04 2500 20 +reset_at=2000000
ls.vvp sc_dirdep_bad 700 6 +reset_at=900000
ls.vvp sc_songchange24 340 40 +reset_at=300000
J
