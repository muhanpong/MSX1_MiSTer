#!/usr/bin/env bash
#  An openMSX port log (replay_omsx.sh's io.log) through the whole sound block in MSX-AUDIO
#  mode -> WAV.  For listening and for levels; nothing is compared here.
#    sim/msx_audio/replay_top.sh <io.log> <out.wav>      env: OUT=<dir>  RAM_AW=15..18 (sample RAM, 32..256 KB)  TBARGS=+fmmute (ADPCM alone)
#  ~130 M clocks per second of sound: a 10 s tune takes some minutes.
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
LOG=${1:?io.log}; WAV=${2:?out.wav}
O=${OUT:-/data/_claude/tmp/msx_audio_rtop.$$}; mkdir -p "$O"
Y=$R/rtl/peripheral/SOUND/ymf278b_fpga/rtl
FILES=$(grep -o 'ymf278b_fpga/rtl/[^]]*' $R/rtl/sound/sound.qip | sed "s#ymf278b_fpga/rtl#$Y#" | grep -v "leds.sv")
verilator --binary --timing -j 8 -O3 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
    -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT -Wno-IMPLICIT +define+PCM_ENGINE3 +define+RAM_AW=${RAM_AW:-15} \
    --top-module tb -Mdir "$O/top" -o tb $FILES $Y/opl3/modules/misc/src/leds.sv \
    $R/rtl/peripheral/SOUND/msx_audio/y8950_addon.sv "$HERE/tb_top_replay.sv" > "$O/build.log" 2>&1
[ -x "$O/top/tb" ] || { echo "RESULT FAIL: build: $(grep -m3 %Error "$O/build.log")"; exit 1; }
python3 "$HERE/omsx2script.py" top "$LOG" "$O/top.script" || exit 1
"$O/top/tb" +script="$O/top.script" +pcm="$O/out.pcm" ${TBARGS:-} | grep REPLAY
python3 - "$O/out.pcm" "$WAV" <<'P'
import sys, wave
d = open(sys.argv[1], "rb").read()
w = wave.open(sys.argv[2], "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(49716); w.writeframes(d); w.close()
print("wav: %.2f s" % (len(d) / 4 / 49716))
P
