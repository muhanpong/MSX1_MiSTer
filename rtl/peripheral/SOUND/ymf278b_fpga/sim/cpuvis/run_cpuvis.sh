#!/usr/bin/env bash
#  CPU-visible lockstep: ymf278b_top (with the OPL3 timer stub) against the
#  openMSX YMF278B model, access by access.  See cpuvis_check.py.
#
#      run_cpuvis.sh [out_dir]
#
#  env: ENGINE (PCM engine files, last one the engine module), REGS, TOP (files
#  under test, default the tree's), LAT (SDRAM read latency, default 6),
#  CLK_HZ (default 128863620), DEV (deviation flags for the model, default all).
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
rm -rf "$O"; mkdir -p "$O"
(cd "$Y/sim/golden" && python3 gen_pcm_testdata.py > /dev/null) || { echo "CPUVIS FAIL: testdata"; exit 1; }
python3 "$HERE/cpuvis_ops.py" > "$O/ops.txt"
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-PINMISSING -Wno-UNDRIVEN -Wno-SIDEEFFECT -Wno-PINCONNECTEMPTY \
   -GCLK_HZ=$CLK_HZ --top-module tb_cpuvis -o vcpu -Mdir "$O/v" \
   "$O3/top_level/pkg/opl3_pkg.sv" "$O3/misc/src/edge_detector.sv" \
   "$O3/timers/src/timer.sv" "$O3/timers/src/timers.sv" "$Y/tb/opl3_stub.sv" \
   $ENGINE "$REGS" "$TOP" "$HERE/tb_cpuvis.sv" > "$O/build.log" 2>&1
[ -x "$O/v/vcpu" ] || { echo "CPUVIS FAIL: build"; grep -m5 %Error "$O/build.log"; exit 1; }
"$O/v/vcpu" +ops="$O/ops.txt" +mem="$Y/sim/golden/mem.hex" +lat=${LAT:-6} +log="$O/cpuvis.log" > "$O/run.log" 2>&1
grep -q "^end " "$O/cpuvis.log" 2>/dev/null || { echo "CPUVIS FAIL: the bench did not finish (see $O/run.log)"; exit 1; }
python3 "$HERE/cpuvis_check.py" "$O/cpuvis.log" "$Y/sim/golden/mem.bin" ${DEV:+--dev $DEV} | tee "$O/check.txt"
grep -q "^CPUVIS PASS" "$O/check.txt"
