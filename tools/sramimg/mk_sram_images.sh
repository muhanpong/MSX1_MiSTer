#!/usr/bin/env bash
#  The blank SRAM file for the MSX1 core (docs/sram_images.md): SRAM.NVR, 2 MB of
#  zeros = 32 entries of 64 kB: six in use (FM-PAC, GameMaster2, Halnote, Panasonic 16 kB,
#  Panasonic 32 kB, RTC settings).  The core mounts it on VD1 through the OSD
#  "SRAM File" entry (SC1); the firmware opens an SC image without creating or
#  growing it, so it must exist at full size.  The core writes an entry header on
#  the first save, so zeros are all that is needed.  createMSXpack.py (next to
#  MSX/, never inside it) and packbuilder.html (its own button) make the same file.
#
#      tools/sramimg/mk_sram_images.sh <dir>      # e.g. /media/fat/games/MSX1/MSX (via sshfs) or a scratch dir
#
#  An existing file is left alone -- it holds saves.  Do NOT make boot1.vhd: the
#  firmware mounts boot<n>.vhd AFTER restoring the SC pick, so a boot1.vhd would
#  take VD1 from the SRAM file (the 2026-09-30 layout used boot1..3.vhd; retired
#  2026-10-04).
set -eu
DIR=${1:?usage: mk_sram_images.sh <dir>}
F="$DIR/SRAM.NVR"
if [ -e "$F" ]; then echo "keep   $F (exists)"; else dd if=/dev/zero of="$F" bs=1024 count=2048 status=none && echo "made   $F (2 MB)"; fi
for n in 1 2 3; do [ -e "$DIR/boot$n.vhd" ] && echo "WARNING $DIR/boot$n.vhd exists -- the firmware mounts it on VD$n over the SC pick"; done
exit 0
