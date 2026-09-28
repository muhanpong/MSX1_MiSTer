#!/usr/bin/env bash
#  The machine class the core derives from a pack: memory_upload latches byte
#  002Dh of the ROM that lands in slot 0-0 page 0 (0 MSX1, 1 MSX2, 2 MSX2+,
#  3 turbo R) into bios_config.ver.  MSX1.sv keys the turbo R hardware and the
#  CPU menu rows on ver == 3.
#
#      sim/fullsys/run_packver.sh                 # packs from the first dir that has them:
#      PACKS=<dir> sim/fullsys/run_packver.sh     #   $PACKS, sim/fullsys/packs (local cache,
#                                                 #   gitignored), tools/CreateMSXpack/MSX here,
#                                                 #   then the main checkout's.
#  The .MSX packs are build products, not in git.  To refill the local cache from the
#  board:  scp root@<board>:/media/fat/games/MSX1/MSX/{Panasonic/"Panasonic FS-A1ST DOS2.MSX",
#          Daewoo/Daewoo_CPC-300.MSX,Sony/Sony_HB-F1XV.MSX} into sim/fullsys/packs/<maker>/.
#
#  PASS needs all three:
#    T   FS-A1ST DOS2 pack            -> bios_ver=03
#    M   Daewoo CPC-300 pack (MSX2)    -> bios_ver=01
#    P   Sony HB-F1XV pack (MSX2+)     -> bios_ver=02
#    N   the ST pack with byte 002Dh of its BIOS record patched to 01
#        -> bios_ver=01  (proves the latch reads THAT byte of THAT record,
#        not something else that happens to be 3 on a turbo R pack)
#  and the "BIOS 002Dh" line must appear exactly once per run (first record wins).
#  A run without an "upload: bios_ver=" line is a FAIL.
set -u
cd "$(dirname "$0")/../.."
ROOT=$PWD; GEN=$ROOT/sim/fullsys/gen; OUT=${OUT:-/tmp/fullsys_packver}
[ -s "$GEN/filelist.txt" ] || { echo "run_packver: sim/fullsys/prep.sh first"; exit 2; }
if [ -z "${PACKS:-}" ]; then
   for d in "$ROOT/sim/fullsys/packs" "$ROOT/tools/CreateMSXpack/MSX" "$HOME/Documents/github/MSX1_MiSTer/tools/CreateMSXpack/MSX"; do
      [ -s "$d/Panasonic/Panasonic FS-A1ST DOS2.MSX" ] && { PACKS=$d; break; }
   done
   PACKS=${PACKS:-$ROOT/sim/fullsys/packs}
fi
ST="$PACKS/Panasonic/Panasonic FS-A1ST DOS2.MSX"; DW="$PACKS/Daewoo/Daewoo_CPC-300.MSX"; SY="$PACKS/Sony/Sony_HB-F1XV.MSX"
#  (The board's Daewoo_CPC-400S.MSX of 2026-05-24 is an older "MSx" file the
#  upload FSM rejects at the first header; it is not a usable sample.)
for f in "$ST" "$DW" "$SY"; do [ -s "$f" ] || { echo "RESULT FAIL: pack missing: $f"; exit 2; }; done
rm -rf "$OUT"; mkdir -p "$OUT"
#  Negative control: same ST pack, BIOS record's byte 002Dh -> 01.  The first
#  record starts at offset 16 (after its 16-byte header); refuse if it is not 03.
python3 - "$ST" "$OUT/st_patched.MSX" <<'PY'
import sys
d=bytearray(open(sys.argv[1],'rb').read())
assert d[0:3]==b'MSX' and d[16+0x2D]==3, "ST pack: first record is not a turbo R BIOS (byte 002Dh != 03)"
d[16+0x2D]=1; open(sys.argv[2],'wb').write(d)
PY
[ -s "$OUT/st_patched.MSX" ] || { echo "RESULT FAIL: could not make the patched pack"; exit 1; }
cmp -s "$ST" "$OUT/st_patched.MSX" && { echo "RESULT FAIL: patched pack identical to source"; exit 1; }

FILES=$(grep -v 'rtl/peripheral/sdram\.sv$' "$GEN/filelist.txt" | tr '\n' ' ')
verilator --binary --timing --public-flat-rw \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
   -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
   -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK \
   -Wno-TIMESCALEMOD \
   --top-module tb -o tbmsx -Mdir "$OUT/v" \
   "+incdir+$GEN" $FILES "$GEN/sdram_sim.sv" sim/fullsys/tb_msx.sv \
   > "$OUT/build.log" 2>&1 || { echo "RESULT FAIL: build"; grep -E '%Error' "$OUT/build.log" | head; exit 1; }

"$OUT/v/tbmsx" "+pack=$ST"                 +ms=1 > "$OUT/T.log" 2>&1 &
"$OUT/v/tbmsx" "+pack=$DW"                 +ms=1 > "$OUT/M.log" 2>&1 &
"$OUT/v/tbmsx" "+pack=$SY"                 +ms=1 > "$OUT/P.log" 2>&1 &
"$OUT/v/tbmsx" "+pack=$OUT/st_patched.MSX" +ms=1 > "$OUT/N.log" 2>&1 &
wait

FAIL=0
ck() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; FAIL=1; fi; }
ver() { grep -oE 'upload: bios_ver=[0-9a-f]{2}' "$OUT/$1.log" | head -1 | cut -d= -f2; }
n2d() { grep -c 'BIOS 002Dh =' "$OUT/$1.log"; }
for r in T M P N; do ck "$r has a bios_ver line" "grep -q 'upload: bios_ver=' '$OUT/$r.log'"; done
ck "T  turbo R pack        -> 03 (got $(ver T))" "[ \"$(ver T)\" = 03 ]"
ck "M  MSX2 pack           -> 01 (got $(ver M))" "[ \"$(ver M)\" = 01 ]"
ck "P  MSX2+ pack          -> 02 (got $(ver P))" "[ \"$(ver P)\" = 02 ]"
ck "N  ST pack, 002Dh:=01  -> 01 (got $(ver N))" "[ \"$(ver N)\" = 01 ]"
for r in T M P N; do ck "$r latched exactly once (count $(n2d $r))" "[ \"$(n2d $r)\" = 1 ]"; done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "PACK VER: PASS" || echo "RESULT FAIL: PACK VER"
exit $FAIL
