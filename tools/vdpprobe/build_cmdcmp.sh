#!/usr/bin/env bash
# Assemble CMDCMP.COM and wrap it in a bootable MSX-DOS disk.
#   usage: tools/cmdcmp/build_cmdcmp.sh
# Output: tools/cmdcmp/CMDCMP.COM and CMDCMP.DSK
#
# The .COM is linked at 0x0100 like any MSX-DOS program.  Its length comes from
# the hex records rather than from scanning the binary: makebin pads with 0xFF,
# so "last non-zero byte" would report the whole 64 KB.
set -eu
cd "$(dirname "$0")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp cmdcmp.s "$W/"
( cd "$W"
  sdasz80 -l -o cmdcmp.rel cmdcmp.s
  sdldz80 -n -i cmdcmp.ihx -b _CODE=0x100 cmdcmp.rel
  makebin -s 65536 cmdcmp.ihx full.bin )
SIZE=$(python3 ihx_size.py "$W/cmdcmp.ihx")
dd if="$W/full.bin" of=CMDCMP.COM bs=1 skip=$((0x100)) count="$SIZE" status=none
echo "CMDCMP.COM: $SIZE bytes"
python3 ../mkdsk/mkmsxdsk.py CMDCMP.DSK --label CMDCMP --autoexec "CMDCMP" CMDCMP.COM | tail -2
