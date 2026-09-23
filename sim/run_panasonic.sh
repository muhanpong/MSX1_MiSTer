#!/usr/bin/env bash
# Panasonic firmware mapper (turbo R slot 3-3): openMSX RomPanasonic.cc semantics.
# Verilator 4 (no --timing): the clock comes from sim_panasonic.cpp.
# See docs/panasonic_mapper.md.
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/panasonic_sim}; mkdir -p "$OUT"
verilator --cc --exe --build -j 4 -O2 +1800-2012ext+sv -Wno-fatal -Wno-lint -Wno-style \
   --top-module tb -Mdir "$OUT/v" -o tb \
   sim/tb_panasonic.sv rtl/peripheral/slots/panasonic.sv "$PWD/sim/sim_panasonic.cpp" \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED"; tail -25 "$OUT/build.log"; exit 2; }
"$OUT/v/tb" 2>&1 | tee "$OUT/run.log" | tail -8
grep -q '^PASSED' "$OUT/run.log" && exit 0 || exit 1
