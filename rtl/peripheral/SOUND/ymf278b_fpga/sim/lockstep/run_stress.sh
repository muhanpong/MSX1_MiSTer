#!/bin/bash
#  Stress lockstep for the PCM slot register file (per-register-byte MLABs).
#
#      ./run_stress.sh          # quick: lat {6,20}, seed 1       (~200 runs)
#      ./run_stress.sh full     # lat {1,6,20,40}, seeds {1,2,3} (~900 runs)
#
#  The current engine and the flop-array reference (ymf278_pcm_engine2_ref.sv)
#  get identical stimulus and are compared on every output, every cycle.  On top
#  of each golden scenario, +stress aims random slot-register writes at the races
#  the MLAB register file could get wrong: a write on the very edge dispatch reads
#  that slot, the next slot a few cycles ahead, a write colliding with the header
#  backfill (same slot and another slot), and -- with +reset_every -- writes in
#  the first 40 cycles after a warm reset during playback.
#
#  PASS needs all four:
#    1. engine: 0 mismatches in every run, with and without warm resets;
#    2. every mutant (mut_*.sv) mismatches in EVERY run it is given;
#    3. a reset held 8 cycles MISMATCHES (the engine clears its register file
#       while in reset and needs >= 24 clk; see the sweep in the engine);
#    4. every targeted event happened at least once -- otherwise a clean run
#       says nothing.
set -u
cd "$(dirname "$0")"
R=../..
O=${OUT:-out_stress}
P=${P:-32}
MODE=${1:-quick}
rm -rf "$O"; mkdir -p "$O"
(cd ../golden && python3 gen_pcm_testdata.py > /dev/null)

build() {   # name engine-file
    iverilog -g2012 -o "$O/$1.vvp" $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
        "$2" ymf278_pcm_engine2_ref.sv tb_lockstep_pcm.sv 2>&1 | grep -v 'sorry:'
    [ -x "$O/$1.vvp" ] || { echo "RESULT FAIL: iverilog did not build $1"; exit 1; }
}
build eng $R/rtl/pcm/ymf278_pcm_engine2.sv
for m in rd1 nopend sw23 noclr; do build $m mut_$m.sv; done

SC="sc_single8:620 sc_square16:620 sc_tri12_loop:720 sc_multi:520 sc_lfo:300 sc_pitchbend:820
    sc_wavehi:520 sc_odd16:620 sc_relwave:200 sc_songchange:900 sc_songchange24:340 sc_memwrite:440
    sc_dirdep_good:700 sc_dirdep_bad:700 sc_st02:1600 sc_st04:2500"
if [ "$MODE" = full ]; then LATS="1 6 20 40"; SEEDS="1 2 3"; else LATS="6 20"; SEEDS="1"; fi
RST="+reset_at=150000 +reset_every=70000"

#  job: tag vvp scenario frames lat seed extra...
{
  for sc in $SC; do s=${sc%%:*}; f=${sc##*:}
    for lat in $LATS; do for seed in $SEEDS; do
      echo "eng_st eng $s $f $lat $seed"
      echo "eng_rs eng $s $f $lat $seed $RST"
      echo "rd1 rd1 $s $f $lat $seed"
      echo "nopend nopend $s $f $lat $seed"
      echo "sw23 sw23 $s $f $lat $seed $RST"
      echo "noclr noclr $s $f $lat $seed $RST"
    done; done
  done
  echo "short eng sc_multi 300 6 1 $RST +reset_len=8"
} | xargs -P "$P" -L1 bash -c '
    t=$0; v=$1; s=$2; f=$3; l=$4; sd=$5; shift 5
    vvp -n '"$O"'/$v.vvp +script=../golden/$s.txt +mem=../golden/mem.hex +frames=$f +lat=$l \
        +out=/dev/null +stress=1 +seed=$sd "$@" 2>&1 \
      | grep -E "^(LOCKSTEP|COVERAGE|STRESS|RESETCOV)" | tr "\n" " " > '"$O"'/${t}_${s}_${l}_${sd}.log
    echo >> '"$O"'/${t}_${s}_${l}_${sd}.log'

FAIL=0
runs()  { cat "$O"/$1_*.log | grep -c LOCKSTEP; }
dirty() { cat "$O"/$1_*.log | grep LOCKSTEP | grep -vc 'mismatches=0 '; }
total() { cat "$O"/$1_*.log | grep -oE "$2=[0-9]+" | awk -F= '{t+=$2} END{print t+0}'; }

for t in eng_st eng_rs; do
    n=$(runs $t); d=$(dirty $t)
    echo "$t: runs=$n with_mismatch=$d"
    [ "$n" -gt 0 ] && [ "$d" -eq 0 ] || { echo "  FAIL: engine must match in every run"; FAIL=1; }
done
for t in rd1 nopend sw23 noclr; do
    n=$(runs $t); d=$(dirty $t)
    echo "mutant $t: runs=$n with_mismatch=$d"
    [ "$n" -gt 0 ] && [ "$d" -eq "$n" ] || { echo "  FAIL: mutant must mismatch in every run"; FAIL=1; }
done
d=$(dirty short)
echo "reset held 8 cycles: with_mismatch=$d (expected 1)"
[ "$d" -eq 1 ] || { echo "  FAIL: a too-short reset must be visible"; FAIL=1; }

echo "events (engine):"
for e in wr_same_cycle_as_dispatch of_which_active deferred_cpu_wr col_same_slot C_bf_other \
         hdr_store_then_stall_read resets_with_active_slots E_writes_after_release; do
    n=$(( $(total eng_st $e) + $(total eng_rs $e) ))
    printf '  %-28s %d\n' "$e" "$n"
    [ "$n" -gt 0 ] || { echo "  FAIL: $e never happened -- the pass would be vacuous"; FAIL=1; }
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "PCM STRESS LOCKSTEP: PASS" || echo "RESULT FAIL: PCM STRESS LOCKSTEP"
exit $FAIL
