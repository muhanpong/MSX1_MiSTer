#!/usr/bin/env bash
#  32 MB acceptance for sdram_tdm: does the biggest machine the uploader can build
#  stay below the VRAM bank (24 MB)?  sim/tb_upload32.sv.  (sdram128, 2026-10-13)
#
#    C1  FS-A1GT 4MB DOS2 + FW pack (yrw801) + slot A 8 MB ASCII16X + slot B 8 MB ASCII16X
#    C2  the same, slot A only
#    C3  FS-A1GT DOS2 (512 kB) + FW pack, no carts
#    N1  C3 with the limit at 1 MB: must report OVERFLOWS (the counter works)
#    P32 C1 on a 32 MB board: RAM capped at 2 MB, fits below 24 MB (C1 itself, run
#        as before on sdram_size 1 with the cap, is the same case: see its RAM line)
#    P64 C1 on a 64 MB board: RAM stays 4 MB, fits below 32 MB
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
#  2026-10-13 policy: the machine RAM is 2 MB at most on a 32 MB board, 4 MB on 64 MB+
#  (a 64 MB board moves 24-32 MB out of the VRAM bank in sdram_tdm, so its limit is 32 MB)
"$OUT/v/tbu" "+pack=$GT4" +fw=$OUT/fw.bin +roma=$OUT/rom8m.bin +romb=$OUT/rom8m.bin +mapa=$X16 +mapb=$X16 +sdsz=1             > $OUT/P32.log 2>&1 &
"$OUT/v/tbu" "+pack=$GT4" +fw=$OUT/fw.bin +roma=$OUT/rom8m.bin +romb=$OUT/rom8m.bin +mapa=$X16 +mapb=$X16 +sdsz=2 +limit=2000000 > $OUT/P64.log 2>&1 &
wait
for c in C1 C2 C3 N1 P32 P64; do
    echo "── $c"; grep -E "^lookup_RAM|^pcm_rom_base|^upload:|^UPLOAD32" $OUT/$c.log | sed 's/^/   /'
done
F=0
grep -q "UPLOAD32 OVERFLOWS" $OUT/N1.log || { echo "FAIL: negative control N1 did not overflow"; F=1; }
grep -q "UPLOAD32 FITS" $OUT/C3.log      || { echo "FAIL: C3 (no carts) does not fit"; F=1; }
grep -q "UPLOAD32 FITS" $OUT/P32.log && grep -q "RAM mapper: 128 x" $OUT/P32.log || { echo "FAIL: P32 -- 32 MB board, 4 MB pack: RAM not capped to 2 MB or does not fit"; F=1; }
grep -q "UPLOAD32 FITS" $OUT/P64.log && grep -q "RAM mapper: 256 x" $OUT/P64.log || { echo "FAIL: P64 -- 64 MB board keeps 4 MB within 32 MB"; F=1; }
[ $F -eq 0 ] && echo "RESULT PASS: bench sound (N1 caught, C3 fits); C1/C2 verdicts above" || echo "RESULT FAIL"
exit $F
