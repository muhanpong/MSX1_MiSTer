#!/usr/bin/env bash
#  YPROBE: the Y8960 Cartridge through the whole machine (slot memory, enablers, SSG2
#  next to the main PSG, the PSG / MSX-AUDIO through 7FF0h-7FF3h, the forced MSX-AUDIO's
#  status, /INT and ADPCM RAM, mapper RAM mode, the slot's SCC, OPM).
#    y8960   slot A = stand-in BIOS, mapper Y8960 (27)    want PASS
#    plain   the same ROM, mapper "none" (3)              want FAIL
#  sim/fullsys/prep.sh first.   sim/fullsys/yprobe/run.sh [pack.MSX] [ms]   env: OUT=<dir>
set -u
cd "$(dirname "$0")/../../.."
PX=${1:-/data/_claude/tmp/msx1-handoff/gt2mb.MSX}
MS=${2:-60}
OUT=${OUT:-/tmp/yprobe}; mkdir -p "$OUT"
python3 sim/fullsys/yprobe/mkyprobe.py > "$OUT/yprobe.hex"
python3 sim/fullsys/yprobe/mkyprobe.py rom "$OUT/y8960bios.rom"
run() { XDEFS="-DYPROBE" EXTRA="+kprobe=$OUT/yprobe.hex" OUT=$OUT/$1 \
           sim/fullsys/run_preload.sh tdm128 "$PX" "$MS" "$OUT/y8960bios.rom" "$2" > "$OUT/$1.log" 2>&1; }
run y8960 27 &
run plain 3  &
wait
ok=1
for r in y8960:PASS plain:FAIL; do
   n=${r%%:*}; want=${r##*:}
   got=$(grep -ho 'YPROBE RESULT [A-Z]*' "$OUT/$n.log" | tail -1 | awk '{print $3}')
   echo "== $n: ${got:-no result} (want $want)"
   grep -h 'BAD\|^YPROBE\|BUILD FAIL\|%Error' "$OUT/$n.log" | head -20
   [ "$got" = "$want" ] || ok=0
done
[ $ok = 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
