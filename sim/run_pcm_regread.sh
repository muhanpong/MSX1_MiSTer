#!/usr/bin/env bash
#  OPL4 wave register readback (ymf278_pcm_engine2 reg_rd_data) against openMSX
#  peekReg -- see rtl/peripheral/SOUND/ymf278b_fpga/tb/tb_pcm_regread.sv.
#      sim/run_pcm_regread.sh
#  PASS needs the bench clean AND every mutant to fail:
#     zero      slot registers read 0 again (the pre-2026-10-04 behaviour)
#     nodecode  field 4 returned without undoing the bit-5 inversion
#     ldport    the CPU read port addressed by the engine's ld_slot, not reg_addr
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/pcm_regread}
rm -rf "$OUT"; mkdir -p "$OUT"
R=rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm
SRC=$R/ymf278_pcm_engine2.sv
mutate() {
   sed -e "$2" "$SRC" > "$OUT/mut_$1.sv"
   cmp -s "$SRC" "$OUT/mut_$1.sv" && { echo "RESULT FAIL: mutant $1 identical to source"; exit 1; }
}
mutate zero     "s/    else                         reg_rd_data <= frc\[rd_field_q\];/    else                         reg_rd_data <= 8'h00;/"
mutate nodecode "s/reg_rd_data <= enc_byte(4'd4, frc\[4\]);/reg_rd_data <= frc[4];/"
mutate ldport   "s/\.ra(rd_snum_q), \.rd(frc\[gk\]));/.ra(ld_slot), .rd(frc[gk]));/"
build() {
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
      -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-UNDRIVEN \
      -Wno-INITIALDLY -Wno-LATCH -Wno-MULTIDRIVEN -Wno-BLKANDNBLK --public-flat-rw \
      --top-module tb_pcm_regread -o "$1" -Mdir "$OUT/v_$1" \
      $R/ymf278_pcm_alu.sv $R/ymf278_pcm_eg_step.sv "$2" \
      rtl/peripheral/SOUND/ymf278b_fpga/tb/tb_pcm_regread.sv > "$OUT/build_$1.log" 2>&1 \
      || { echo "RESULT FAIL: verilator build $1"; grep -E '%Error' "$OUT/build_$1.log" | head -8; exit 1; }
}
build eng "$SRC"
for m in zero nodecode ldport; do build "$m" "$OUT/mut_$m.sv"; done
"$OUT/v_eng/eng" > "$OUT/eng.log" 2>&1
grep -E '^(PASS|FAIL|RESULT|  )' "$OUT/eng.log"
FAIL=0
grep -q '^RESULT: 0 error' "$OUT/eng.log" || FAIL=1
for m in zero nodecode ldport; do
   "$OUT/v_$m/$m" > "$OUT/$m.log" 2>&1
   if grep -q '^RESULT: 0 error' "$OUT/$m.log"; then echo "FAIL  mutant $m passed -- the bench cannot see it"; FAIL=1
   else echo "ok    mutant $m fails: $(grep -c '^FAIL' "$OUT/$m.log") checks ($(grep '^FAIL' "$OUT/$m.log" | head -2 | cut -c7-70 | paste -sd'|'))"; fi
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "PCM REGREAD: PASS" || echo "RESULT FAIL: PCM REGREAD"
exit $FAIL
