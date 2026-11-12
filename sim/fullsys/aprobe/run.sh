#!/usr/bin/env bash
#  APROBE: the MSX-AUDIO through the whole machine (port decode, WAIT, status, /INT).
#    msxaudio   Audio Card = MSX-AUDIO     want PASS
#    moonsound  Audio Card = MoonSound     want FAIL (C0h undecoded)
#    none       Audio Card = None          want FAIL
#  sim/fullsys/prep.sh first.   sim/fullsys/aprobe/run.sh [pack.MSX] [ms]   env: OUT=<dir>
set -u
cd "$(dirname "$0")/../../.."
PX=${1:-/data/_claude/tmp/msx1-handoff/gt2mb.MSX}
MS=${2:-40}
OUT=${OUT:-/tmp/aprobe}; mkdir -p "$OUT"
#  FW=<fw pack>: a firmware pack (16-byte "MSX" 0 8 0 128 header + yrw801.rom = the MoonSound ROM)
#  HI=80: the sample RAM test at 20040h, which only the SDRAM home (a pack with the MoonSound
#  ROM) can pass
python3 sim/fullsys/aprobe/mkaprobe.py ${HI:-00} > sim/fullsys/aprobe/aprobe.hex
H=$PWD/sim/fullsys/aprobe/aprobe.hex
run() { XDEFS="-DAPROBE" EXTRA="+kprobe=$H $2" OUT=$OUT/$1 \
           sim/fullsys/run_preload.sh tdm128 "$PX" "$MS" "" 0 "${FW:-}" > "$OUT/$1.log" 2>&1; }
run msxaudio  "+msxaudio"  &
run moonsound "+moonsound" &
run none      ""           &
wait
ok=1
for r in msxaudio:PASS moonsound:FAIL none:FAIL; do
   n=${r%%:*}; want=${r##*:}
   got=$(grep -ho 'APROBE RESULT [A-Z]*' "$OUT/$n.log" | tail -1 | awk '{print $3}')
   echo "== $n: ${got:-no result} (want $want)"
   grep -h '^aprobe: sample\|^aprobe: byte\|^APROBE\|BUILD FAIL\|%Error' "$OUT/$n.log" | head -20
   [ "$got" = "$want" ] || ok=0
done
[ $ok = 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
