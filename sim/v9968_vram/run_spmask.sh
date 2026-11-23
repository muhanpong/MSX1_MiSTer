#!/usr/bin/env bash
#  R#25 MSK hides sprites at screen X 0-7 (WBML V9968 dashboard: sprites at X=0 showed one dot
#  into the masked strip).  One-dot sprites at X=7 (must be hidden) and X=8 (must show), sprite
#  modes 2 and 3, SCREEN 8, MSK=1.  Plus the G5 case below.
#  Since upstream v0.99.x (merged 2026-11-24) the palette masks sprites with the BG display
#  enable itself, and the core's own gate (2026-11-01) was retired.  The mutants now break
#  upstream's mask: (a) the enable tied to 1 (X=7 must then show), (c) the mask 24 columns wide
#  in every mode (the G5 logo must then show a bitmap run before the sprite).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/v9968_spmask.$$}; mkdir -p "$O"
rm -rf "$O/ma" "$O/mc"; mkdir -p "$O/ma" "$O/mc"
cp $R/rtl/video/v9968/*.v "$O/ma/"; cp $R/rtl/video/v9968/*.v "$O/mc/"
python3 - "$O" <<'P' || { echo "RESULT FAIL: mutant anchor (the palette's mask moved?)"; exit 1; }
import sys; O = sys.argv[1]
o = "ff_display_color_delay0_en <= display_color_screen_mode_en;"
for d, n in (("ma", "ff_display_color_delay0_en <= 1'b1;"),
             ("mc", "ff_display_color_delay0_en <= display_color_screen_mode_en & (screen_pos_x[13:4] >= 10'd24);")):
    p = O + "/" + d + "/vdp_color_palette.v"; s = open(p).read()
    if s.count(o) != 1: sys.exit(1)
    open(p, "w").write(s.replace(o, n))
P
build() {  # name v9968-dir
    verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        -GRELEASE_PH=5 --top-module tb -Mdir "$O/b_$1" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $R/sim/sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $2/*.v $R/rtl/video/v9968_cmdwait.sv $HERE/tb_v9968_vram.sv > "$O/$1.build.log" 2>&1
}
build cur $R/rtl/video/v9968 & build mut "$O/ma" & build mut5 "$O/mc" & wait
check() {  # binary -> prints ok/bad count
    local b=$1 bad=0
    for c in "spx 7 hide" "spx 8 show" "sp3x 7 hide" "sp3x 8 show"; do
        set -- $c
        n=$("$O/b_$b/tb" +m128=1 +ms=0 +bytes=16 +mskt=1 +mskv=1 +$1=$2 | grep -c -E 'MSKT .*run (ff0000|7b0000) ')
        if [ "$3" = hide ] && [ "$n" -ne 0 ]; then bad=$((bad+1)); fi
        if [ "$3" = show ] && [ "$n" -eq 0 ]; then bad=$((bad+1)); fi
    done
    echo $bad
}
#  G5 (512 dots, the GT boot logo): a sprite over a colour-1 bitmap at X=0 must cover it right up to
#  the mask -- no bitmap-colour (2ee32e) run before the sprite's first 7bff7b run (rbf 20261101a
#  opened a one-pixel black column in the GT logo).
g5gap() { "$O/b_$1/tb" +m128=1 +ms=0 +bytes=16 +mskt=1 +g5=1 | grep G5MSK | awk '/7bff7b/{exit} /2ee32e/{n++} END{print n+0}'; }
c=$(check cur); m=$(check mut); g=$(g5gap cur); gm=$(g5gap mut5)
echo "current: $c wrong of 4; mutant (mask off): $m wrong of 4"
echo "G5: current $g bitmap runs before the sprite; mutant (mask 24 wide) $gm"
[ "$c" -eq 0 ] && [ "$m" -gt 0 ] && [ "$g" -eq 0 ] && [ "$gm" -gt 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
