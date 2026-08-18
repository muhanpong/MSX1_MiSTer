#!/usr/bin/env bash
# SCC/SCC+ integration TB runner (docs/sccplus_spec.md S3)
#
#  1. build + run tb_sccplus against the WORKING TREE RTL      -> new
#  2. build + run tb_sccplus against the PRE-CHANGE RTL (git   -> gold
#     ref, default HEAD) extracted with `git show`, no stash/checkout
#  3. bit-compare the T1 (Real mode) wave sample dump new vs gold
#
# usage:  sim/run_sccplus.sh [GOLD_REF]        (GOLD_REF default: HEAD)
# env:    OUT=<dir> (default /tmp/sccplus_sim)  GOLD_DIR=<dir> (default /tmp/gold)
#         SKIP_GOLD=1  only run the working-tree sim
set -u
cd "$(dirname "$0")/.."

GOLD_REF=${1:-HEAD}
OUT=${OUT:-/tmp/sccplus_sim}
GOLD_DIR=${GOLD_DIR:-/tmp/gold}
mkdir -p "$OUT" "$GOLD_DIR"

TB=sim/tb_sccplus.sv
RTL_WRAP=rtl/peripheral/slots/scc_sound.sv
RTL_IKA=rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v
RTL_PRIM=rtl/IKASCC/src/IKASCC_modules/IKASCC_primitives.v

rc=0

echo "### [new] working tree RTL"
iverilog -g2012 -o "$OUT/new.vvp" "$TB" "$RTL_WRAP" "$RTL_IKA" "$RTL_PRIM" || { echo "new: COMPILE FAILED"; exit 2; }
vvp -n "$OUT/new.vvp" +dump="$OUT/new_wave.txt" | tee "$OUT/new.log" | grep -E '^(FAIL|RESULT|---)'
grep -q '^RESULT: [0-9]* passed, 0 failed' "$OUT/new.log" || rc=1

if [ "${SKIP_GOLD:-0}" = "1" ]; then exit $rc; fi

echo
echo "### [gold] RTL from git ref $GOLD_REF"
git show "$GOLD_REF:$RTL_WRAP" > "$GOLD_DIR/scc_sound.sv"        || exit 2
git show "$GOLD_REF:$RTL_IKA"  > "$GOLD_DIR/IKASCC_player_s.v"   || exit 2
git show "$GOLD_REF:$RTL_PRIM" > "$GOLD_DIR/IKASCC_primitives.v" || exit 2
iverilog -g2012 -o "$OUT/gold.vvp" "$TB" "$GOLD_DIR/scc_sound.sv" "$GOLD_DIR/IKASCC_player_s.v" "$GOLD_DIR/IKASCC_primitives.v" \
   || { echo "gold: COMPILE FAILED"; exit 2; }
vvp -n "$OUT/gold.vvp" +dump="$OUT/gold_wave.txt" | tee "$OUT/gold.log" | grep -E '^(RESULT)'
echo "(gold is expected to FAIL T2-T4; only its T1 wave dump is used as reference)"

echo
echo "### T1 Real-mode wave dump: new vs gold"
if cmp -s "$OUT/new_wave.txt" "$OUT/gold_wave.txt"; then
   echo "GOLDEN: IDENTICAL ($(wc -l < "$OUT/new_wave.txt") samples)"
else
   echo "GOLDEN: MISMATCH  (first diffs below)"; diff "$OUT/gold_wave.txt" "$OUT/new_wave.txt" | head -20
   rc=1
fi

echo
echo "new : $(grep '^RESULT' "$OUT/new.log")"
echo "gold: $(grep '^RESULT' "$OUT/gold.log")"
exit $rc
