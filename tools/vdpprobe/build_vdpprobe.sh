#!/usr/bin/env bash
# Assemble VDPPROBE.COM and wrap it in a bootable MSX-DOS disk.
#   usage: tools/vdpprobe/build_vdpprobe.sh
# Output: tools/vdpprobe/VDPPROBE.COM and VDPPROBE.DSK
#
# The .COM is linked at 0x0100 like any MSX-DOS program.  Its length comes from
# the hex records rather than from scanning the binary: makebin pads with 0xFF,
# so "last non-zero byte" would report the whole 64 KB.
set -eu
cd "$(dirname "$0")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp vdpprobe.s "$W/"
( cd "$W"
  sdasz80 -l -o vdpprobe.rel vdpprobe.s
  sdldz80 -n -i vdpprobe.ihx -b _CODE=0x100 vdpprobe.rel
  makebin -s 65536 vdpprobe.ihx full.bin )
SIZE=$(python3 ihx_size.py "$W/vdpprobe.ihx")
dd if="$W/full.bin" of=VDPPROBE.COM bs=1 skip=$((0x100)) count="$SIZE" status=none
echo "VDPPROBE.COM: $SIZE bytes"
python3 ../mkdsk/mkmsxdsk.py VDPPROBE.DSK --label VDPPROBE --autoexec "VDPPROBE" VDPPROBE.COM | tail -2
