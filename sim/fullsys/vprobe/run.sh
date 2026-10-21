#!/usr/bin/env bash
#  VPROBE (plan S5): the MSX_V9968 build in fullsys, the probe in place of the BIOS.
#  Runs the normal build and the negative control (v9968_link RELEASE_PH 6: the V9968
#  leaves reset on the wrong clk_vdp edge of the TDM frame, its first VRAM read is never
#  answered) and wants PASS / FAIL, in that order.
#    sim/fullsys/vprobe/run.sh [pack.MSX] [ms]     env: OUT=<dir>
#  RELEASE_PH sweep (2026-10-21, FS-A1FX, tdm128): 12 phases land on 8 release edges;
#  only clk_vdp 40702 (phases 4 and 5) works.  sim/v9968_vram: only phase 5.
set -u
cd "$(dirname "$0")/../../.."
PX=${1:-$HOME/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack/MSX/Panasonic/Panasonic FS-A1FX.MSX}
MS=${2:-250}
OUT=${OUT:-/tmp/vprobe}; mkdir -p "$OUT"
H=$PWD/sim/fullsys/vprobe/vprobe.hex
V9968=1 XDEFS="-DVPROBE" EXTRA="+kprobe=$H" OUT=$OUT/norm \
   sim/fullsys/run_preload.sh tdm128 "$PX" "$MS" > "$OUT/norm.log" 2>&1 &
V9968=1 XDEFS="-DVPROBE -DV99_RELPH=6" EXTRA="+kprobe=$H" OUT=$OUT/mut \
   sim/fullsys/run_preload.sh tdm128 "$PX" "$MS" > "$OUT/mut.log" 2>&1 &
wait
n=$(grep -ho 'VPROBE RESULT [A-Z]*' "$OUT/norm.log" | tail -1)
m=$(grep -ho 'VPROBE RESULT [A-Z]*' "$OUT/mut.log" | tail -1)
grep -hE '^VPROBE|^V9968' "$OUT/norm.log"
echo "normal: ${n:-no result} | negative control (RELEASE_PH 6): ${m:-no result}"
[ "$n" = "VPROBE RESULT PASS" ] && [ "$m" = "VPROBE RESULT FAIL" ] && echo "RESULT PASS" || echo "RESULT FAIL"
