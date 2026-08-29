#!/usr/bin/env bash
# Does msx_device survive a SLOT A/B ROM load?  See docs/TODO_msx_device_leak.md.
#   (default)          the shipped RTL -- no clear in the load block
#   CLEARFIX=1         models the reverted one-line "fix" (msx_device <= '0)
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/devreload_sim}; mkdir -p "$OUT"
SRC=rtl/peripheral/slots/memory_upload.sv
WORK="$OUT/memory_upload.sv"
if [ "${CLEARFIX:-0}" = "1" ]; then
   python3 - "$SRC" "$WORK" <<'PY'
import sys
s=open(sys.argv[1]).read()
a="         cart_device           <= '{0, 0};"
assert a in s
open(sys.argv[2],'w').write(s.replace(a, a+"\n         msx_device            <= '0;",1))
PY
else
   cp "$SRC" "$WORK"
fi
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-ENUMVALUE \
   --top-module tb_device_reload -o tbdevrl -Mdir "$OUT/v" \
   rtl/package.sv sim/tb_device_reload.sv "$WORK" rtl/peripheral/slots/mapper_detect.sv > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -30 "$OUT/build.log"; exit 2; }
"$OUT/v/tbdevrl" 2>&1 | grep -vE '^(CONF|  (LOAD|ADD|STORE|SLOT|CONFIG)|     ADD)'
exit ${PIPESTATUS[0]}
