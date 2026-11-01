#!/usr/bin/env bash
#  R#25 MSK hides sprites at screen X 0-7 (WBML V9968 dashboard: sprites at X=0 showed one dot
#  into the masked strip).  One-dot sprites at X=7 (must be hidden) and X=8 (must show), sprite
#  modes 2 and 3, SCREEN 8, MSK=1; the mutant gates at position 14 and must fail.
#  Plus the G5 case below.
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/v9968_spmask.$$}; mkdir -p "$O"
build() {  # name extra-defines
    verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        -GRELEASE_PH=5 $2 --top-module tb -Mdir "$O/$1" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $R/sim/sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $R/rtl/video/v9968/*.v $R/rtl/video/v9968_cmdwait.sv $HERE/tb_v9968_vram.sv > "$O/$1.build.log" 2>&1
}
build cur "" & build mut "+define+SPRITE_MASK_POS=10'd14" & build mut5 "+define+SPRITE_MASK_ALLMODES" & wait
check() {  # binary -> prints ok/bad count
    local b=$1 bad=0
    for c in "spx 7 hide" "spx 8 show" "sp3x 7 hide" "sp3x 8 show"; do
        set -- $c
        n=$("$O/$b/tb" +m128=1 +ms=0 +bytes=16 +mskt=1 +mskv=1 +$1=$2 | grep -c -E 'MSKT .*run (ff0000|7b0000) ')
        if [ "$3" = hide ] && [ "$n" -ne 0 ]; then bad=$((bad+1)); fi
        if [ "$3" = show ] && [ "$n" -eq 0 ]; then bad=$((bad+1)); fi
    done
    echo $bad
}
#  G5 (512 dots, the GT boot logo): a sprite over a colour-1 bitmap at X=0 must cover it right up to
#  the mask -- no bitmap-colour (2ee32e) run before the sprite's first 7bff7b run (rbf 20261101a
#  opened a one-pixel black column in the GT logo).  Mutant: 20261101a's rule in every mode.
g5gap() { "$O/$1/tb" +m128=1 +ms=0 +bytes=16 +mskt=1 +g5=1 | grep G5MSK | awk '/7bff7b/{exit} /2ee32e/{n++} END{print n+0}'; }
c=$(check cur); m=$(check mut); g=$(g5gap cur); gm=$(g5gap mut5)
echo "current: $c wrong of 4; mutant (mask at 14): $m wrong of 4"
echo "G5: current $g bitmap runs before the sprite; mutant (20261101a rule) $gm"
[ "$c" -eq 0 ] && [ "$m" -gt 0 ] && [ "$g" -eq 0 ] && [ "$gm" -gt 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
