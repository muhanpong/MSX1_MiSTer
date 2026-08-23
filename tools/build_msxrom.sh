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
  sdldz80 -n -i "$SRC.ihx" -b _CODE=0x4000 "$SRC.rel"
  makebin -s 65536 "$SRC.ihx" full.bin )
dd if="$W/full.bin" of="$OUT" bs=1 skip=$((0x4000)) count=$((0x8000)) status=none
printf 'built %s  %s bytes\n' "$OUT" "$(stat -c %s "$OUT")"
printf 'header: '; head -c 16 "$OUT" | od -An -tx1 | tr -s ' '
