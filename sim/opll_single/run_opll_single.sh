#!/usr/bin/env bash
#  One OPLL per machine (rtl/peripheral/slots/opll_ika.sv) against the old
#  three-instance wrapper (opll_ref3.sv), every output sample compared.
#
#      sim/opll_single/run_opll_single.sh
#
#  PASS needs all of:
#    A, B, E  : 0 mismatches and the tone audible (nz_dut > 0)
#    C        : no OPLL configured, stray OUT (7C): BOTH outputs zero for the run
#    D        : built-in + FM-PAC with I/O enable: ref == 2 * dut on every sample
#               (two identical chips summed vs one), dbl_bad = 0, tone audible
#    F        : built-in present, a write on the slot-A FM-PAC path with no
#               FM-PAC configured: both silent (the old design sent it to a
#               deselected chip).  C cannot see the gate (i_CS_n is high with
#               no device at all), F can.
#    mutant   : the wrapper with the per-source gate dropped (|wr instead of
#               |(wr & cs)) must FAIL scenario F (it plays from the stray path)
#  A run whose log has no OPLLSINGLE line is a FAIL, not a pass.
set -u
cd "$(dirname "$0")/../.."
OUT=${OUT:-/tmp/opll_single}
rm -rf "$OUT"; mkdir -p "$OUT"
IKA="rtl/sound/IKAOPLL/src/IKAOPLL.v $(ls rtl/sound/IKAOPLL/src/IKAOPLL_modules/*.v | tr '\n' ' ')"

#  mutant: same file, gate dropped.  It must differ from the source or it tests nothing.
sed -e 's/wire wr_any = |(wr & cs);/wire wr_any = |wr;/' rtl/peripheral/slots/opll_ika.sv > "$OUT/opll_mut.sv"
cmp -s rtl/peripheral/slots/opll_ika.sv "$OUT/opll_mut.sv" && { echo "RESULT FAIL: mutant identical to source (sed matched nothing)"; exit 1; }

build() {   # name wrapper-file
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
      -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
      -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-LATCH -Wno-INITIALDLY -Wno-ASCRANGE \
      --top-module tb_opll_single -o "$1" -Mdir "$OUT/v_$1" \
      $IKA sim/opll_single/opll_ref3.sv "$2" sim/opll_single/tb_opll_single.sv > "$OUT/build_$1.log" 2>&1 \
      || { echo "RESULT FAIL: verilator build $1"; grep -E '%Error' "$OUT/build_$1.log" | head -8; exit 1; }
   [ -x "$OUT/v_$1/$1" ] || { echo "RESULT FAIL: no binary for $1"; exit 1; }
}
build eng rtl/peripheral/slots/opll_ika.sv
build mut "$OUT/opll_mut.sv"

for sc in A B C D E F; do "$OUT/v_eng/eng" +sc=$sc > "$OUT/eng_$sc.log" 2>&1 & done
"$OUT/v_mut/mut" +sc=F > "$OUT/mut_F.log" 2>&1 &
wait

FAIL=0
field() { grep -oE "$2=[-0-9]+" "$OUT/$1.log" | head -1 | cut -d= -f2; }
ck() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; FAIL=1; fi; }
for f in eng_A eng_B eng_C eng_D eng_E eng_F mut_F; do
   grep -q OPLLSINGLE "$OUT/$f.log" || { echo "FAIL  $f produced no result line"; FAIL=1; }
done
for sc in A B E; do
   ck "$sc identical  (mism=$(field eng_$sc mismatches) nz=$(field eng_$sc nz_dut))" \
      "[ \"$(field eng_$sc mismatches)\" = 0 ] && [ \"$(field eng_$sc nz_dut)\" -gt 0 ]"
done
ck "C no OPLL: both silent (nz_ref=$(field eng_C nz_ref) nz_dut=$(field eng_C nz_dut))" \
   "[ \"$(field eng_C nz_ref)\" = 0 ] && [ \"$(field eng_C nz_dut)\" = 0 ]"
ck "D two chips summed == 2 x one chip (dbl_bad=$(field eng_D dbl_bad) nz=$(field eng_D nz_dut))" \
   "[ \"$(field eng_D dbl_bad)\" = 0 ] && [ \"$(field eng_D nz_dut)\" -gt 0 ]"
ck "F stray FM-PAC-path write, no FM-PAC: both silent (nz_ref=$(field eng_F nz_ref) nz_dut=$(field eng_F nz_dut))" \
   "[ \"$(field eng_F nz_ref)\" = 0 ] && [ \"$(field eng_F nz_dut)\" = 0 ]"
ck "mutant without the gate plays in F (nz_dut=$(field mut_F nz_dut))" \
   "[ \"$(field mut_F nz_dut)\" -gt 0 ]"
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "OPLL SINGLE: PASS" || echo "RESULT FAIL: OPLL SINGLE"
exit $FAIL
