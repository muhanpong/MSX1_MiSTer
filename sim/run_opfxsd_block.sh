#!/usr/bin/env bash
# Replay OPFXSD.COM v1.18's real 8KB block-write sequence through
# mapper_mfrsd1 + flash.sv and check its own DQ7 data-poll.
#
# usage: sim/run_opfxsd_block.sh                       # DSK block 45 (/d1) — the one that dies on hardware
#        BLK=sim/data/dsk_blk44.hex IDX=44 sim/run_opfxsd_block.sh
#        BASE=98 sim/run_opfxsd_block.sh               # same block as /d2 sees it
#        NEGCTL=1 sim/run_opfxsd_block.sh              # drop the 4th byte of every group; MUST fire
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/opfxsd_block_sim}; mkdir -p "$OUT"
BLK=${BLK:-sim/data/dsk_blk45.hex}
IDX=${IDX:-45}
BASE=${BASE:-4}

if [ ! -f "$BLK" ]; then
   echo "missing $BLK -- the block dumps are slices of commercial software and are"
   echo "not committed.  Regenerate them:  python3 sim/data/make_blocks.py"
   exit 1
fi

DEF=""; FLASH="rtl/peripheral/slots/flash.sv"
if [ "${NEGCTL:-0}" = "1" ]; then
   DEF="+define+NEGCTL"; mkdir -p "$OUT/neg"
   sed 's/prog_cnt <= 3.d3;              \/\/ three more bytes after this one/prog_cnt <= 3'"'"'d2;/' \
       "$FLASH" > "$OUT/neg/flash.sv"
   if ! grep -q "prog_cnt <= 3'd2;" "$OUT/neg/flash.sv"; then
      echo "tb_opfxsd_block: NEGCTL could not shorten the program byte count — check the pattern"; exit 1
   fi
   FLASH="$OUT/neg/flash.sv"
fi

verilator --binary --timing -Wno-fatal -Wno-WIDTH $DEF --top-module tb_opfxsd_block \
   -o tb_opfxsd_block -Mdir "$OUT/tb" \
   rtl/package.sv rtl/peripheral/slots/mfrsd.sv "$FLASH" sim/tb_opfxsd_block.sv \
   > "$OUT/build.log" 2>&1 \
   || { echo "tb_opfxsd_block: COMPILE FAILED (see $OUT/build.log)"; tail -30 "$OUT/build.log"; exit 1; }

"$OUT/tb/tb_opfxsd_block" +blk="$BLK" +idx=$IDX +base=$BASE +dbgw=${DBGW:-1AA4} +whi=${WHI:-4} +wlo=${WLO:-6} 2>&1 | grep -vE '^- '
rc=${PIPESTATUS[0]}; echo "rc=$rc"; exit $rc
