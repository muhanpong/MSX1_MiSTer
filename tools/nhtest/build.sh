#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
SRC=${1:?usage: build.sh <MSXdev25_NeonHorizon_v1.0.rom> [msx boot sector .dsk]}
BOOT=${2:-/home/sysop/data/aso_orig_plain.dsk}
python3 - "$SRC" <<'PY'
import sys
d=bytearray(open(sys.argv[1],'rb').read())
assert len(d)==8*1024*1024 and d[0:2]==b'AB' and d[0x10:0x18]==b'ASCII16X'
d[0]=d[1]=0                      # no "AB": the BIOS skips it, DOS/BASIC boots
open('NHTEST.ROM','wb').write(d)
t=bytearray()
for p in range(512):
    b=d[p*16384:(p+1)*16384]; s=sum(b)&0xffff; x=0
    for v in b: x^=v
    t+=bytes([s&0xff,s>>8,x])
open('nhtbl.bin','wb').write(t)
PY
/home/sysop/data/knightmare/tools/sjasmplus --raw=nhtest.raw --lst=nhtest.lst nhtest.asm > sj.err 2>&1 || { cat sj.err; exit 1; }
python3 - "$SRC" <<'PY'
r=open('nhtest.raw','rb').read(); st=0xC000; en=st+len(r)-1
open('NHTEST.BIN','wb').write(bytes([0xFE,st&255,st>>8,en&255,en>>8,st&255,st>>8])+r)
print('NHTEST.BIN %04x-%04x (%d bytes)'%(st,en,len(r)))
PY
printf '10 CLEAR 200,&HBFFF\r\n20 BLOAD "NHTEST.BIN",R\r\n' > AUTOEXEC.BAS
rm -f nhtest.dsk; mformat -C -f 720 -v NHTEST -i nhtest.dsk ::
mcopy -i nhtest.dsk NHTEST.BIN AUTOEXEC.BAS ::
#  MSX boot sector: the disk ROM loads sector 0 to C000h and calls C01Eh, so the
#  PC boot code mformat writes would run as Z80 code.  Take an MSX one (same BPB).
python3 - "$BOOT" <<'PY'
import sys
m=open(sys.argv[1],'rb').read(512)
d=bytearray(open('nhtest.dsk','rb').read())
assert m[11:28]==d[11:28]
d[0:512]=m
open('nhtest.dsk','wb').write(d)
PY
mdir -i nhtest.dsk ::
