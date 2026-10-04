#!/usr/bin/env bash
#  RTC settings memory second port + mem_dirty (rtc.vhd).  See sim/tb_rtc_nvport.sv.
#      sim/run_rtc_nvport.sh
#  Runs on the ghdl netlist of rtc.vhd (sim/fullsys/prep.sh writes gen/rtc.v; it
#  is regenerated here when rtc.vhd is newer).  PASS needs the bench clean AND the
#  mutant (mem_dirty on every memory write, block and register ignored) to fail R4.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/rtc_nvport}
rm -rf "$OUT"; mkdir -p "$OUT"
GEN=sim/fullsys/gen/rtc.v
if [ ! -s "$GEN" ] || [ rtl/peripheral/rtc.vhd -nt "$GEN" ]; then
   sim/fullsys/prep.sh > "$OUT/prep.log" 2>&1 || { echo "RESULT FAIL: fullsys prep"; tail -5 "$OUT/prep.log"; exit 1; }
fi
#  the mutant: the same netlist made from an rtc.vhd whose mem_dirty ignores block and register
mkdir -p "$OUT/mut"
sed -e "s/mem_dirty   <=  '1' when( w_mem_we = '1' and reg_mode(1) = '1' and reg_ptr <= \"1100\" )else/mem_dirty   <=  '1' when( w_mem_we = '1' )else/" \
   rtl/peripheral/rtc.vhd > "$OUT/mut/rtc.vhd"
cmp -s rtl/peripheral/rtc.vhd "$OUT/mut/rtc.vhd" && { echo "RESULT FAIL: mutant identical to source"; exit 1; }
( cd "$OUT/mut" && ghdl -a --std=08 -frelaxed -fsynopsys rtc.vhd 2> ghdl.log && ghdl synth --std=08 -frelaxed -fsynopsys --latches --out=verilog rtc > rtc.v 2>> ghdl.log ) \
   || { echo "RESULT FAIL: ghdl mutant"; tail -5 "$OUT/mut/ghdl.log"; exit 1; }
build() {
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
      -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-PINMISSING \
      --top-module tb_rtc_nvport -o "$1" -Mdir "$OUT/v_$1" "$2" sim/tb_rtc_nvport.sv > "$OUT/build_$1.log" 2>&1 \
      || { echo "RESULT FAIL: verilator build $1"; grep -E '%Error' "$OUT/build_$1.log" | head -8; exit 1; }
}
build eng "$GEN"
build mut "$OUT/mut/rtc.v"
"$OUT/v_eng/eng" > "$OUT/eng.log" 2>&1
grep -E '^(PASS|FAIL|RESULT)' "$OUT/eng.log"
FAIL=0
grep -q '^RESULT: 0 error' "$OUT/eng.log" || FAIL=1
"$OUT/v_mut/mut" > "$OUT/mut.log" 2>&1
if grep -q '^FAIL: R4' "$OUT/mut.log"; then echo "ok    mutant (dirty on every write) fails R4"; else echo "FAIL  mutant passes R4 -- the bench cannot see it"; FAIL=1; fi
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "RTC NVPORT: PASS" || echo "RESULT FAIL: RTC NVPORT"
exit $FAIL
