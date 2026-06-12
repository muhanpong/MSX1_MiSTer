#!/usr/bin/env bash
# PCM golden comparison: RTL engine vs YMF278.cc-derived python model.
set -e
cd "$(dirname "$0")"
G=.
R=../../
mkdir -p out

python3 gen_pcm_testdata.py

iverilog -g2012 -o out/tb_golden_pcm.vvp \
  $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
  $R/rtl/pcm/ymf278_pcm_engine2.sv $R/tb/tb_golden_pcm.sv 2>&1 | grep -v sorry || true

FAIL=0
for sc in sc_single8 sc_square16 sc_tri12_loop sc_multi sc_lfo; do
    frames=$(case $sc in sc_tri12_loop) echo 1000;; sc_multi) echo 1200;; sc_lfo) echo 1500;; *) echo 900;; esac)
    vvp out/tb_golden_pcm.vvp +script=$G/$sc.txt +mem=$G/mem.hex +frames=$frames +out=out/${sc}_rtl.txt > /dev/null 2>&1
    python3 golden_pcm.py $G/$sc.txt $G/mem.bin $frames out/${sc}_gold.txt > /dev/null
    python3 compare_pcm.py out/${sc}_rtl.txt out/${sc}_gold.txt "$sc" || FAIL=1
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "PCM GOLDEN: ALL SCENARIOS MATCH" || echo "PCM GOLDEN: MISMATCHES FOUND"
exit $FAIL
