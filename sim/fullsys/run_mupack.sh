#!/usr/bin/env bash
#  MU-PACK in slot B, through the whole-machine upload.  Four runs, in parallel,
#  each stopped 1 ms after reset release -- the question is what the upload built:
#
#    S1  FS-A1ST + FW pack with MU_PACK + slot B = MU-PACK      (the feature)
#    S2  FS-A1ST + the same FW pack + slot B not MU-PACK        (negative control)
#    S3  FS-A1ST + FW pack WITHOUT MU_PACK + slot B = MU-PACK   (missing ROM)
#    S4  FS-A1GT + FW pack with MU_PACK + slot B = MU-PACK      (GT's MIDI wins)
#
#  PASS needs all of:
#    S1  slot 2 expanded; 2-1 pages 0-3 = MAPPER_MUPACK with 16 x 16 kB; 2-2 page 1
#        holds the ROM ("BIT2MIDI" at 18h, i.e. "MIDI" at 401Ch); MIDI is the
#        E2h-controlled variant, closed at reset (external=1, ext_ctl=81h)
#    S2  slot 2 not expanded and empty; no MIDI device
#    S3  2-1 mapper present, 2-2 empty, the pack otherwise identical to S1 outside
#        slot 2 (no silent loss of later records), MSX_typ=MSX2, .sav requested
#        -- and the MIDI is still there (cs=1, E2h-controlled, closed): MIDRY /I5
#        needs no ROM
#    S4  MIDI is the GT's built-in one (external=0) even with MU-PACK chosen
#
#  The mu-pack.rom used here is SYNTHETIC (16 kB, "AB" with INIT=0, "BIT2MIDI" at
#  18h): the real ROM is not in the tree.  This proves placement and wiring, not
#  the ROM's own behaviour -- that is the board test with the real ROM.
#
#      sim/fullsys/prep.sh          # once, after RTL changes
#      sim/fullsys/run_mupack.sh
set -u
cd "$(dirname "$0")/../.."
ROOT=$PWD
GEN=$ROOT/sim/fullsys/gen
OUT=${OUT:-/tmp/fullsys_mupack}
#  The .MSX packs are build products, not in git: point PACKS at a tree that has them.
PACKS=${PACKS:-$ROOT/tools/CreateMSXpack/MSX/Panasonic}
[ -s "$GEN/filelist.txt" ] || { echo "run_mupack: sim/fullsys/prep.sh first"; exit 2; }
mkdir -p "$OUT"

python3 - "$OUT" <<'PY'
import sys
out = sys.argv[1]
def hdr(typ, blocks16k):
    h = bytearray(b'MSX'); h += bytes([0, typ, blocks16k >> 8, blocks16k & 255]); return h + bytes(16 - len(h))
rom = bytearray(b'\xFF' * 0x4000)
rom[0:16] = b'AB' + bytes(14)
rom[0x18:0x20] = b'BIT2MIDI'
dummy = bytes([0xA5]) * 0x4000            # an FM_PAC-typed block the search must step over
open(f'{out}/fw_mu.bin',   'wb').write(hdr(4, 1) + dummy + hdr(9, 1) + rom)   # 9 = ROM_MUPACK
open(f'{out}/fw_nomu.bin', 'wb').write(hdr(4, 1) + dummy)
PY

FILES=$(grep -v 'rtl/peripheral/sdram\.sv$' "$GEN/filelist.txt" | tr '\n' ' ')
verilator --binary --timing --public-flat-rw \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
   -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
   -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK \
   -Wno-TIMESCALEMOD \
   --top-module tb -o tbmsx -Mdir "$OUT/v" \
   "+incdir+$GEN" $FILES "$GEN/sdram_sim.sv" sim/fullsys/tb_msx.sv \
   > "$OUT/build.log" 2>&1 || { echo "RESULT FAIL: build"; grep -E '%Error' "$OUT/build.log" | head; exit 1; }

ST="$PACKS/Panasonic FS-A1ST.MSX"; GT="$PACKS/Panasonic FS-A1GT.MSX"
"$OUT/v/tbmsx" "+pack=$ST" +fwpack="$OUT/fw_mu.bin"   +slotb=8 +ms=1 > "$OUT/S1.log" 2>&1 &
"$OUT/v/tbmsx" "+pack=$ST" +fwpack="$OUT/fw_mu.bin"   +slotb=0 +ms=1 > "$OUT/S2.log" 2>&1 &
"$OUT/v/tbmsx" "+pack=$ST" +fwpack="$OUT/fw_nomu.bin" +slotb=8 +ms=1 > "$OUT/S3.log" 2>&1 &
"$OUT/v/tbmsx" "+pack=$GT" +fwpack="$OUT/fw_mu.bin"   +slotb=8 +ms=1 > "$OUT/S4.log" 2>&1 &
wait

FAIL=0
ck() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; FAIL=1; fi; }
has() { grep -qF -- "$2" "$OUT/$1.log"; }
n21() { grep -cE "mupack: 2-1 page [0-3] mapper=26 ref_ram=[0-9]+ size=16 " "$OUT/$1.log"; }
outside2() { grep "upload: slot_layout" "$OUT/$1.log" | grep -v "slot 2-" | sed 's/ref_ram=[0-9]*//'; }

for s in S1 S2 S3 S4; do ck "$s ran to the end of the upload" "has $s 'mupack: slot B typ='"; done
ck "S1 slot 2 is expanded"                        "has S1 '(slot 2 expanded=1)'"
ck "S1 2-1 pages 0-3 = MU-PACK mapper, 16 x 16kB" "[ \$(n21 S1) -eq 4 ]"
ck "S1 2-2 page 1 holds the ROM (BIT2MIDI)"       "has S1 'bytes 18h-1Fh = \"BIT2MIDI\"'"
ck "S1 MIDI is E2h-controlled, closed at reset"   "has S1 '-> cs=1 external=1 ext_ctl=81'"
ck "S2 slot 2 not expanded"                       "has S2 '(slot 2 expanded=0)'"
ck "S2 slot 2-2 empty"                            "has S2 '(slot 2-2 page 1 empty)'"
ck "S2 no MIDI device"                            "has S2 '-> cs=0 '"
ck "S3 2-1 mapper still there"                    "[ \$(n21 S3) -eq 4 ]"
ck "S3 2-2 empty (no MU_PACK in the FW pack)"     "has S3 '(slot 2-2 page 1 empty)'"
#  Two empty lists are equal too: demand that S1 actually loaded something first.
ck "S1 loaded the pack outside slot 2 (>= 8 entries)" "[ \$(outside2 S1 | wc -l) -ge 8 ]"
ck "S3 rest of the pack = S1 outside slot 2"      "diff <(outside2 S1) <(outside2 S3) > /dev/null"
ck "S3 CONFIG parsed and .sav requested"          "has S3 'MSX_typ=1' && has S3 'load_sram issued=1'"
ck "S3 MIDI survives the missing ROM"             "has S3 '-> cs=1 external=1 ext_ctl=81'"
ck "S4 GT's own MIDI wins (external=0)"           "has S4 'gt=1' && has S4 '-> cs=1 external=0'"
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "MU-PACK FULLSYS: PASS" || echo "RESULT FAIL: MU-PACK FULLSYS"
exit $FAIL
