#!/usr/bin/env bash
#  sdram_tdm bench (sdram128 study): both board maps, several seeds and loads,
#  the stock-speed CPU deadline (+stock, ch2 byte taken at E0+28 with no
#  handshake, CPU in bank 0 rows 00 like a machine's BIOS/RAM), and negative
#  controls that must each be caught.
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
for v in "b128:" "b32:-DONECHIP" "i32:-DONECHIP" "msens:-DONECHIP -DTDM_MUT_SENS" "mbank:-DTDM_MUT_BANK" \
         "mnoref:-DTDM_MUT_NOREF" "mcap:-DTDM_MUT_CAP" "mcape:-DTDM_MUT_CAPE" "mrdy:-DTDM_MUT_RDY" "mrfslow:-DONECHIP -DTDM_MUT_RFSLOW" "b64:-DCHIP64" "mno64:-DCHIP64 -DTDM_MUT_NO64" "mrsv:-DONECHIP -DTDM_MUT_NORSV" "mlate:-DONECHIP -DTDM_MUT_LATEHOLD" "mrdover:-DTDM_MUT_RDOVER" "mdropgap:-DONECHIP -DTDM_MUT_DROPGAP" "mnobusy:-DONECHIP -DTDM_MUT_NOBUSY"; do
    build ${v%%:*} ${v#*:} &
done; wait
CYC=${CYC:-400000}; [ "${1:-}" = quick ] && CYC=120000
SEEDS="1 2 3 4"; [ "${1:-}" = quick ] && SEEDS="1 2"
jobs=()
for sd in $SEEDS; do for bz in 15 50; do
    jobs+=("b128 1 $sd $bz" "b32 0 $sd $bz" "b128 1 $sd $bz +stock=1 +cpulow=1" "b32 0 $sd $bz +stock=1 +cpulow=1" "b64 0 $sd $bz +m64=1" "b32 0 $sd $bz +stock=1 +cpulow=2" "b128 1 $sd $bz +r800wr=1" "b32 0 $sd $bz +r800wr=1" "b32 0 $sd $bz +r800wr=2")
done; done
for m in "msens 0" "mbank 1" "mnoref 1" "mcap 1" "mcape 1" "mrdy 1"; do jobs+=("$m 1 50"); done
#  a grid phase the refresh frame catches without cancellation (9 of 36 do)
#  deadline mutants fail at some grid phases only (12-clock period): three phases
#  each, a longer run, caught if any of them fails
for g in 2 14 26; do jobs+=("mrfslow 0 3 30 +stock=1 +cpulow=1 +gph=$g +cycles=400000"); done
jobs+=("mno64 0 1 50 +m64=1")
#  rows 01 for the CPU: G1 read reservation off / CPU hold a clock late (phases that fail)
for g in 0 12 24; do jobs+=("mrsv 0 3 30 +stock=1 +cpulow=2 +gph=$g +cycles=400000"); done
for g in 3 15 27; do jobs+=("mlate 0 3 30 +stock=1 +cpulow=2 +gph=$g +cycles=400000"); done
jobs+=("mrdover 1 1 50 +r800wr=1")
#  rows 01 at the three grid phases where ch2_req_s's clock matters (2026-10-20,
#  docs/evidence_20261020/tdm_stock_deadline_ven.txt): with v_en = 0 (MSX1.sv
#  today) they must pass on the 32 and 64 MB maps; with v_en = 1 they are LATE
#  at E0+29 -- an open V9968 item, printed below as INFO, not a pass condition.
for g in 3 15 27; do
    jobs+=("b32 0 3 30 +stock=1 +cpulow=2 +ven=0 +gph=$g" "b64 0 3 30 +m64=1 +stock=1 +cpulow=2 +ven=0 +gph=$g")
    jobs+=("i32 0 3 30 +stock=1 +cpulow=2 +gph=$g")
done
#  R800 write then read in the cycle the write's line drop is still due; and no back-pressure
for sd in 1 2 3 4 5 6; do jobs+=("mdropgap 0 $sd 30 +r800wr=1 +cycles=600000"); done
for sd in 1 2 3 4 5 6; do jobs+=("mnobusy 0 $sd 30 +r800wr=2 +cycles=600000"); done
printf '%s\n' "${jobs[@]}" | xargs -P "${P:-16}" -L1 bash -c \
    'x=$(echo "$4$5$6$7$8" | tr -dc a-z0-9); "'"$O"'"/$0/tb $4 $5 $6 $7 $8 +m128=$1 +seed=$2 +busy=$3 +cycles='"$CYC"' > "'"$O"'"/run_$0_$1_$2_$3${x:+_$x}.log 2>&1'
n=0; p=0
for f in "$O"/run_b*.log; do
    n=$((n+1)); grep -q "TDM RESULT PASS" "$f" && p=$((p+1)) || fail "$(basename $f): $(grep -m2 'ERR\|RESULT' $f | tr '\n' ' ')"
done
echo "engine runs: $n, pass: $p"
grep -h "max latency\|cache hits\|chip:" "$O/run_b128_1_1_50.log" "$O/run_b32_0_1_50.log" | sed 's/^/  /'
n=$(grep -l "LATE=[1-9]" "$O"/run_i32_*.log 2>/dev/null | wc -l)
echo "  INFO (open, V9968): 32 MB rows 01 with v_en = 1 at g3/15/27: $n of 3 phases LATE ($(grep -ho 'complete at E0+[0-9]*' "$O"/run_i32_*.log | sort | uniq -c | tr -s ' ' | tr '\n' ' '))"
grep -h "stock:" "$O"/run_b*_stock*.log | sed 's/grid phase [0-9]*: //' | sort | uniq -c | sed 's/^/  /'
for m in msens mbank mnoref mcap mcape mrdy mrfslow mno64 mrsv mlate mrdover mdropgap mnobusy; do
    c=$(grep -L "TDM RESULT PASS" "$O"/run_${m}_*.log | head -1)
    if [ -z "$c" ]; then fail "mutant $m passed (negative control broken)"
    else echo "  mutant $m caught: $(grep -m1 'SDCHK ERR\|TDM ERR\|overflow' $c | cut -c1-110)"; fi
done
echo "════════════════════════════════"
[ $FAIL -eq 0 ] && echo "RESULT PASS: sdram_tdm" || echo "RESULT FAIL: sdram_tdm"
exit $FAIL
