#!/usr/bin/env bash
#  FH must stay 0 while IE1 (R#0 bit4) is off -- Knightmare 224 v2's interrupt handler reads S#1
#  first and takes FH = 1 as a line interrupt; with IE1 off (192-line mode, frame interrupt only)
#  a stray FH swallowed every VBLANK and the game never ran (rbf 20261024b..20261027a, after
#  b82ef60 stopped clearing FH at the frame interrupt).  openMSX VDP::execHScan sets the flag only
#  with IE1 on; the ESE VDP has the same gate (vdp_interrupt.vhd).
#    sim/v9968_vram/run_fhoff.sh        OUT=<dir>
#  PASS needs: the current RTL reads FH = 0 in 6 of 6 VBLANK handlers (IE1 off, R#19 = 68h), AND
#  the mutant without the IE1 gate reads FH = 1 (the test can fail).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/data/_claude/tmp/v9968_fhoff.$$}; rm -rf "$O"; mkdir -p "$O/mut"
cp $R/rtl/video/v9968/*.v "$O/mut/"
python3 - "$O/mut/vdp_cpu_interface.v" <<'P'
import sys
p = sys.argv[1]; s = open(p).read()
old = "else if( intr_line && ff_line_interrupt_enable ) begin"
if s.count(old) != 1: sys.exit("mutant: anchor not found in vdp_cpu_interface.v (the gate moved?)")
open(p, "w").write(s.replace(old, "else if( intr_line ) begin", 1))
P
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
for b in cur mut; do "$O/$b/tb" +m128=1 +fhoff=6 > "$O/$b.log" 2>&1 & done; wait
c=$(grep 'FHOFF RESULT' "$O/cur.log"); m=$(grep 'FHOFF RESULT' "$O/mut.log")
echo "  current: ${c:-missing}"; echo "  mutant:  ${m:-missing}"
cf=$(echo "$c" | sed -n 's/.* \([0-9]*\) read FH=1.*/\1/p'); mf=$(echo "$m" | sed -n 's/.* \([0-9]*\) read FH=1.*/\1/p')
cg=$(echo "$c" | sed -n 's/FHOFF RESULT: \([0-9]*\) of.*/\1/p')
if [ "$cg" = 6 ] && [ "$cf" = 0 ] && [ -n "$mf" ] && [ "$mf" -gt 0 ]; then
    echo "RESULT PASS: FH stays 0 with IE1 off (6/6), mutant reads FH = 1 ($mf/6)"
else
    echo "RESULT FAIL"
fi
