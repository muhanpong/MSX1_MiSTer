#!/usr/bin/env bash
#  A failed firmware search leaves save_addr set, and the rest of the pack is
#  never recognised.  Case A is a machine with no firmware pack loaded; case B
#  is the same pack with one in the store.  See sim/tb_fwsearch.sv.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/fwsearch_sim}; mkdir -p "$OUT"
SRC=rtl/peripheral/slots/memory_upload.sv
if [ "${NOFIX:-0}" = "1" ]; then     # model the shipped-before behaviour
   WORK="$OUT/memory_upload.sv"
   #  argv, not interpolation: the first version of this escaped $SRC into the python
   #  string and opened a file literally named "$SRC", so NOFIX silently stopped being
   #  a negative control.  sim/checkrun.sh caught it.
   python3 - "$SRC" "$WORK" <<'PY'
import re, sys
src, work = sys.argv[1], sys.argv[2]
s = open(src).read()
#  undo both corrections at the two firmware-search return sites
a = "ddr3_addr <= save_addr - 28'd1;"
assert s.count(a) == 2, s.count(a)
s = s.replace(a, "ddr3_addr <= save_addr;")
n = len(re.findall(r"save_addr <= 28'd0;   // ", s))
assert n == 2, n
s = re.sub(r" *save_addr <= 28'd0;   // [^\n]*\n( +// [^\n]*\n)*", "", s)
open(work, "w").write(s)
PY
   [ -s "$WORK" ] || { echo "RESULT FAIL: NOFIX could not build the old source"; exit 1; }
   SRC="$WORK"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY \
   -Wno-ASCRANGE -Wno-LATCH -Wno-ENUMVALUE \
   --top-module tb_fwsearch -o tbfw -Mdir "$OUT" \
   rtl/package.sv "$SRC" sim/tb_fwsearch.sv rtl/peripheral/slots/mapper_detect.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: verilator build"; grep -E '%Error' "$OUT/build.log" | head -10; exit 1; }
 "$OUT/tbfw" | grep -E 'FILL FW|FIND|ok |FAIL|RESULT|  [0AB]:|ADD DEVICE|STORE CONFIG'
