#!/bin/sh
# Build vdptools.rom from the V9968 Cartridge test programs.
#   ./build.sh [V9968_Cartridge clone] [revision]
# Needs sjasmplus (SJASMPLUS=path) and python3.
set -e
cd "$(dirname "$0")"
REPO=${1:-$HOME/data/V9968_Cartridge}
REV=${2:-453d5f3}
SJ=${SJASMPLUS:-$HOME/data/knightmare/tools/sjasmplus}
mkdir -p com
for f in VDPCHK/VDPCHK.COM VDPCHK/VDPREG.COM VDPVIEW/VDPVIEW.COM VDPVIEW/VDPINT.COM \
         VDPVIEW/VDPDIAG.COM VRAMSTRS/VRAMSTRS.COM VDPTEST.COM VRAMRW.COM; do
    git -C "$REPO" show "$REV:test/$f" > "com/$(basename $f)"
done
git -C "$REPO" show "$REV:LICENSE" > com/LICENSE
python3 pack.py                       # banks.inc
"$SJ" --nologo --sym=vdptools.sym vdptools.asm
python3 pack.py --rom                 # vdptools.rom
python3 detect.py vdptools.rom        # must say ASCII16 (the MiSTer core's auto detection)
python3 detect.py vdptools.rom | grep -q -- "-> ASCII16$"
md5sum vdptools.rom
