#!/usr/bin/env bash
#  V9968 on sdram_tdm's V slot (plan S2): every RELEASE_PH 0..11 on the 128 MB map,
#  exactly one must pass (the others are the negative controls); then that one on
#  the 32 MB map.  OUT=<dir>  MS=<ms of display after the CPU test>  P=<jobs>
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/v9968_vram.$$}; mkdir -p "$O"
build() {  # name ph defines...
    local n=$1 ph=$2; shift 2
    rm -rf "$O/$n"; mkdir -p "$O/$n"
    verilator --binary --timing -j 4 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-PINCONNECTEMPTY -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT \
        "$@" ${XDEF:-} -GRELEASE_PH=$ph --top-module tb -Mdir "$O/$n" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $HERE/../sdram_tdm/sdram_chk.sv $R/rtl/video/v9968_link.sv \
        $R/rtl/video/v9968/*.v $HERE/tb_v9968_vram.sv > "$O/$n.build.log" 2>&1
    [ -x "$O/$n/tb" ] || echo "BUILD FAIL $n: $(grep -m2 %Error "$O/$n.build.log")"
}
for ph in $(seq 0 11); do build p$ph $ph & done; wait
for ph in $(seq 0 11); do echo "p$ph"; done | xargs -P "${P:-12}" -I{} sh -c "'$O'/{}/tb +m128=1 +ms=${MS:-0} +bytes=${BYTES:-1024} > '$O'/{}.log 2>&1"
pass=""
for ph in $(seq 0 11); do
    r=$(grep -h "RESULT" "$O/p$ph.log"); echo "  ph $ph: $r | $(grep -h 'latency\|bad latency\|link:' "$O/p$ph.log" | tr -s ' ' | tr '\n' ' ' | cut -c1-200)"
    echo "$r" | grep -q PASS && pass="$pass $ph"
done
echo "passing RELEASE_PH:${pass:- none}"
n=$(echo $pass | wc -w)
[ "$n" -eq 1 ] && echo "RESULT PASS: exactly one phase" || echo "RESULT FAIL: $n phases pass (want exactly 1)"
#  Until plan S3 (refresh of the VRAM's chip) the V slot drops requests on refresh
#  frames and the passing phase still fails on data; build with
#  XDEF=-DTDM_SIM_NO_VCHIP_REFRESH to see S2 alone (the SDRAM model then reports the
#  missing refresh of chip 1 -- expected in that mode).
