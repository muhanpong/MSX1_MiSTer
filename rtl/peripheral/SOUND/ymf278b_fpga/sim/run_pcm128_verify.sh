#!/usr/bin/env bash
#  PCM engine at 128.86 MHz (branch sdram128-study): every check this work relies
#  on, in one run, each one refusing to pass on an empty or unbuilt result.
#
#    rtl/peripheral/SOUND/ymf278b_fpga/sim/run_pcm128_verify.sh [quick]
#
#  1. golden at 85.909 and 128.86 MHz: both match the model, the 128.86 MHz
#     binary really runs a 2922-cycle frame, and all 8 scenarios are
#     byte-identical between the two clocks.
#  2. stress lockstep at PIPE=0, every cycle: the 85.909 MHz circuit is the one
#     the reference engine is (64 runs clean, 4 mutants must fail).
#  3. SNAPCHK at PIPE=1 under stress: at every dispatch the snapshot equals the
#     async read; SN_MUT_NOCHG (freshness ignoring last cycle's writes) must be
#     caught in every run.
#  4. PIPECHK at PIPE=1 (same runs as 3): each PIPE split (CHIT0 need_b and byte
#     picks, EGPRE/EGPRE2 attack, the inv_word-1 sweep compare) equals the one-cycle
#     expression on every use; every check kind must have fired.  Then four
#     mutants, one per split, each must be caught on its own check kind.
#
#  OUT=<dir> for the work files (default /tmp/pcm128_verify.$$), P=<jobs>.
#  Put Homebrew first: the system verilator is 4.038.
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd)
R=$HERE/..
O=${OUT:-/tmp/pcm128_verify.$$}
P=${P:-32}
mkdir -p "$O"
FAIL=0
fail() { echo "  FAIL: $*"; FAIL=1; }

SCEN="sc_single8 sc_square16 sc_tri12_loop sc_multi sc_lfo sc_pitchbend sc_wavehi sc_odd16"

