#!/usr/bin/env bash
# cpuswap lockstep bench (Verilator 4.x).
#
#   GHDL=<ghdl 4.x binary> SJASMPLUS=<sjasmplus> rtl/cpu/cpuswap/sim/run.sh [seeds]
#
# 1. T80s is synthesised to Verilog with GHDL from rtl/cpu (sim copy: one bit-string
#    literal width fixed, T80.vhd:611, which GHDL rejects and Quartus accepts).
# 2. swaptest.asm is assembled; the bench runs it as T80s only (reference), NextZ80
#    only, and with random swaps for each seed; plus a negative control that flips
#    one bit of one transfer and must FAIL.
# The data-write/OUT log (E000h-FFFFh excluded) must be identical to the reference.
set -u
here=$(cd "$(dirname "$0")" && pwd); cpu=$here/../..; obj=$here/obj; out=$here/out
seeds=${1:-"1 2 3 4 5 6 7 8"}
GHDL=${GHDL:?set GHDL}; SJASMPLUS=${SJASMPLUS:?set SJASMPLUS}
rm -rf "$obj" "$out"; mkdir -p "$obj/t80" "$out"

cp "$cpu"/T80_Pack.vhd "$cpu"/T80_ALU.vhd "$cpu"/T80_MCode.vhd "$cpu"/T80_Reg.vhd "$cpu"/T80.vhd "$cpu"/T80s.vhd "$obj/t80/"
sed -i 's/(ioq and x"7")/(ioq and "000000111")/' "$obj/t80/T80.vhd"
( cd "$obj/t80" && "$GHDL" -a --std=08 -fsynopsys -frelaxed T80_Pack.vhd T80_ALU.vhd T80_MCode.vhd T80_Reg.vhd T80.vhd T80s.vhd \
  && "$GHDL" --synth --std=08 -fsynopsys -frelaxed --out=verilog T80s > t80s.v ) > "$out/ghdl.log" 2>&1 \
  || { echo "GHDL failed, see $out/ghdl.log"; exit 1; }
# GHDL 4.1 emits identifiers like u0_\reg (backslash mid-name), which is not Verilog.
sed -i 's/\([A-Za-z0-9_]\)\\\([A-Za-z0-9_]*\) /\1_\2_ /g' "$obj/t80/t80s.v"

( cd "$obj" && "$SJASMPLUS" --nologo --lst=swaptest.lst "$here/swaptest.asm" ) > "$out/asm.log" 2>&1 || { echo "assembly failed, see $out/asm.log"; exit 1; }
python3 -c "
import sys; d=open('$obj/swaptest.bin','rb').read()
open('$obj/swaptest.hex','w').write('\n'.join('%02x'%b for b in d)+'\n')"

nz=$cpu/nextz80/patched
verilator --cc --exe --build -j 8 -O2 +1364-2005ext+v +1800-2012ext+sv -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-COMBDLY -Wno-TIMESCALEMOD \
  --top-module tb -Mdir "$obj/vl" "$here/tb_swap.sv" "$cpu/cpuswap/cpuswap_ctl.sv" "$cpu/../peripheral/turbor/turbor.sv" "$obj/t80/t80s.v" \
  "$nz/nextz80cpu.v" "$nz/nextz80reg.v" "$nz/nextz80alu.v" "$here/sim_main.cpp" > "$out/build.log" 2>&1 \
  || { echo "verilator build failed, see $out/build.log"; exit 1; }

# explicit plusargs come first on the command line: $value$plusargs takes the first match
common="+prog=$obj/swaptest.hex +intper=40000"
# OUTs to A4h/A5h are left out: with BUFF on, a pending D/A value may land on the
# tick just before the BUFF-off write, so their order against the D lines is timing.
filt() { awk '$1=="W" { if (strtonum("0x"$2) < 0xE000) print; next } $1=="O" && $2 != "a4" && $2 != "a5" || $1=="P" || $1=="E" || $1=="D" || $1=="M" || $1=="Z" { print }' "$1"; }
run() { local name=$1; shift; "$obj/vl/Vtb" "$@" $common > "$out/$name.log" 2>&1; filt "$out/$name.log" > "$out/$name.trace";
        grep -E '^(END|TIMEOUT)' "$out/$name.log" | tr '\n' ' '; echo; }

fail=0
printf '%-14s ' ref;   run ref +mode=0
nref=$(wc -l < "$out/ref.trace")
check() { local name=$1 expect=$2; local res
  if cmp -s "$out/ref.trace" "$out/$name.trace"; then res=SAME; else res=DIFF; fi
  local first=$(diff "$out/ref.trace" "$out/$name.trace" | head -3 | tr '\n' ' ')
  if [ "$res" = "$expect" ]; then echo "    PASS ($res, $nref trace lines) $first"; else echo "    FAIL ($res, expected $expect) $first"; fail=1; fi; }
printf '%-14s ' nz;    run nz +mode=1;   check nz SAME
for s in $seeds; do
  printf '%-14s ' "swap seed=$s"; run swap$s +mode=2 +seed=$s; check swap$s SAME
done
printf '%-14s ' "swap div=3";  run swapdiv +mode=2 +seed=11 +t80div=3; check swapdiv SAME
printf '%-14s ' "swap every";  run swapall +mode=2 +swapmin=0 +swapmax=0; check swapall SAME
printf '%-14s ' "every, int";  run swapallint +mode=2 +swapmin=0 +swapmax=0 +intper=997; check swapallint SAME
eipc=$(awk '/ld \(EIMARK\),a +; must run/ { print $2; exit }' "$obj/swaptest.lst")
#  A transfer at the instruction after EI must never happen (either direction); INT is
#  raised on it so a core that then takes the interrupt early also trips the program.
#  Several swap rhythms (delays spanning a few instructions), so that both cores
#  execute the EI in some iteration.
for v in "0 0 1" "0 12 5" "3 30 9" "0 8 13" "6 20 17"; do set -- $v
  printf '%-14s ' "EI rhythm $1-$2"; run swapei$3 +mode=2 +swapmin=$1 +swapmax=$2 +seed=$3 +eipc=$eipc; check swapei$3 SAME
  echo "    transfers at the EI-delay instruction (${eipc}h): $(grep -c '^E transfer' "$out/swapei$3.log")"
done
printf '%-14s ' "software S1990"; run soft +mode=3; check soft SAME
n=$(grep -c '^X' "$out/soft.log"); [ "$n" = 24 ] && echo "    PASS (24 port-driven switches)" || { echo "    FAIL ($n port-driven switches, expected 24)"; fail=1; }
printf '%-14s ' "negative";    run neg +mode=2 +seed=1 +corrupt=5; check neg DIFF
[ $fail = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
