#!/usr/bin/env bash
# TURBOR_FDC block: mapper_msxdos2 (7FF0-only window) + fdc (WD2793, Sony layout)
# sharing one page-1 window.  See tools/turbor_diskrom/README.md.
# Two benches: the mapper alone (openMSX RomMSXDOS2 / TurboRFDC semantics, iverilog)
# and the pair together (verilator).  wd1793.sv is taken from sim/fullsys/gen/sv,
# the prep.sh rewrite: the RTL copy declares spt_addr only under EDSK and both
# simulators reject its constant-false use (Quartus does not).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/trfdc_sim}; mkdir -p "$OUT"
rc=0
[ -f sim/fullsys/gen/sv/wd1793.sv ] || sim/fullsys/prep.sh > /dev/null || { echo "prep.sh failed"; exit 2; }
sim/run_msxdos2.sh | tail -2 | grep -q PASSED || { echo "FAIL: tb_msxdos2"; rc=1; }
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-CASEINCOMPLETE \
   --top-module tb_trfdc -o tb -Mdir "$OUT/v" \
   sim/tb_trfdc.sv rtl/peripheral/slots/fdc.sv rtl/peripheral/slots/msxdos2.sv sim/fullsys/gen/sv/wd1793.sv \
   > "$OUT/build.log" 2>&1 || { echo "COMPILE FAILED: tb_trfdc"; tail -20 "$OUT/build.log"; exit 2; }
"$OUT/v/tb" 2>&1 | grep -vE '^- ' | tee "$OUT/run.log" | tail -3
grep -q '^PASSED' "$OUT/run.log" || rc=1
echo "rc=$rc"; exit $rc
