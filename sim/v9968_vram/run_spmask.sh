#!/usr/bin/env bash
#  R#25 MSK hides sprites at screen X 0-7 (WBML V9968 dashboard: sprites at X=0 showed one dot
#  into the masked strip).  One-dot sprites at X=7 (must be hidden) and X=8 (must show), sprite
#  modes 2 and 3, SCREEN 8, MSK=1; the mutant gates at position 14 and must fail.
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
build cur "" & build mut "+define+SPRITE_MASK_POS=10'd14" & wait
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
c=$(check cur); m=$(check mut)
echo "current: $c wrong of 4; mutant (mask at 14): $m wrong of 4"
[ "$c" -eq 0 ] && [ "$m" -gt 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
