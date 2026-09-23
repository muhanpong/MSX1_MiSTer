#!/usr/bin/env bash
#  nvram_backup: a LOAD request arriving inside the stretched machine reset must
#  survive it (the .sav a ROM load asks for).  See sim/tb_nvram_load_reset.sv.
#
#      sim/run_nvram_load_reset.sh          # the fixed RTL
#      NVRAM_SRC=/path/old.sv sim/run_nvram_load_reset.sh   # negative control
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/nvram_load_reset}
SRC=${NVRAM_SRC:-rtl/nvram_backup.sv}
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   -Wno-ASCRANGE \
   --top-module tb_nvram_load_reset -o tbnv -Mdir "$OUT" \
   rtl/package.sv "$SRC" sim/tb_nvram_load_reset.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
[ -x "$OUT/tbnv" ] || { echo "RESULT FAIL: no binary"; exit 1; }
"$OUT/tbnv" | grep -E 'PASS|FAIL|RESULT'
