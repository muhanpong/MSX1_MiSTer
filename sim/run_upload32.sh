#!/usr/bin/env bash
#  32 MB acceptance for sdram_tdm: does the biggest machine the uploader can build
#  stay below the VRAM bank (24 MB)?  sim/tb_upload32.sv.  (sdram128, 2026-10-13)
#
#    C1  FS-A1GT 4MB DOS2 + FW pack (yrw801) + slot A 8 MB ASCII16X + slot B 8 MB ASCII16X
#    C2  the same, slot A only
#    C3  FS-A1GT DOS2 (512 kB) + FW pack, no carts
#    N1  C3 with the limit at 1 MB: must report OVERFLOWS (the counter works)
#
#  Prints each case's layout and verdict; the verdicts are the measurement, not a
#  pass/fail of the core (a board with one 32 MB chip has always been full at C1).
set -u
cd "$(dirname "$0")/.."
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
OUT=${OUT:-/tmp/upload32}; mkdir -p "$OUT"
PACKS=${PACKS:-/home/sysop/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack}
YRW=$PACKS/ROM/_fromset/yrw801.rom
GT4="$PACKS/MSX/Panasonic/Panasonic FS-A1GT 4MB DOS2.MSX"
GT="$PACKS/MSX/Panasonic/Panasonic FS-A1GT DOS2.MSX"
for f in "$YRW" "$GT4" "$GT"; do [ -s "$f" ] || { echo "RESULT FAIL: missing $f"; exit 2; }; done
python3 - "$OUT" "$YRW" <<'PY'
import sys
out, yrw = sys.argv[1], sys.argv[2]
def hdr(typ, blocks16k):
    h = bytearray(b'MSX'); h += bytes([0, typ, blocks16k >> 8, blocks16k & 255]); return h + bytes(16 - len(h))
y = open(yrw, 'rb').read(); assert len(y) == 0x200000
open(f'{out}/fw.bin', 'wb').write(hdr(8, len(y) >> 14) + y)        # 8 = ROM_MOONSOUND
rom = bytearray((i * 7 + (i >> 14)) & 255 for i in range(0x800000))
rom[0:2] = b'AB'
open(f'{out}/rom8m.bin', 'wb').write(rom)
PY
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY -Wno-ASCRANGE -Wno-LATCH -Wno-ENUMVALUE \
   --top-module tb_upload32 -o tbu -Mdir "$OUT/v" \
   rtl/package.sv rtl/peripheral/slots/memory_upload.sv rtl/peripheral/slots/mapper_detect.sv \
   sim/tb_upload32.sv > "$OUT/build.log" 2>&1 \
   || { echo "RESULT FAIL: build"; grep -E '%Error' "$OUT/build.log" | head; exit 1; }
X16=19     # MAPPER_ASCII16X
"$OUT/v/tbu" "+pack=$GT4" +fw=$OUT/fw.bin +roma=$OUT/rom8m.bin +romb=$OUT/rom8m.bin +mapa=$X16 +mapb=$X16 > $OUT/C1.log 2>&1 &
"$OUT/v/tbu" "+pack=$GT4" +fw=$OUT/fw.bin +roma=$OUT/rom8m.bin +mapa=$X16                              > $OUT/C2.log 2>&1 &
"$OUT/v/tbu" "+pack=$GT"  +fw=$OUT/fw.bin                                                              > $OUT/C3.log 2>&1 &
"$OUT/v/tbu" "+pack=$GT"  +fw=$OUT/fw.bin +limit=100000                                                > $OUT/N1.log 2>&1 &
wait
for c in C1 C2 C3 N1; do
    echo "── $c"; grep -E "^lookup_RAM|^pcm_rom_base|^upload:|^UPLOAD32" $OUT/$c.log | sed 's/^/   /'
done
F=0
grep -q "UPLOAD32 OVERFLOWS" $OUT/N1.log || { echo "FAIL: negative control N1 did not overflow"; F=1; }
grep -q "UPLOAD32 FITS" $OUT/C3.log      || { echo "FAIL: C3 (no carts) does not fit"; F=1; }
[ $F -eq 0 ] && echo "RESULT PASS: bench sound (N1 caught, C3 fits); C1/C2 verdicts above" || echo "RESULT FAIL"
exit $F
