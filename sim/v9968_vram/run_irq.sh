#!/usr/bin/env bash
#  FH (line-interrupt flag) must survive until the CPU reads S#1 -- ASO 224's second split
#  (R#19 = D2h, R#9 = 212 lines: FH at line 210, the frame-interrupt timing 14.5 us later).
#  The real chip and openMSX clear FH only on reset, the S#1 read and an IE1-off R#0 write;
#  upstream V9968 also cleared it at the frame interrupt (ORIGIN.md, 2026-10-24).
#    sim/v9968_vram/run_irq.sh        OUT=<dir>
#  PASS needs: the current RTL reads FH = 1 at every handler delay (5..90 us) and on the control
#  line 68h; AND the mutant with upstream's frame-time clear restored reads FH = 0 at >= 20 us
#  (the test can fail).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/data/_claude/tmp/v9968_irq.$$}; rm -rf "$O"; mkdir -p "$O/mut"
cp $R/rtl/video/v9968/*.v "$O/mut/"
python3 - "$O/mut/vdp_cpu_interface.v" <<'E'
import sys
p = sys.argv[1]; s = open(p).read()
old = "\t\t\t//\tFH is not cleared at the frame interrupt (MSX1 core, 2026-10-24): see ORIGIN.md\n\t\t\tif( ff_register_write"
new = "\t\t\tif( clear_line_interrupt || intr_frame ) begin\n\t\t\t\tff_line_interrupt <= 1'b0;\n\t\t\tend\n\t\t\telse if( ff_register_write"
if old not in s: sys.exit("mutant: anchor not found in vdp_cpu_interface.v (the fix moved?)")
open(p, "w").write(s.replace(old, new, 1))
E
[ $? -eq 0 ] || { echo "RESULT FAIL: could not build the mutant"; exit 1; }
build() {  # name v9968-dir
    verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        -GRELEASE_PH=5 --top-module tb -Mdir "$O/$1" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $R/sim/sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $2/*.v $R/rtl/video/v9968_cmdwait.sv $HERE/tb_v9968_vram.sv > "$O/$1.build.log" 2>&1
    [ -x "$O/$1/tb" ] || { echo "RESULT FAIL: build $1: $(grep -m1 %Error "$O/$1.build.log")"; exit 1; }
}
build cur $R/rtl/video/v9968 & build mut "$O/mut" & wait
[ -x "$O/cur/tb" ] && [ -x "$O/mut/tb" ] || { echo "RESULT FAIL: build"; exit 1; }
#  delays in clk_vdp: 5, 10, 20, 48 (this core's R800), 90 us (openMSX)
run() {  # name line r9 delay
    "$O/$1/tb" +m128=1 +ie1=6 +ie1line=$2 +ie1r9=$3 +ie1dly=$4 > "$O/$1_$2_$4.log" 2>&1
}
for b in cur mut; do
    for d in 430 859 1718 4124 7732; do run $b D2 80 $d & done
    run $b 68 00 4124 &
done
wait
fh0() { grep -ho "IE1 RESULT.*" "$O/$1_$2_$3.log" | sed -E 's/.* ([0-9]+) read FH=0.*/\1/'; }
ok=1
for d in 430 859 1718 4124 7732; do
    c=$(fh0 cur D2 $d); m=$(fh0 mut D2 $d)
    echo "  line D2h delay $d clk: current FH=0 in ${c:-?}/6, mutant ${m:-?}/6"
    [ "$c" = 0 ] || ok=0
    [ $d -ge 1718 ] && { [ "${m:-0}" -gt 0 ] || { echo "  mutant NOT caught at $d"; ok=0; }; }
done
c=$(fh0 cur 68 4124); m=$(fh0 mut 68 4124)
echo "  control line 68h delay 4124: current ${c:-?}/6, mutant ${m:-?}/6"
[ "$c" = 0 ] || ok=0
[ $ok = 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
