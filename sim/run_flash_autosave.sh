#!/usr/bin/env bash
#  flash_dirtysave: autosave gating, the dirty_new lifecycle, and (T6) that a LOAD
#  request arriving inside the stretched machine reset survives it.
#
#      sim/run_flash_autosave.sh
set -eu
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/flash_autosave}
rm -rf "$OUT"; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   --top-module tb_flash_autosave -o tbfa -Mdir "$OUT" \
   rtl/flash_dirtysave.sv sim/tb_flash_autosave.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
[ -x "$OUT/tbfa" ] || { echo "RESULT FAIL: no binary"; exit 1; }
"$OUT/tbfa" | grep -E 'PASS|FAIL|RESULT'
