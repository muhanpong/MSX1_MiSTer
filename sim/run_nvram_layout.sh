#!/usr/bin/env bash
#  nvram_backup image layout and autosave: VD0 raw, VD1 = the SRAM file with one
#  64 kB entry per SRAM kind (entry = kind - 1) and a header sector, slot A over
#  slot B on a shared kind, the RTC bank, and autosave on write
#  (docs/sram_images.md).  See sim/tb_nvram_layout.sv.
#
#      sim/run_nvram_layout.sh
#
#  PASS needs the bench clean AND every mutant to FAIL -- each one removes one
#  rule the bench claims to check:
#     data+9      data base LBA 128n + 9 instead of + 8 (a one-sector offset)
#     nopriority  slot B's FM-PAC/GM2 no longer yields entry 0/1 to slot A's
#     noquiet     autosave never fires on quiet (age and flush only)
#     noflush     flush does not save at once
#     nodrop      an upload does not drop what was dirty
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/nvram_layout}
rm -rf "$OUT"; mkdir -p "$OUT"
SRC=rtl/nvram_backup.sv
mutate() {   # name, sed expression
   sed -e "$2" "$SRC" > "$OUT/mut_$1.sv"
   cmp -s "$SRC" "$OUT/mut_$1.sv" && { echo "RESULT FAIL: mutant $1 identical to source"; exit 1; }
}
mutate data9      "s/lba_base + 32'd8 : 32'd0;/lba_base + 32'd9 : 32'd0;/"
mutate nopriority "s/(bk_kind\[m\] == bk_kind\[n\])) eligible\[n\] = 1'b0;/(bk_kind[m] == bk_kind[n])) eligible[n] = eligible[n];/"
mutate noquiet    "s/(quiet\[QUIET_BITS-1\] | age\[AGE_BITS-1\]/(1'b0 | age[AGE_BITS-1]/"
mutate noflush    "s/| (flush \& ~flush_q));/| 1'b0);/"
mutate nodrop     "s/if (upload_busy | ~autosave_en) begin/if (~autosave_en) begin/"
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
build eng "$SRC"
for m in data9 nopriority noquiet noflush nodrop; do build "$m" "$OUT/mut_$m.sv"; done
"$OUT/v_eng/eng" > "$OUT/eng.log" 2>&1
grep -E '^(PASS|FAIL|RESULT)' "$OUT/eng.log"
FAIL=0
grep -q '^RESULT: 0 error' "$OUT/eng.log" || FAIL=1
for m in data9 nopriority noquiet noflush nodrop; do
   "$OUT/v_$m/$m" > "$OUT/$m.log" 2>&1
   if grep -q '^RESULT: 0 error' "$OUT/$m.log"; then
      echo "FAIL  mutant $m passed -- the bench cannot see that rule"; FAIL=1
   else
      echo "ok    mutant $m fails: $(grep -c '^FAIL' "$OUT/$m.log") checks ($(grep '^FAIL' "$OUT/$m.log" | head -2 | cut -c7-60 | paste -sd'|'))"
   fi
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "NVRAM LAYOUT: PASS" || echo "RESULT FAIL: NVRAM LAYOUT"
exit $FAIL
