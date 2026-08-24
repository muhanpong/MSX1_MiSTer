#!/usr/bin/env bash
# cart_ascii16x + flash.sv seam: an ordinary cart write must not walk the SHARED
# flash command FSM into CFI.  Yamanooto got this gate (yamanooto.sv:276-277);
# ASCII16X did not (ascii16x.sv:107 `assign flash_rq = cs;`).
#
# usage: sim/run_a16x_cfi.sh
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/a16x_cfi_sim}; mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-WIDTH --top-module tb_a16x_cfi \
   -o tb_a16x_cfi -Mdir "$OUT/tb" \
   rtl/package.sv rtl/peripheral/slots/ascii16x.sv rtl/peripheral/slots/flash.sv sim/tb_a16x_cfi.sv \
   > "$OUT/build.log" 2>&1 \
   || { echo "tb_a16x_cfi: COMPILE FAILED"; tail -25 "$OUT/build.log"; exit 1; }
"$OUT/tb/tb_a16x_cfi" 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
