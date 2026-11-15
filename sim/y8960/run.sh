#!/bin/bash
# Unit bench of the Y8960 cartridge wrapper.
#   1. the cartridge answers core-style bus cycles (ports off after reset, SSG2 and
#      the OPM sound only after their enablers, register read-backs, mapper, the
#      strobes and volumes that go to the machine's own chips)
#   2. the core clocking (21.477 MHz, enable 1-in-6) gives the same chip outputs
#      as the upstream clocking (42.95 MHz, enable 1-in-12): see cmp_clocking.py
# usage: sim/y8960/run.sh [workdir]
set -e
cd "$(dirname "$0")/../.."
W=${1:-/data/_claude/tmp/y8960_sim}
mkdir -p "$W"
Y=rtl/peripheral/SOUND/y8960
FILES=$(sed -n 's/.*qip_path) \(upstream[^ ]*\.v\) .*/\1/p' $Y/y8960.qip | sed "s|^|$Y/|")
for DIV in 6 12; do
   verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -DTB_DIV=$DIV \
      --top-module tb_y8960 -Mdir "$W/obj$DIV" -o tb \
      sim/y8960/tb_y8960.sv $Y/y8960_cart.sv $FILES > "$W/build$DIV.log" 2>&1 || { tail -30 "$W/build$DIV.log"; exit 1; }
   "$W/obj$DIV/tb" +out="$W/out$DIV.txt" $TBARGS | tee "$W/run$DIV.log" | grep -v "^ok "
done
python3 sim/y8960/cmp_clocking.py "$W/out6.txt" "$W/out12.txt" | tee "$W/cmp.log"
grep -q "CLOCKING PASS" "$W/cmp.log" && grep -q "RESULT PASS" "$W/run6.log" && grep -q "RESULT PASS" "$W/run12.log" && echo "Y8960 UNIT PASS"
