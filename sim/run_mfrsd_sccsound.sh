#!/usr/bin/env bash
# MFRSD subslot 1 -> scc_sound -> IKASCC.  tb_mfrsd_sccmode checks the VALUE of
# scc_mode; this checks what that value does to the chip, which is where the
# real defect was (mode collapsing between bus accesses).
#   usage: sim/run_mfrsd_sccsound.sh   |   NEGCTL=1 sim/run_mfrsd_sccsound.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/mfrsd_sccsound_sim}; mkdir -p "$OUT"
DEF=""; SRC="rtl/peripheral/slots/mfrsd.sv"
if [ "${NEGCTL:-0}" = "1" ]; then
   DEF="+define+NEGCTL"; mkdir -p "$OUT/neg"
   # restore the pre-cc183c9 export: the window enable instead of the MODE
   sed 's/assign scc_mode     = sccMode\[5\] & sccBanks\[3\]\[7\];/assign scc_mode     = EN_SCCPLUS;/' \
       "$SRC" > "$OUT/neg/mfrsd.sv"
   if ! grep -q 'assign scc_mode     = EN_SCCPLUS;' "$OUT/neg/mfrsd.sv"; then
      echo "NEGCTL could not restore the old export"; exit 1; fi
   SRC="$OUT/neg/mfrsd.sv"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME $DEF \
   --top-module tb_mfrsd_sccsound -o tb -Mdir "$OUT/tb" \
   sim/tb_mfrsd_sccsound.sv rtl/package.sv "$SRC" \
   rtl/peripheral/slots/scc_sound.sv \
   rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v \
   rtl/IKASCC/src/IKASCC_modules/IKASCC_primitives.v > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -15 "$OUT/build.log"; exit 1; }
"$OUT/tb/tb" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
