#!/usr/bin/env bash
#  Blank SRAM images for the MSX1 core (docs/sram_images.md).  The MiSTer
#  firmware auto-mounts games/MSX1/boot1.vhd .. boot3.vhd on VD1..VD3 at core
#  start; the core writes an entry header on the first save, so zero-filled
#  files are all that is needed.  boot0.vhd is deliberately NOT made: VD0 is
#  the slot A ROM's companion .sav, which the firmware creates itself.
#
#      tools/sramimg/mk_sram_images.sh <dir>      # e.g. /media/fat/games/MSX1 (via sshfs) or a scratch dir
#
#  Sizes = entries x 64 kB:  VD1 2 entries (FM-PAC, GameMaster2) 128 kB,
#  VD2 1 entry (FM-PAC) 64 kB, VD3 3 entries (Halnote, FS-A1ST, FS-A1GT) 192 kB.
#  Existing files are left alone.
set -eu
DIR=${1:?usage: mk_sram_images.sh <dir>}
mk() { if [ -e "$DIR/$1" ]; then echo "keep   $DIR/$1 (exists)"; else dd if=/dev/zero of="$DIR/$1" bs=1024 count="$2" status=none && echo "made   $DIR/$1 ($2 kB)"; fi; }
mk boot1.vhd 128
mk boot2.vhd 64
mk boot3.vhd 192