echo "== 1. golden, 85.909 vs 128.86 MHz"
cd "$HERE/golden"
for spec in 86:85909090 128:128863620; do
    tag=${spec%%:*}; hz=${spec##*:}
    OUT=$O/vg$tag CLK_HZ=$hz TAG=_v$tag ./run_pcm_golden_vl.sh > "$O/golden_$tag.log" 2>&1
    grep -q "ALL SCENARIOS MATCH" "$O/golden_$tag.log" \
        || fail "golden $tag: $(tail -1 "$O/golden_$tag.log")"
    [ -x "$O/vg$tag/vgold" ] || { fail "golden $tag: no binary"; continue; }
    fr=$("$O/vg$tag/vgold" +script=sc_single8.txt +mem=mem.hex +frames=1 +out=/dev/null \
         | grep -o "frame=[0-9]*")
    want=$([ "$tag" = 86 ] && echo frame=1948 || echo frame=2922)
    [ "$fr" = "$want" ] || fail "golden $tag: binary reports '$fr', expected $want"
    echo "  $tag: $(tail -1 "$O/golden_$tag.log")  ($fr)"
done
n=0
for sc in $SCEN; do
    a=out/${sc}_vl_v86.txt; b=out/${sc}_vl_v128.txt
    if [ -s "$a" ] && cmp -s "$a" "$b"; then n=$((n+1)); else fail "$sc differs between clocks (or is empty)"; fi
done
echo "  byte-identical across clocks: $n / 8"
[ "$n" -eq 8 ] || fail "expected 8 identical scenarios"

echo "== 2. stress lockstep, PIPE=0, every cycle"
cd "$HERE/lockstep"
OUT=$O/stress P=$P ./run_stress.sh > "$O/stress.log" 2>&1
grep -E "runs=|PASS|FAIL" "$O/stress.log" | sed 's/^/  /'
grep -q "PCM STRESS LOCKSTEP: PASS" "$O/stress.log" || fail "stress lockstep did not pass"

echo "== 3. SNAPCHK, PIPE=1, under stress"
for v in "eng:-DPIPECHK" "mut:-DSN_MUT_NOCHG"; do
    n=${v%%:*}; d=${v#*:}
    rm -f "$O/snap_$n.vvp"
    iverilog -g2012 $d -Ptb_lockstep_pcm.DUT_PIPE=1 -o "$O/snap_$n.vvp" \
        $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv $R/rtl/pcm/ymf278_pcm_engine2.sv \
        ymf278_pcm_engine2_ref.sv tb_lockstep_pcm.sv 2>&1 | grep -v "sorry:"
    [ -x "$O/snap_$n.vvp" ] || { fail "SNAPCHK $n did not build"; }
done
(cd ../golden && python3 gen_pcm_testdata.py > /dev/null)
rm -rf "$O/snap"; mkdir -p "$O/snap"
SC="sc_single8:620 sc_square16:620 sc_tri12_loop:720 sc_multi:520 sc_lfo:300 sc_pitchbend:820
    sc_wavehi:520 sc_odd16:620 sc_relwave:200 sc_songchange:900 sc_songchange24:340 sc_memwrite:440
    sc_dirdep_good:700 sc_dirdep_bad:700 sc_st02:1600 sc_st04:2500"
[ "${1:-}" = quick ] && SC="sc_multi:300 sc_songchange24:200"
{
  for sc in $SC; do for lat in 6 20; do for v in eng mut; do
      echo "$v ${sc%%:*} ${sc##*:} $lat nr"
      echo "$v ${sc%%:*} ${sc##*:} $lat rs +reset_at=150000 +reset_every=70000"
  done; done; done
} | xargs -P "$P" -L1 bash -c '
    v=$0; s=$1; f=$2; l=$3; k=$4; shift 4
    vvp -n '"$O"'/snap_$v.vvp +script=../golden/$s.txt +mem=../golden/mem.hex +frames=$f \
        +lat=$l +out=/dev/null +stress=1 +seed=1 "$@" 2>&1 \
      | grep -E "^(SNAPCHK|PIPECHK) [a-z]" > '"$O"'/snap/${v}_${s}_${l}_${k}.log'
expect=$(( $(echo $SC | wc -w) * 2 * 2 ))
for v in eng mut; do
    runs=$(ls "$O"/snap/${v}_*.log 2>/dev/null | wc -l)
    empty=$(for f in "$O"/snap/${v}_*.log; do grep -q "^SNAPCHK disp" "$f" || echo x; done | wc -l)
    clean=$(grep -l 'bad=0$' "$O"/snap/${v}_*.log 2>/dev/null | wc -l)
    disp=$(cat "$O"/snap/${v}_*.log 2>/dev/null | grep -oE 'dispatches=[0-9]+' | cut -d= -f2 | paste -sd+ | bc)
    echo "  $v: runs=$runs empty=$empty clean=$clean dispatches=${disp:-0}"
    [ "$runs" -eq "$expect" ] || fail "$v: $runs runs, expected $expect"
    [ "$empty" -eq 0 ] || fail "$v: $empty runs printed no SNAPCHK line"
    [ "${disp:-0}" -gt 0 ] || fail "$v: no dispatch was checked"
    if [ "$v" = eng ]; then [ "$clean" -eq "$runs" ] || fail "engine: snapshot differed from the async read"
    else [ "$clean" -eq 0 ] || fail "mutant: $clean runs were not caught (negative control broken)"; fi
done

echo "== 4. PIPECHK, PIPE=1: the splits, and one mutant per split"
#  sum "<kind>=checks/bad" over a set of logs: prints "checks bad"
pcsum() { cat "$@" 2>/dev/null | grep "^PIPECHK" | grep -oE "$K=[0-9]+/[0-9]+" \
          | awk -F'[=/]' '{c+=$2; b+=$3} END{print c+0, b+0}'; }
for K in decode need_b attack inv; do
    read c b < <(pcsum "$O"/snap/eng_*.log)
    echo "  engine $K: checks=$c bad=$b"
    [ "$c" -gt 0 ] || fail "PIPECHK $K never fired (no exposure is not a pass)"
    [ "$b" -eq 0 ] || fail "PIPECHK $K: a split differs from the one-cycle value"
done
rm -rf "$O/pcm"; mkdir -p "$O/pcm"
#  scenarios that expose each split: 16-bit odd starts and 12-bit (byte picks
#  across words, need_b), memwrite (the invalidate sweep), attack everywhere
PSC="sc_odd16:300 sc_tri12_loop:300 sc_memwrite:440 sc_multi:300"
for m in BSEL:decode NEEDB:need_b ATT:attack INV:inv; do
    M=${m%%:*}
    rm -f "$O/pc_$M.vvp"
    iverilog -g2012 -DPIPECHK -DPC_MUT_$M -Ptb_lockstep_pcm.DUT_PIPE=1 -o "$O/pc_$M.vvp" \
        $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv $R/rtl/pcm/ymf278_pcm_engine2.sv \
        ymf278_pcm_engine2_ref.sv tb_lockstep_pcm.sv 2>&1 | grep -v "sorry:"
    [ -x "$O/pc_$M.vvp" ] || fail "PIPECHK mutant $M did not build"
done
for m in BSEL NEEDB ATT INV; do for sc in $PSC; do echo "$m ${sc%%:*} ${sc##*:}"; done; done \
  | xargs -P "$P" -L1 bash -c '
    vvp -n '"$O"'/pc_$0.vvp +script=../golden/$1.txt +mem=../golden/mem.hex +frames=$2 \
        +lat=6 +out=/dev/null +stress=1 +seed=1 2>&1 | grep "^PIPECHK [a-z]" > '"$O"'/pcm/$0_$1.log'
for m in BSEL:decode NEEDB:need_b ATT:attack INV:inv; do
    M=${m%%:*}; K=${m##*:}
    read c b < <(pcsum "$O"/pcm/${M}_*.log)
    echo "  mutant $M on $K: checks=$c bad=$b"
    [ "$c" -gt 0 ] || fail "mutant $M: no $K check ran"
    [ "$b" -gt 0 ] || fail "mutant $M was not caught (negative control broken)"
done

echo "════════════════════════════════"
[ "$FAIL" -eq 0 ] && echo "RESULT PASS: pcm128 verify" || echo "RESULT FAIL: pcm128 verify"
exit "$FAIL"
