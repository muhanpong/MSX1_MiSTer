#!/usr/bin/env bash
#  The 4 MB VRAM (V9968 v0.99.11+, R#28-R#30): the CPU bank register through the V9968, the
#  link and sdram_tdm.  Banks 0, 1, 9 and 15 each get their own bytes at 01230h and are read
#  back: all four distinct on the 128 MB and the 32 MB map (there banks 8-15 are bank 3's rows
#  01, whose V ACT masks a G2 word: the 32 MB build counts masked words, the data check
#  judges).  Negative control: +bank=2 reads every bank with R#28 = 0 and must FAIL.
#    sim/v9968_vram/run_bank.sh   OUT=<dir>
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/v9968_bank.$$}; mkdir -p "$O"
build() {  # name defines...
    local n=$1; shift
    rm -rf "$O/$n"
    verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        "$@" -GRELEASE_PH=5 --top-module tb -Mdir "$O/$n" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $HERE/../sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $R/rtl/video/v9968/*.v $R/rtl/video/v9968_cmdwait.sv $HERE/tb_v9968_vram.sv > "$O/$n.build.log" 2>&1
    [ -x "$O/$n/tb" ] || { echo "RESULT FAIL: build $n: $(grep -m2 %Error "$O/$n.build.log")"; exit 1; }
}
build two & build one -DONECHIP -DCHK_ALLOW_MASKED & wait
"$O/two/tb" +m128=1 +bank=1 > "$O/m128.log" 2>&1 &
"$O/one/tb" +m128=0 +bank=1 > "$O/m32.log" 2>&1 &
"$O/two/tb" +m128=1 +bank=2 > "$O/neg.log" 2>&1 &
wait
ok=1
for r in m128:PASS m32:PASS neg:FAIL; do
    n=${r%%:*}; want=${r##*:}
    got=$(grep -ho 'BANK RESULT [A-Z]*' "$O/$n.log" | awk '{print $3}')
    echo "  $n: $(grep -h '^BANK m128' "$O/$n.log") -> ${got:-none} (want $want)"
    grep -h 'SDCHK ERR\|TB ERR' "$O/$n.log" | head -3
    [ "$got" = "$want" ] || ok=0
    [ "$n" != neg ] && grep -q 'SDCHK ERR' "$O/$n.log" && ok=0
done
[ $ok = 1 ] && echo "RESULT PASS" || echo "RESULT FAIL"
