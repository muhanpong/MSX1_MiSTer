#!/usr/bin/env bash
#  Whole-machine run without the byte-by-byte upload: sim/tb_upload32.sv builds the
#  SDRAM image and the uploader's outputs (+dump), tb_msx -DPRELOAD loads them and
#  releases the machine.  For carts and firmware too big to upload in fullsys time.
#
#    sim/fullsys/run_preload.sh <old|tdm|tdm128> <pack.MSX> <ms> [roma.rom mapper] [fw.bin]
#      tdm128: sdram_tdm in the 128 MB board map (two chips), sdram_size 3
#      env: OUT=<dir>  V9968=1 (MSX_V9968 build)  MOONSOUND=1 (OSD MoonSound on)  EXTRA="+plusargs"  XDEFS="-D..."  VFLAGS="--threads 4"
#  Validated against a normal upload run: see docs/handoff_20261013b_tdm_boot.md 7.
set -eu
cd "$(dirname "$0")/../.."
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
MODE=${1:?old|tdm|tdm128}; PACK=${2:?pack}; MS=${3:?ms}; ROMA=${4:-}; MAPA=${5:-0}; FW=${6:-}
OUT=${OUT:-/tmp/fullsys_preload_$MODE}; mkdir -p "$OUT"
GEN=$PWD/sim/fullsys/gen
#  1. the upload, alone (sdram_size 2, as tb_msx)
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY -Wno-ASCRANGE -Wno-LATCH -Wno-ENUMVALUE \
   --top-module tb_upload32 -o tbu -Mdir "$OUT/u" \
   rtl/package.sv rtl/peripheral/slots/memory_upload.sv rtl/peripheral/slots/mapper_detect.sv \
   sim/tb_upload32.sv > "$OUT/u.build.log" 2>&1 || { echo "RESULT FAIL: upload bench build"; exit 1; }
SDSZ=2; [ "$MODE" = tdm128 ] && SDSZ=3
A=("+pack=$PACK" +sdsz=$SDSZ +limit=4000000 "+dump=$OUT/pre")
[ -n "$FW" ]   && A+=("+fw=$FW")
[ -n "$ROMA" ] && A+=("+roma=$ROMA" "+mapa=$MAPA")
"$OUT/u/tbu" "${A[@]}" > "$OUT/upload.log" 2>&1
grep -E "^dump:|FILL|UPLOAD32" "$OUT/upload.log" | tail -4
#  2. the machine
FILES=$(grep -v 'rtl/peripheral/sdram\(_tdm\)\?\.sv$' "$GEN/filelist.txt" | grep -v 'memory_upload\.sv$' | tr '\n' ' ')
DEFS="-DPRELOAD -DPRELOAD_SVH=\"$OUT/pre.state.svh\""
[ "$MODE" = tdm ] && DEFS="$DEFS -DTDM"
[ "$MODE" = tdm128 ] && DEFS="$DEFS -DTDM128"
#  V9968=1 (plan S5): the MSX_V9968 build -- the V9968 instead of the ESE VDP, its VRAM in
#  sdram_tdm's V slot (needs tdm / tdm128)
if [ -n "${V9968:-}" ]; then
   FILES=$(echo "$FILES" | tr ' ' '\n' | grep -v '/gen/vdp\.v$' | tr '\n' ' ')
   FILES="$FILES $(ls rtl/video/v9968/*.v | tr '\n' ' ') rtl/video/v9968_link.sv rtl/video/v9968_bus.sv"
   DEFS="$DEFS -DMSX_V9968"
fi
DEFS="$DEFS ${XDEFS:-}"      # extra defines (negative controls: -DTDM128_MUT_MAP, -DIOLOG_MUT)
verilator --binary --timing --public-flat-rw \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
   -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
   -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK \
   -Wno-TIMESCALEMOD \
   $DEFS ${VFLAGS:-} --top-module tb -o tbmsx -Mdir "$OUT/v" \
   "+incdir+$GEN" $FILES "$GEN/sdram_sim.sv" "$GEN/sdram_tdm_sim.sv" sim/fullsys/tb_msx.sv \
   > "$OUT/build.log" 2>&1 || { echo "BUILD FAIL:"; grep -E '%Error' "$OUT/build.log" | head -20; exit 1; }
echo "built -> $OUT/v/tbmsx"
X=("+pack=$PACK" "+ms=$MS" "+preload=$OUT/pre")
[ -n "${MOONSOUND:-}" ] && X+=(+moonsound)
"$OUT/v/tbmsx" "${X[@]}" ${EXTRA:-}
