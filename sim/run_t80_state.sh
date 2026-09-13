#!/usr/bin/env bash
# Architectural-state diff for the CPU wrappers.
#
# T80 exposes REG(211:0) -- the whole register file -- and T80s now forwards it,
# so "did this change alter behaviour" is a diff rather than a board test.  The
# first use was the WAIT question: T80pa hardwires the core's WAIT_n to '1' and
# withholds CEN (T80pa.vhd:123,170, header line 51 "WAIT_n is broken in
# T80.vhd"), while T80s routes the real WAIT_n in and lets the core keep
# clocking.  Our turbo guard works entirely by inserting waits, so if that were
# unsafe every turbo speed would be quietly wrong.
#
# usage:  sim/run_t80_state.sh
# env:    OUT=<dir>  (default /tmp/t80state)
set -eu
OUT=${OUT:-/tmp/t80state}; rm -rf "$OUT"; mkdir -p "$OUT"
FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed-rules"
SRC="rtl/cpu/T80_Pack.vhd rtl/cpu/T80_ALU.vhd rtl/cpu/T80_MCode.vhd rtl/cpu/T80_Reg.vhd
     rtl/cpu/T80.vhd rtl/cpu/T80pa.vhd rtl/cpu/T80s.vhd rtl/cpu/sim/tb_t80_state.vhd"
ghdl -a --workdir="$OUT" $FLAGS -Wno-hide $SRC 2>&1 | head -5
ghdl -e --workdir="$OUT" $FLAGS TB_T80_STATE 2>&1 | head -3 || true

ref=""
fail=0
for cfg in "0 2" "1 2" "1 1"; do
    set -- $cfg
    for w in 0 1 2 3 4 6 8; do
        out=$(ghdl -r --workdir="$OUT" $FLAGS TB_T80_STATE \
              -gUSE_T80S=$1 -gDIVN=$2 -gEXTRA_WAIT=$w --ieee-asserts=disable 2>&1 || true)
        hdr=$(echo "$out" | grep '^wrapper')
        reg=$(echo "$out" | grep -o 'REG=[0-9A-F]*')
        [ -z "$ref" ] && ref="$reg"
        if [ "$reg" = "$ref" ]; then echo "  ok   $hdr"
        else echo "  DIFF $hdr"; echo "       $reg"; echo "       want $ref"; fail=1; fi
    done
done
echo
if [ $fail -eq 0 ]; then
    echo "run_t80_state: PASS -- architectural state identical across both wrappers,"
    echo "               both dividers and every wait depth 0..8"
else
    echo "run_t80_state: FAIL"
fi
exit $fail
