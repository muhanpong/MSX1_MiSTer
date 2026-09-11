#!/usr/bin/env bash
# Assemble CEPROBE.COM and wrap it in a bootable MSX-DOS disk.
#   usage: tools/ceprobe/build_ceprobe.sh
# Output: tools/ceprobe/CEPROBE.COM and CEPROBE.DSK
#
# The .COM is linked at 0x0100 like any MSX-DOS program.  Its length comes from
# the hex records rather than from scanning the binary: makebin pads with 0xFF,
# so "last non-zero byte" would report the whole 64 KB.
set -eu
cd "$(dirname "$0")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp ceprobe.s "$W/"
( cd "$W"
  sdasz80 -l -o ceprobe.rel ceprobe.s
  sdldz80 -n -i ceprobe.ihx -b _CODE=0x100 ceprobe.rel
  makebin -s 65536 ceprobe.ihx full.bin )
SIZE=$(python3 ihx_size.py "$W/ceprobe.ihx")
dd if="$W/full.bin" of=CEPROBE.COM bs=1 skip=$((0x100)) count="$SIZE" status=none
echo "CEPROBE.COM: $SIZE bytes"
python3 ../mkdsk/mkmsxdsk.py CEPROBE.DSK --label CEPROBE --autoexec "CEPROBE" CEPROBE.COM | tail -2
