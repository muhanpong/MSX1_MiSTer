#!/usr/bin/env bash
# Assemble one of the .s test carts into a 32KB MSX ROM image.
#   usage: tools/build_msxrom.sh yamanooto_savetest [out.rom]
# The cart is linked at 0x4000 (page 1) and padded to 32KB, so it occupies
# pages 1+2 and leaves 0xC000-0xFFFF as RAM for the resident routine.
set -eu
cd "$(dirname "$0")"
SRC="${1:?usage: build_msxrom.sh <name-without-.s> [out.rom]}"
SRC="${SRC%.s}"
OUT="$(realpath -m "${2:-$SRC.rom}")"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$SRC.s" "$W/"
( cd "$W"
  sdasz80 -l -o "$SRC.rel" "$SRC.s"
  # _RESID is linked for 0xC000 because it EXECUTES there -- copying position
  # dependent code is not enough, its call/jp targets must resolve to RAM.
  sdldz80 -n -i "$SRC.ihx" -b _CODE=0x4000 -b _RESID=0xC000 "$SRC.rel"
  makebin -s 65536 "$SRC.ihx" full.bin )
dd if="$W/full.bin" of="$OUT" bs=1 skip=$((0x4000)) count=$((0x8000)) status=none
# stage the 0xC000 blob into the cart at offset 0x2000 (CPU 0x6000) so init can
# copy it; without this the cart would contain no copy of the routine at all.
if [ -s "$W/full.bin" ]; then
   dd if="$W/full.bin" of="$OUT" bs=1 skip=$((0xC000)) seek=$((0x2000)) \
      count=$((0x1000)) conv=notrunc status=none
fi
printf 'built %s  %s bytes\n' "$OUT" "$(stat -c %s "$OUT")"
printf 'header: '; head -c 16 "$OUT" | od -An -tx1 | tr -s ' '
