#!/usr/bin/env bash
#  ymf278b_top in MSX-AUDIO mode: detection, sample RAM, FM and ADPCM reach the output.
#    sim/msx_audio/run_top.sh        OUT=<dir>
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/data/_claude/tmp/msx_audio_top.$$}; mkdir -p "$O"
Y=$R/rtl/peripheral/SOUND/ymf278b_fpga/rtl
FILES=$(grep -o 'ymf278b_fpga/rtl/[^]]*' $R/rtl/sound/sound.qip | sed "s#ymf278b_fpga/rtl#$Y#" | grep -v "leds.sv")
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
    -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-IMPLICIT +define+PCM_ENGINE3 \
    --top-module tb -Mdir "$O/top" -o tb $FILES $Y/opl3/modules/misc/src/leds.sv \
    $R/rtl/peripheral/SOUND/msx_audio/y8950_addon.sv "$HERE/tb_top_audio.sv" > "$O/build.log" 2>&1
[ -x "$O/top/tb" ] || { echo "RESULT FAIL: build: $(grep -m3 %Error "$O/build.log")"; exit 1; }
"$O/top/tb" | tee "$O/run.log" | grep -v "^- "
grep -q "TOP PASS" "$O/run.log" && echo "RESULT PASS" || { echo "RESULT FAIL"; exit 1; }
