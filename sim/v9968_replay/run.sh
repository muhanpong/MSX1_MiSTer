#!/usr/bin/env bash
#  run.sh <trace.io> <dump flips: "174,204,234"> [out dir]
#  Replays an openMSX-V9968 I/O trace (~/data/v9968_oracle, iotrace.tcl) into the RTL
#  V9968 and dumps the frame after each listed page flip (write to R#2).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
TR=$1; DUMPS=$2; O=${3:-/tmp/v9968_replay}; mkdir -p "$O"
if [ ! -x "$O/bin/tb" ] || [ -n "${REBUILD:-}" ]; then
    rm -rf "$O/bin"; mkdir -p "$O/bin"
    verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        ${XDEF:-} -GRELEASE_PH=5 --top-module tb -Mdir "$O/bin" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $HERE/../sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $R/rtl/video/v9968/*.v $R/rtl/video/v9968_cmdwait.sv $HERE/tb_replay.sv > "$O/build.log" 2>&1
    [ -x "$O/bin/tb" ] || { echo "BUILD FAIL: $(grep -m3 %Error "$O/build.log")"; exit 1; }
fi
( time "$O/bin/tb" +trace="$TR" +out="$O" +dump="$DUMPS" ) > "$O/run.log" 2>&1
grep "REPLAY\|TB ERR\|RESULT" "$O/run.log"; grep real "$O/run.log"
