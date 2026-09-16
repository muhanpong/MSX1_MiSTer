#!/bin/bash
# Lockstep: new engine (MLAB header/dyn) vs reference (flop arrays), every output every cycle.
# usage: run_lockstep.sh <vvp> <outdir> [extra plusargs...]
V=$1; O=$2; shift 2; mkdir -p $O
jobs=()
for sc in sc_single8:620 sc_square16:620 sc_tri12_loop:720 sc_multi:520 sc_lfo:300 sc_pitchbend:820 sc_wavehi:520 sc_odd16:620 \
          sc_relwave:200 sc_songchange:900 sc_songchange24:340 sc_memwrite:440 sc_dirdep_good:700 sc_dirdep_bad:700 sc_st02:1600 sc_st04:2500; do
  s=${sc%%:*}; f=${sc##*:}
  for lat in 1 6 20 40; do jobs+=("$s $f $lat"); done
done
printf '%s\n' "${jobs[@]}" | xargs -P ${P:-6} -L1 bash -c 'vvp -n '"$V"' +script=../golden/$0.txt +mem=../golden/mem.hex +frames=$1 +lat=$2 +out=/dev/null '"$*"' 2>&1 | grep -E "LOCKSTEP|FATAL|MISMATCH|   " | sed "s/^/$0 lat=$2 | /" > '"$O"'/$0_lat$2.log'
cat $O/*.log | grep LOCKSTEP | awk '{m+=0; for(i=1;i<=NF;i++){if($i~/^mismatches=/){split($i,a,"=");m=a[2]} if($i~/^hdr_store_then_stall_read=/){split($i,b,"=");h+=b[2]} } if(m>0)bad++; n++} END{print "runs="n, "runs_with_mismatch="bad+0, "hdr_path_events_total="h}'
grep -h "FATAL" $O/*.log | head -3
