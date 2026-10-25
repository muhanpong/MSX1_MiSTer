#!/usr/bin/env bash
#  CPU-visible lockstep: ymf278b_top (with the OPL3 timer stub) against the
#  openMSX YMF278B model, access by access.  See cpuvis_check.py.
#
#      run_cpuvis.sh [out_dir]
#
#  env: ENGINE (PCM engine files, last one the engine module), REGS, TOP (files
#  under test, default the tree's), LAT (SDRAM read latency, default 6),
#  WLAT (SDRAM write latency, default 0), CLK_HZ (default 128863620), DEV (deviation
#  flags for the model, default all), RESET_LEN / AGAIN_GAP (cpuvis_ops.py knobs).
#  Prints "CPUVIS PASS|FAIL"; a build that fails is a FAIL.
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd)
Y=$(cd "$HERE/../.." && pwd)
O=${1:-/tmp/cpuvis.$$}
ENGINE=${ENGINE:-"$Y/rtl/pcm/ymf278_pcm_alu.sv $Y/rtl/pcm/ymf278_pcm_eg_step.sv $Y/rtl/pcm/ymf278_pcm_engine2.sv"}
REGS=${REGS:-$Y/rtl/ymf278b_regs.sv}
TOP=${TOP:-$Y/rtl/ymf278b_top.sv}
CLK_HZ=${CLK_HZ:-128863620}
O3=$Y/rtl/opl3/modules
#  the engine module named by the last ENGINE file picks the top's engine (PCM_ENGINE3)
#  and, with it, the reg 6 write delay the model expects (ymf278b_top.sv)
EMOD=$(grep -m1 -oE '^\s*module\s+[A-Za-z0-9_]+' $(echo $ENGINE | awk '{print $NF}') | awk '{print $2}')
VDEFS=""; MEMW=1024
if [ "$EMOD" = ymf278_pcm_engine3 ]; then
    VDEFS="+define+PCM_ENGINE3"; MEMW=$(( (28 * (CLK_HZ / 1000) + 33868 / 2) / 33868 ))
fi
rm -rf "$O"; mkdir -p "$O"
echo "engine $EMOD, reg 6 write delay $MEMW clk, lat ${LAT:-6}, wlat ${WLAT:-0}" > "$O/engine.txt"
(cd "$Y/sim/golden" && python3 gen_pcm_testdata.py > /dev/null) || { echo "CPUVIS FAIL: testdata"; exit 1; }
#  cpuvis's own copy of the sample memory: wave 0's header bytes 7-11 (what a reset
#  backfills into fields 5-9) made non-zero and distinct, so a field that missed the
#  backfill cannot read the same as one that got it.  golden's mem.bin is not touched
#  (its scenarios play wave 0 with that envelope).
python3 - "$Y/sim/golden/mem.bin" "$O" <<'PY' || { echo "CPUVIS FAIL: memory image"; exit 1; }
import sys
m = bytearray(open(sys.argv[1], 'rb').read())
m[7:12] = bytes([0x31, 0x5A, 0x27, 0xC6, 0x0B])
open(sys.argv[2] + '/mem.bin', 'wb').write(m)
open(sys.argv[2] + '/mem.hex', 'w').write(''.join(f"{b:02x}\n" for b in m))
PY
#  RESET_LEN: the warm reset's length in clk (the harness `reset` gate moves it)
CPUVIS_RESET_LEN=${RESET_LEN:-256} CPUVIS_AGAIN_GAP=${AGAIN_GAP:-8} CPUVIS_AGAIN_PRE=${AGAIN_PRE:-0} python3 "$HERE/cpuvis_ops.py" > "$O/ops.txt"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-PINCONNECTEMPTY \
   $VDEFS -GCLK_HZ=$CLK_HZ --top-module tb_cpuvis -o vcpu -Mdir "$O/v" \
   "$O3/top_level/pkg/opl3_pkg.sv" "$O3/misc/src/edge_detector.sv" \
   "$O3/timers/src/timer.sv" "$O3/timers/src/timers.sv" "$Y/tb/opl3_stub.sv" \
   $ENGINE "$REGS" "$TOP" "$HERE/tb_cpuvis.sv" > "$O/build.log" 2>&1
[ -x "$O/v/vcpu" ] || { echo "CPUVIS FAIL: build"; grep -m5 %Error "$O/build.log"; exit 1; }
"$O/v/vcpu" +ops="$O/ops.txt" +mem="$O/mem.hex" +lat=${LAT:-6} +wlat=${WLAT:-0} +log="$O/cpuvis.log" > "$O/run.log" 2>&1
#  an engine that reports a lost register write fails whatever the model says (Verilator
#  stops at the $error, so this comes before the "did not finish" check)
if grep -q "queue overflow" "$O/run.log"; then echo "CPUVIS FAIL: $(grep -m1 'queue overflow' "$O/run.log" | sed 's/^\[[0-9]*\] //')"; exit 1; fi
grep -q "^end " "$O/cpuvis.log" 2>/dev/null || { echo "CPUVIS FAIL: the bench did not finish (see $O/run.log)"; exit 1; }
CPUVIS_ENGINE=$EMOD CPUVIS_MEMW=$MEMW CPUVIS_WLAT=${WLAT:-0} python3 "$HERE/cpuvis_check.py" "$O/cpuvis.log" "$O/mem.bin" ${DEV:+--dev $DEV} | tee "$O/check.txt"
grep -q "^CPUVIS PASS" "$O/check.txt"
