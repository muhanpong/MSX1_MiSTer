#!/usr/bin/env bash
#  sdram_tdm bench (sdram128 study): both board maps, several seeds and loads,
#  and four negative controls that must each be caught.
#    sim/sdram_tdm/run.sh [quick]          OUT=<dir>  P=<jobs>
#  Verilator 5 (Homebrew first on PATH; the system one is 4.038).
set -u
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
O=${OUT:-/tmp/sdram_tdm.$$}; mkdir -p "$O"
FAIL=0; fail() { echo "  FAIL: $*"; FAIL=1; }
build() {  # name defines...
    local n=$1; shift
    rm -rf "$O/$n"
    verilator --binary --timing -j 8 -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
        "$@" --top-module tb -Mdir "$O/$n" -o tb \
        $R/rtl/peripheral/sdram_tdm.sv $HERE/sdram_chk.sv $HERE/tb_tdm.sv > "$O/$n.build.log" 2>&1
    [ -x "$O/$n/tb" ] || fail "$n did not build: $(grep -m2 %Error "$O/$n.build.log")"
}
for v in "b128:" "b32:-DONECHIP" "msens:-DONECHIP -DTDM_MUT_SENS" "mbank:-DTDM_MUT_BANK" \
         "mnoref:-DTDM_MUT_NOREF" "mcap:-DTDM_MUT_CAP" "mcape:-DTDM_MUT_CAPE"; do
    build ${v%%:*} ${v#*:} &
done; wait
CYC=${CYC:-400000}; [ "${1:-}" = quick ] && CYC=120000
SEEDS="1 2 3 4"; [ "${1:-}" = quick ] && SEEDS="1 2"
jobs=()
for sd in $SEEDS; do for bz in 15 50; do
    jobs+=("b128 1 $sd $bz" "b32 0 $sd $bz")
done; done
for m in "msens 0" "mbank 1" "mnoref 1" "mcap 1" "mcape 1"; do jobs+=("$m 1 50"); done
printf '%s\n' "${jobs[@]}" | xargs -P "${P:-16}" -L1 bash -c \
    '"'"$O"'"/$0/tb +m128=$1 +seed=$2 +busy=$3 +cycles='"$CYC"' > "'"$O"'"/run_$0_$1_$2_$3.log 2>&1'
n=0; p=0
for f in "$O"/run_b*.log; do
    n=$((n+1)); grep -q "TDM RESULT PASS" "$f" && p=$((p+1)) || fail "$(basename $f): $(grep -m2 'ERR\|RESULT' $f | tr '\n' ' ')"
done
echo "engine runs: $n, pass: $p"
grep -h "max latency\|cache hits\|chip:" "$O/run_b128_1_1_50.log" "$O/run_b32_0_1_50.log" | sed 's/^/  /'
for m in msens mbank mnoref mcap mcape; do
    f=$(ls "$O"/run_${m}_*.log); 
    if grep -q "TDM RESULT PASS" "$f"; then fail "mutant $m passed (negative control broken)"
    else echo "  mutant $m caught: $(grep -m1 'SDCHK ERR\|TDM ERR' $f | cut -c1-110)"; fi
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "RESULT PASS: sdram_tdm" || echo "RESULT FAIL: sdram_tdm"
exit $FAIL
