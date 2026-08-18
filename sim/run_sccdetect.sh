#!/usr/bin/env bash
# SCC/SCC+ *detection* TB runner (docs/sccplus_spec.md S3b)
#
# Puts cart_konami_scc in the loop, so the chain
#     CPU write -> mapper (0x9000 / 0xB000 / 0xBFFE) -> scc_req / scc_mode -> scc_sound
# is exercised end to end.  tb_sccplus.sv forces sccPlusChip/sccPlusMode instead and
# therefore covers none of this.
#
# Verilator, not Icarus: iverilog 13 chokes on konami_scc.sv:25
#   bank <= '{'{'h00,'h01,'h02,'h03},'{...}}   ("cannot evaluate VEC4 expression")
# and the RTL must not be reshaped just to please a simulator.
#
# usage: sim/run_sccdetect.sh          normal run
#        NEGCTL=1 sim/run_sccdetect.sh also re-inject the 2026-08-18 Compat ch5 bug into
#                                      a scratch copy and assert the TB still catches it
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/sccplus_sim}
mkdir -p "$OUT"

RTL=(rtl/peripheral/slots/konami_scc.sv
     rtl/peripheral/slots/scc_sound.sv
     rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v
     rtl/IKASCC/src/IKASCC_modules/IKASCC_primitives.v)
VFLAGS=(--binary --timing --top-module tb_sccdetect
        -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME)

rc=0
echo "### working tree RTL"
verilator "${VFLAGS[@]}" --Mdir "$OUT/vdet" -o tbdet sim/tb_sccdetect.sv "${RTL[@]}" > "$OUT/detect.build" 2>&1 \
   || { echo "COMPILE FAILED (see $OUT/detect.build)"; exit 2; }
"$OUT/vdet/tbdet" 2>&1 | tee "$OUT/detect.log" | grep -E '^(FAIL|RESULT|---|TIMEOUT)'
grep -q '^RESULT: [0-9]* passed, 0 failed' "$OUT/detect.log" || rc=1

if [ "${NEGCTL:-0}" = "1" ]; then
   # Negative control: a TB that cannot fail proves nothing.  Re-inject the exact defect
   # fixed on 2026-08-18 (ch5 private RAM enabled in Compatible mode) and require a FAIL.
   echo
   echo "### negative control (bug re-injected)"
   B="$OUT/buggy"; rm -rf "$B"; mkdir -p "$B"; cp "${RTL[@]}" "$B/"
   sed -i "s|wire            sccp_ch5_indep = (i_SCCP_MODE == 2'd2);.*|wire            sccp_ch5_indep = \|i_SCCP_MODE;|" \
      "$B/IKASCC_player_s.v"
   python3 - "$B/scc_sound.sv" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """         2'd1: case (a[7:5])
                  3'b101:  scc_ablo_remap = rd ? {3'b011, a[4:0]} : {3'b110, a[4:0]};
                  3'b110:  scc_ablo_remap = {3'b111, a[4:0]};
                  default: ;
               endcase"""
new = """         2'd1: if (a[7:5] == 3'b110) scc_ablo_remap = {3'b111, a[4:0]};"""
assert s.count(old) == 1, "remap block not found - negative control is stale"
open(p, 'w').write(s.replace(old, new))
PY
   verilator "${VFLAGS[@]}" --Mdir "$OUT/vbug" -o tbbug sim/tb_sccdetect.sv \
      "$B/konami_scc.sv" "$B/scc_sound.sv" "$B/IKASCC_player_s.v" "$B/IKASCC_primitives.v" \
      > "$OUT/neg.build" 2>&1 || { echo "COMPILE FAILED (see $OUT/neg.build)"; exit 2; }
   "$OUT/vbug/tbbug" 2>&1 | tee "$OUT/neg.log" | grep -E '^(FAIL|RESULT)'
   if grep -q '^RESULT: [0-9]* passed, 0 failed' "$OUT/neg.log"; then
      echo "NEGCTL: *** TB DID NOT CATCH THE RE-INJECTED BUG - it has no detection power ***"
      rc=1
   else
      echo "NEGCTL: ok (bug caught)"
   fi
fi
exit $rc
