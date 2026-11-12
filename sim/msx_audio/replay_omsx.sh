#!/usr/bin/env bash
#  A VGM played by VGMPlay on openMSX's MSX-AUDIO, replayed through the Y8950 add-on.
#    sim/msx_audio/replay_omsx.sh <file.vgz> <seconds> <dos2 dir> <vgmplay.com>   env: OUT=<dir>
#  1. openMSX (FS-A1GT + the "audio" extension) boots <dos2 dir> (MSXDOS2.SYS, COMMAND2.COM)
#     and runs VGMPlay; every access to C0h/C1h is logged with its time and the 15 channels
#     of the device are recorded at the chip rate (ch15 = ADPCM).
#  2. omsx2script.py turns the log into a bench script; the golden model and the RTL run it.
#  3. PASS needs: RTL log == model log (byte for byte: every read, status and sample), and
#     model ADPCM == openMSX's ch15 recording, sample for sample.
#  The FM channels are NOT compared: the core's FM is the OPL3 core, openMSX's is its own
#  Y8950 FM emulation, and they are different implementations.
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
VGZ=${1:?file.vgz}; SEC=${2:?seconds}; DOS=${3:?dos2 dir}; VP=${4:?vgmplay.com}
O=${OUT:-/data/_claude/tmp/msx_audio_replay.$$}; rm -rf "$O"; mkdir -p "$O/disk"
cp "$DOS/MSXDOS2.SYS" "$DOS/COMMAND2.COM" "$O/disk/"; cp "$VP" "$O/disk/VGMPLAY.COM"; cp "$VGZ" "$O/disk/T.VGZ"
printf 'vgmplay T.VGZ\r\n' > "$O/disk/AUTOEXEC.BAT"
cat > "$O/run.tcl" <<'T'
set throttle off
set fh [open $::env(PSY_OUT)/io.log w]
proc lw {p} { puts $::fh "[machine_info time] W $p [format %02x $::wp_last_value]" }
proc lr {p} { puts $::fh "[machine_info time] R $p" }
debug set_watchpoint write_io 0xC0 {} {lw 0}
debug set_watchpoint write_io 0xC1 {} {lw 1}
debug set_watchpoint read_io 0xC0 {} {lr 0}
debug set_watchpoint read_io 0xC1 {} {lr 1}
set D "Generic MSX-Audio"
for {set i 1} {$i <= 15} {incr i} { set "::${D}_ch${i}_record" $::env(PSY_OUT)/ch$i.wav }
after time $::env(PSY_SEC) { close $::fh; exit }
T
PSY_OUT=$O PSY_SEC=$SEC SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy timeout 1800 \
    openmsx -machine Panasonic_FS-A1GT -ext audio -diska "$O/disk" -script "$O/run.tcl" > "$O/omsx.log" 2>&1
[ -s "$O/ch15.wav" ] || { echo "RESULT FAIL: no openMSX recording"; exit 1; }
python3 "$HERE/omsx2script.py" conv "$O/io.log" "$O/script.txt" "$SEC" || exit 1
python3 "$HERE/y8950_model.py" run "$O/script.txt" "$O/model.log" || exit 1
verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
    --top-module tb -Mdir "$O/v" -o tb "$R/rtl/peripheral/SOUND/msx_audio/y8950_addon.sv" "$HERE/tb_y8950.sv" > "$O/build.log" 2>&1
"$O/v/tb" +script="$O/script.txt" +log="$O/rtl.log" +memlat=3 > /dev/null 2>&1
echo "accesses: $(grep -c ' W 1 ' "$O/io.log") data writes, $(grep -c ' R ' "$O/io.log") reads; log lines $(wc -l < "$O/model.log")"
ok=1
cmp -s "$O/model.log" "$O/rtl.log" && echo "rtl == model: identical" || { echo "rtl != model:"; diff "$O/model.log" "$O/rtl.log" | head -6; ok=0; }
python3 "$HERE/omsx2script.py" cmp "$O/model.log" "$O/ch15.wav" | tee "$O/cmp.txt"
grep -q "CMP PASS" "$O/cmp.txt" || ok=0
[ $ok = 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
