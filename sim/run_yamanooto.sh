#!/usr/bin/env bash
# Yamanooto mapper TB (docs/yamanooto_spec.md).  Verilator: the RTL uses
# SystemVerilog unpacked arrays that iverilog 13 chokes on elsewhere in this repo.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/yama_sim}
mkdir -p "$OUT"
verilator --binary --timing --top-module tb_yamanooto \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
   --Mdir "$OUT/v" -o tbyama \
   sim/tb_yamanooto.sv rtl/package.sv rtl/peripheral/slots/yamanooto.sv \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; tail -30 "$OUT/build.log"; exit 2; }
"$OUT/v/tbyama" 2>&1 | tee "$OUT/run.log" | grep -E '^(FAIL|RESULT|TIMEOUT|   )'
rc=0
grep -q '^RESULT: [0-9]* passed, 0 failed' "$OUT/run.log" || rc=1

if [ "${NEGCTL:-0}" = "1" ]; then
   # A TB that cannot fail proves nothing.  Re-inject the two defects openMSX actually has
   # (issue #1992 "512KB boundary", issue #1964 "RAM mode") and require the TB to catch them.
   echo; echo "### negative control (openMSX #1992 + #1964 re-injected)"
   B="$OUT/buggy"; rm -rf "$B"; mkdir -p "$B"
   cp rtl/package.sv rtl/peripheral/slots/yamanooto.sv "$B/"
   python3 - "$B/yamanooto.sv" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
subs = [
 ("? ( rawBank[cart_num][3][7]", "? ( bankReg[cart_num][3][7]"),
 (": ((rawBank[cart_num][2][5:0] == 6'h3F)", ": ((bankReg[cart_num][2][5:0] == 6'h3F)"),
 ("wire        scc_on       = ~|(cfgr & K4) & ~scc_ram_mode;",
  "wire        scc_on       = ~|(cfgr & K4);"),
]
for o, n in subs:
    assert s.count(o) == 1, "negative control is stale: " + o[:40]
    s = s.replace(o, n)
open(p, 'w').write(s)
PY2
   verilator --binary --timing --top-module tb_yamanooto       -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME       --Mdir "$OUT/vbug" -o tbbug sim/tb_yamanooto.sv "$B/package.sv" "$B/yamanooto.sv"       > "$OUT/negbuild.log" 2>&1 || { echo "COMPILE FAILED"; exit 2; }
   "$OUT/vbug/tbbug" 2>&1 | tee "$OUT/neg.log" | grep -E '^(FAIL|RESULT)'
   if grep -q '^RESULT: [0-9]* passed, 0 failed' "$OUT/neg.log"; then
      echo "NEGCTL: *** TB DID NOT CATCH THE RE-INJECTED DEFECTS ***"; rc=1
   else
      echo "NEGCTL: ok (both caught)"
   fi
fi
exit $rc
