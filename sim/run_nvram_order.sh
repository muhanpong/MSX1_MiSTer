#!/usr/bin/env bash
#  nvram_backup never writes the wrong BRAM contents into an image (tb_nvram_order.sv):
#  load before save, nothing during an upload, a mounted image is read, and the
#  save_guard signal spans the whole save.
#      sim/run_nvram_order.sh
#  PASS needs the bench clean AND each mutant to fail its own case:
#    savefirst  -> O1     nobusy  -> O2     nomountload -> O3     guardgap -> O4
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/nvram_order}
rm -rf "$OUT"; mkdir -p "$OUT"
SRC=rtl/nvram_backup.sv
python3 - "$SRC" "$OUT" <<'PY'
import sys
s=open(sys.argv[1]).read(); out=sys.argv[2]
def mut(name, pairs):
    t=s
    for a,b in pairs:
        assert t.count(a)==1, (name, a[:60]); t=t.replace(a,b)
    open(f"{out}/nvram_{name}.sv","w").write(t)
mut("savefirst", [("""         if (request_load[num] & can_load[num]) begin
            rd <= 1'b1;
         end else if (request_save[num] & can_save[num]) begin
            wr <= 1'b1;""","""         if (request_save[num] & can_save[num]) begin
            wr <= 1'b1;
         end else if (request_load[num] & can_load[num]) begin
            rd <= 1'b1;""")])
mut("nobusy", [("   if (upload_busy) rs = 4'b0;\n",""), ("if (~wr & ~rd & ~upload_busy) begin","if (~wr & ~rd) begin")])
mut("nomountload", [("   rl = rl | img_mounted;\n","")])
mut("guardgap", [("assign guard      = (state != STATE_SLEEP) | wr | rd | |(request_save & can_save);","assign guard      = (state != STATE_SLEEP);")])
PY
[ $? -eq 0 ] || { echo "RESULT FAIL: a mutation anchor is missing"; exit 1; }
build() {
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
      -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
      -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
      -Wno-ASCRANGE -Wno-LATCH --public-flat-rw \
      --top-module tb_nvram_order -o "$1" -Mdir "$OUT/v_$1" \
      rtl/package.sv "$2" sim/tb_nvram_order.sv > "$OUT/build_$1.log" 2>&1 \
      || { echo "RESULT FAIL: verilator build $1"; grep -E '%Error' "$OUT/build_$1.log" | head -8; exit 1; }
}
build eng "$SRC"
"$OUT/v_eng/eng" > "$OUT/eng.log" 2>&1
grep -E '^(PASS|FAIL|  O|RESULT)' "$OUT/eng.log"
FAIL=0
grep -q '^RESULT: 0 error' "$OUT/eng.log" || FAIL=1
for m in savefirst:O1 nobusy:O2 nomountload:O3 guardgap:O4; do
   name=${m%%:*}; case_=${m##*:}
   build "$name" "$OUT/nvram_$name.sv"
   "$OUT/v_$name/$name" > "$OUT/$name.log" 2>&1
   n=$(grep -c "^FAIL: $case_" "$OUT/$name.log")
   if [ "$n" -ge 1 ]; then echo "ok    mutant $name fails $case_ ($n checks)"; else echo "FAIL  mutant $name passes $case_ -- the bench cannot see it"; FAIL=1; fi
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "NVRAM ORDER: PASS" || echo "RESULT FAIL: NVRAM ORDER"
exit $FAIL
