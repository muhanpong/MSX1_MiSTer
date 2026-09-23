#!/usr/bin/env bash
#  The PCM golden comparison, run under Verilator instead of iverilog.
#
#      ./run_pcm_golden_vl.sh
#
#  Why a second runner: iverilog cannot elaborate a per-field write into an
#  unpacked array element (`ram_regs[i].field <= x`, elab_lval.cc:1277), which
#  is exactly the shape that removes the engine's read-modify-write muxes.
#  Verilator takes it, and the rest of this project already simulates in
#  Verilator.  Keep BOTH: iverilog is what RESULTS.md was measured with, and two
#  independent simulators agreeing on bit-exactness is worth the extra minute.
set -eu
cd "$(dirname "$0")"
G=.; R=../../
OUT=${OUT:-/tmp/vgold}
mkdir -p out

python3 gen_pcm_testdata.py > /dev/null

#  The whole -Mdir, not just the binary: with only the binary removed verilator
#  re-runs make, make says "Nothing to be done", and the check below then
#  reports no binary for a build that never happened.
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT \
   --top-module tb_golden_pcm -o vgold -Mdir "$OUT" \
   $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
   $R/rtl/pcm/ymf278_pcm_engine2.sv $R/tb/tb_golden_pcm.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
[ -x "$OUT/vgold" ] || { echo "RESULT FAIL: verilator produced no binary"; exit 1; }

FAIL=0
for sc in sc_single8 sc_square16 sc_tri12_loop sc_multi sc_lfo sc_pitchbend sc_wavehi sc_odd16; do
    frames=$(case $sc in sc_tri12_loop|sc_pitchbend) echo 1000;; sc_multi) echo 1200;; sc_lfo) echo 1500;; sc_wavehi) echo 800;; *) echo 900;; esac)
    "$OUT/vgold" +script=$G/$sc.txt +mem=$G/mem.hex +frames=$frames +out=out/${sc}_vl.txt > /dev/null 2>&1
    python3 golden_pcm.py $G/$sc.txt $G/mem.bin $frames out/${sc}_gold.txt > /dev/null
    python3 compare_pcm.py out/${sc}_vl.txt out/${sc}_gold.txt "$sc" || FAIL=1
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "PCM GOLDEN (verilator): ALL SCENARIOS MATCH" || echo "RESULT FAIL: PCM GOLDEN (verilator) mismatches"
exit $FAIL
