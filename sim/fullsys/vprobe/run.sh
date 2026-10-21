#!/usr/bin/env bash
#  VPROBE (plan S5): the MSX_V9968 build in fullsys, the probe in place of the BIOS.
#  Five runs, each its own build, in parallel:
#    stock         stock Z80 (unpaced)                          want PASS
#    turbo         +zspeed=4 (21.48 MHz, handshaked)            want PASS
#    mut_relph     v9968_link RELEASE_PH 6: the V9968 leaves reset on the wrong
#                  clk_vdp edge, its first VRAM read is never answered    want FAIL
#    mut_nowait    turbo, msx.sv V99_MUT_NOWAIT: no wait for the transaction  want FAIL
#    mut_noint     msx.sv V99_MUT_NOINT: the V9968's interrupt never arrives  want FAIL
#    sim/fullsys/vprobe/run.sh [pack.MSX] [ms]     env: OUT=<dir>
#  RELEASE_PH sweep (2026-10-21, FS-A1FX, tdm128): 12 phases land on 8 release edges;
#  only clk_vdp 40702 (phases 4 and 5) works.  sim/v9968_vram: only phase 5.
set -u
cd "$(dirname "$0")/../../.."
PX=${1:-$HOME/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack/MSX/Panasonic/Panasonic FS-A1FX.MSX}
MS=${2:-250}
OUT=${OUT:-/tmp/vprobe}; mkdir -p "$OUT"
H=$PWD/sim/fullsys/vprobe/vprobe.hex
run() {  # name defs extra
   V9968=1 XDEFS="-DVPROBE $2" EXTRA="+kprobe=$H $3" OUT=$OUT/$1 \
      sim/fullsys/run_preload.sh tdm128 "$PX" "$MS" > "$OUT/$1.log" 2>&1
}
run stock      ""                  ""          &
run turbo      ""                  "+zspeed=4" &
run mut_relph  "-DV99_RELPH=6"     ""          &
run mut_nowait "-DV99_MUT_NOWAIT"  "+zspeed=4" &
run mut_noint  "-DV99_MUT_NOINT"   ""          &
wait
ok=1
for r in stock:PASS turbo:PASS mut_relph:FAIL mut_nowait:FAIL mut_noint:FAIL; do
   n=${r%%:*}; want=${r##*:}
   got=$(grep -ho 'VPROBE RESULT [A-Z]*' "$OUT/$n.log" | tail -1 | awk '{print $3}')
   echo "== $n: ${got:-no result} (want $want)"
   grep -hE '^VPROBE p1|^V9968 VRAM:|^V9968 link' "$OUT/$n.log"
   [ "$got" = "$want" ] || ok=0
done
[ $ok = 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
