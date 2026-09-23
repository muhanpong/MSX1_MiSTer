#!/usr/bin/env bash
# Direction-dependency golden repro + SDRAM-latency sweep.
# Captured BASIC tester order (key-on first, then wave write while keyed).
# RTL engine vs YMF278.cc model.  +lat=N models ch4 read latency.
set -e
cd "$(dirname "$0")"
R=../../
mkdir -p out

python3 gen_pcm_testdata.py >/dev/null

#  Same simulator choice as run_pcm_golden.sh: Verilator by default, because
#  iverilog cannot elaborate the engine's per-field array writes (2026-09-24).
#  SIM=iverilog keeps the old path for older revisions of the engine.
OUT=${OUT:-/tmp/vgold_dirdep}
if [ "${SIM:-verilator}" = "iverilog" ]; then
    rm -f out/tb_golden_pcm.vvp
    iverilog -g2012 -o out/tb_golden_pcm.vvp \
      $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
      $R/rtl/pcm/ymf278_pcm_engine2.sv $R/tb/tb_golden_pcm.sv 2>&1 | grep -v 'sorry:' || true
    [ -x out/tb_golden_pcm.vvp ] || { echo "RESULT FAIL: iverilog did not produce out/tb_golden_pcm.vvp"; exit 1; }
    SIMRUN="vvp out/tb_golden_pcm.vvp"
else
    rm -rf "$OUT"; mkdir -p "$OUT"
    verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
       -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
       -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT \
       --top-module tb_golden_pcm -o vgold -Mdir "$OUT" \
       $R/rtl/pcm/ymf278_pcm_alu.sv $R/rtl/pcm/ymf278_pcm_eg_step.sv \
       $R/rtl/pcm/ymf278_pcm_engine2.sv $R/tb/tb_golden_pcm.sv > "$OUT/build.log" 2>&1 \
       || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
    [ -x "$OUT/vgold" ] || { echo "RESULT FAIL: verilator produced no binary"; exit 1; }
    SIMRUN="$OUT/vgold"
fi

# golden is latency-independent (frame-based model) — compute once per scenario
for sc in sc_dirdep_good sc_dirdep_bad; do
    python3 golden_pcm.py ./$sc.txt ./mem.bin 700 out/${sc}_gold.txt >/dev/null
done

echo "lat | dirdep_good        | dirdep_bad"
for lat in 1 6 12 20 40 80; do
    g=$($SIMRUN +script=./sc_dirdep_good.txt +mem=./mem.hex +frames=700 +lat=$lat +out=out/g.txt >/dev/null 2>&1; \
        python3 compare_pcm.py out/g.txt out/sc_dirdep_good_gold.txt good 2>&1 | head -1)
    b=$($SIMRUN +script=./sc_dirdep_bad.txt +mem=./mem.hex +frames=700 +lat=$lat +out=out/b.txt >/dev/null 2>&1; \
        python3 compare_pcm.py out/b.txt out/sc_dirdep_bad_gold.txt bad 2>&1 | head -1)
    printf "%3s | %s | %s\n" "$lat" "$g" "$b"
done
