#!/bin/bash
# MFRSD SD pacing bench: old (read-only pacer) vs new (pending requests + hold).
# Expect: old turbo dropped>0 (negative control), new dropped=0, cmp mismatches=0.
set -e; cd "$(dirname "$0")"; R=../..
python3 - <<'PY'
s=open('../../rtl/peripheral/slots/mfrsd.sv').read()
i=s.index('module mapper_mfrsd3'); j=s.index('endmodule', i)+len('endmodule')
open('mfrsd3_new.sv','w').write(s[i:j]+'\n')
PY
verilator --binary --timing -j 8 -O2 --top-module tb -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-BLKSEQ \
  -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-IMPLICIT --Mdir obj -o tb \
  tb_sdpace.sv mfrsd3_new.sv mfrsd3_old.sv $R/rtl/peripheral/spi_divmmc.sv > build.log 2>&1
for d in 0 1; do for t in 1 0; do ./obj/tb +design=$d +turbo=$t | grep design=; done; done
./obj/tb +cmp=1 +turbo=0 | grep CMP
