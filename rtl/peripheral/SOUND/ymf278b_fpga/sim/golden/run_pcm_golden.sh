#!/usr/bin/env bash
# PCM golden comparison: RTL engine vs YMF278.cc-derived python model.
set -e
cd "$(dirname "$0")"
G=.
R=../../
mkdir -p out

python3 gen_pcm_testdata.py

#  SIMULATOR.  Verilator by default: since 2026-09-24 the engine writes single
#  fields of an unpacked array element (`ram_regs[i].field <= x`), which removes
#  the read-modify-write muxes and which iverilog cannot elaborate at all
#  (elab_lval.cc:1277).  SIM=iverilog still runs the old path for anything that
#  predates that; it will simply fail to build on today's engine.
#
#  A failed compile must FAIL.  The iverilog line used to end in
#  `| grep -v sorry || true`, which hid the error AND left the previous
#  out/tb_golden_pcm.vvp in place -- the run then compared the OLD engine and
#  printed ALL SCENARIOS MATCH for a change that does not compile.
if [ "${SIM:-verilator}" != "iverilog" ]; then
    exec ./run_pcm_golden_vl.sh "$@"
fi
rm -f out/tb_golden_pcm.vvp
iverilog -g2012 -o out/tb_golden_pcm.vvp \
  $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
  $R/rtl/pcm/ymf278_pcm_engine2.sv $R/tb/tb_golden_pcm.sv 2>&1 | grep -v 'sorry:' || true
[ -x out/tb_golden_pcm.vvp ] || { echo "RESULT FAIL: iverilog did not produce out/tb_golden_pcm.vvp"; exit 1; }

FAIL=0
for sc in sc_single8 sc_square16 sc_tri12_loop sc_multi sc_lfo sc_pitchbend sc_wavehi sc_odd16; do
    frames=$(case $sc in sc_tri12_loop|sc_pitchbend) echo 1000;; sc_multi) echo 1200;; sc_lfo) echo 1500;; sc_wavehi) echo 800;; *) echo 900;; esac)
    vvp out/tb_golden_pcm.vvp +script=$G/$sc.txt +mem=$G/mem.hex +frames=$frames +out=out/${sc}_rtl.txt > /dev/null 2>&1
    python3 golden_pcm.py $G/$sc.txt $G/mem.bin $frames out/${sc}_gold.txt > /dev/null
    python3 compare_pcm.py out/${sc}_rtl.txt out/${sc}_gold.txt "$sc" || FAIL=1
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "PCM GOLDEN: ALL SCENARIOS MATCH" || echo "PCM GOLDEN: MISMATCHES FOUND"
exit $FAIL
