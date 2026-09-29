#!/usr/bin/env bash
#  nvram_backup image layout: VD0 raw, VD1..3 one 64 kB entry per SRAM kind with
#  a header sector (docs/sram_images.md).  See sim/tb_nvram_layout.sv.
#
#      sim/run_nvram_layout.sh
#
#  PASS needs the bench clean AND the mutant (data base LBA 128n + 9 instead of
#  + 8) to FAIL -- a bench that cannot see a one-sector offset error is not
#  testing the layout.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/nvram_layout}
rm -rf "$OUT"; mkdir -p "$OUT"
sed -e "s/lba_base + 32'd8 : 32'd0;/lba_base + 32'd9 : 32'd0;/" rtl/nvram_backup.sv > "$OUT/nvram_mut.sv"
cmp -s rtl/nvram_backup.sv "$OUT/nvram_mut.sv" && { echo "RESULT FAIL: mutant identical to source"; exit 1; }
build() {
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
      -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
      -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
      -Wno-ASCRANGE -Wno-LATCH --public-flat-rw \
      --top-module tb_nvram_layout -o "$1" -Mdir "$OUT/v_$1" \
      rtl/package.sv "$2" sim/tb_nvram_layout.sv > "$OUT/build_$1.log" 2>&1 \
      || { echo "RESULT FAIL: verilator build $1"; grep -E '%Error' "$OUT/build_$1.log" | head -8; exit 1; }
   [ -x "$OUT/v_$1/$1" ] || { echo "RESULT FAIL: no binary $1"; exit 1; }
}
build eng rtl/nvram_backup.sv
build mut "$OUT/nvram_mut.sv"
"$OUT/v_eng/eng" > "$OUT/eng.log" 2>&1; ENG=$?
"$OUT/v_mut/mut" > "$OUT/mut.log" 2>&1; MUT=$?
grep -E '^(PASS|FAIL|RESULT)' "$OUT/eng.log"
FAIL=0
grep -q '^RESULT: 0 error' "$OUT/eng.log" || FAIL=1
if grep -q '^RESULT: 0 error' "$OUT/mut.log"; then echo "FAIL  mutant (data base +9) passed -- the bench cannot see a one-sector offset"; FAIL=1; else echo "ok    mutant (data base +9) fails: $(grep -c '^FAIL' "$OUT/mut.log") checks"; fi
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "NVRAM LAYOUT: PASS" || echo "RESULT FAIL: NVRAM LAYOUT"
exit $FAIL
