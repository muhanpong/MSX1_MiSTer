#!/usr/bin/env bash
#  Geo3D frame time on this core (geo3d v2.0 + V9968 + sdram_tdm V slot), driven by upstream's
#  tb_system.v stimulus (geo3d/sim/texdemo_sys.txt, made by run_demo_z80.py from GEO3DT.COM).
#  STIM=<file> (default stim/texdemo_sys.txt; stim/tiny_sys.txt = geometry-only control)  OUT=<dir>  ARGS="+r20=0 +v9938=1 +frames=N ..."
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/geo3d_perf.$$}; mkdir -p "$O"
if [ ! -x "$O/obj/tb" ]; then
    verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        -GRELEASE_PH=5 --top-module tb -Mdir "$O/obj" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $R/sim/sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $R/rtl/video/v9968/*.v $R/rtl/video/v9968_cmdwait.sv \
        $R/rtl/video/geo3d/geo3d_bus.v $R/rtl/video/geo3d/geo3d_engine.v $R/rtl/video/geo3d/geo3d_core.v \
        $HERE/brk_probe.sv $HERE/${TB:-tb_geo3d_perf}.sv > "$O/build.log" 2>&1
    [ -x "$O/obj/tb" ] || { echo "BUILD FAIL: $(grep -m3 %Error "$O/build.log")"; exit 1; }
fi
"$O/obj/tb" +stim=${STIM:-$HERE/stim/texdemo_sys.txt} ${ARGS:-}
