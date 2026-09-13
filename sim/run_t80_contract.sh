#!/usr/bin/env bash
# T80pa vs T80s bus contract, side by side.
#
# usage:  sim/run_t80_contract.sh [DIVN]      clk21m ticks per T-state (default 6)
# env:    OUT=<dir>  (default /tmp/t80ct)
#
# Prints both traces and their diff.  T80pa cannot run at DIVN=1 -- it needs two
# enables per T-state -- so that case runs T80s alone.
set -eu
OUT=${OUT:-/tmp/t80ct}; DIVN=${1:-6}
rm -rf "$OUT"; mkdir -p "$OUT"
FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed-rules"
SRC="rtl/cpu/T80_Pack.vhd rtl/cpu/T80_ALU.vhd rtl/cpu/T80_MCode.vhd rtl/cpu/T80_Reg.vhd
     rtl/cpu/T80.vhd rtl/cpu/T80pa.vhd rtl/cpu/T80s.vhd rtl/cpu/sim/tb_t80_contract.vhd"
ghdl -a --workdir="$OUT" $FLAGS -Wno-hide $SRC 2>&1 | grep -v '^$' | head -5 || true
ghdl -e --workdir="$OUT" $FLAGS TB_T80_CONTRACT 2>&1 | head -3 || true
for w in 0 1; do
    ghdl -r --workdir="$OUT" $FLAGS TB_T80_CONTRACT \
         -gUSE_T80S=$w -gDIVN=$DIVN --ieee-asserts=disable \
         > "$OUT/w$w.txt" 2>&1 || true
done
echo "=== T80pa (DIVN=$DIVN) ==="; head -30 "$OUT/w0.txt"
echo; echo "=== T80s (DIVN=$DIVN) ==="; head -30 "$OUT/w1.txt"
echo; echo "=== diff ==="; diff "$OUT/w0.txt" "$OUT/w1.txt" | head -40 || true
