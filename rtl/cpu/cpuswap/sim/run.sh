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
  --top-module tb -Mdir "$obj/vl" "$here/tb_swap.sv" "$cpu/cpuswap/cpuswap_ctl.sv" "$cpu/cpuswap/nz_bus.sv" "$cpu/../peripheral/turbor/turbor.sv" "$cpu/../peripheral/turbor/pcm_play.sv" "$obj/t80/t80s.v" \
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
#  SDRAM-like memory: data home 4 clocks after the request (the most an unpaced T80s at CEN/6
#  tolerates), WAIT until home for NextZ80, turbo T80s and the resume guard after a hand-over.
printf '%-14s ' "sdram stock";   run sdstock +mode=2 +seed=1 +t80div=6 +sdlat=4 +maxclk=8000000; check sdstock SAME
printf '%-14s ' "sdram st every"; run sdstall +mode=2 +swapmin=0 +swapmax=0 +t80div=6 +sdlat=4 +maxclk=12000000; check sdstall SAME
printf '%-14s ' "sdram turbo";   run sdturbo +mode=2 +swapmin=0 +swapmax=0 +sdlat=7 +turbo=1 +maxclk=12000000; check sdturbo SAME
printf '%-14s ' "sdram nz";      run sdnz +mode=1 +sdlat=6 +maxclk=8000000; check sdnz SAME
printf '%-14s ' "sdram soft";    run sdsoft +mode=3 +t80div=6 +sdlat=4 +maxclk=12000000; check sdsoft SAME
printf '%-14s ' "no resume grd"; run sdnorg +mode=2 +seed=1 +t80div=6 +sdlat=4 +norg=1 +maxclk=8000000; check sdnorg DIFF
#  R800 MULUB / MULUW: NextZ80 only -- a Z80 executes these as NOPs, so this is not a
#  lockstep run.  The OUT log is compared with gen_mulref.py, which encodes the R800
#  rules independently of the RTL.
( cd "$obj" && "$SJASMPLUS" --nologo --lst=multest.lst "$here/multest.asm" ) > "$out/asm_mul.log" 2>&1 \
  || { echo "mul assembly failed, see $out/asm_mul.log"; fail=1; }
python3 -c "
import sys; d=open('$obj/multest.bin','rb').read()
open('$obj/multest.hex','w').write('\n'.join('%02x'%b for b in d)+'\n')"
python3 "$here/gen_mulref.py" > "$out/mulref.trace"
printf '%-14s ' "R800 multiply"
"$obj/vl/Vtb" +mode=1 +intper=0 +prog=$obj/multest.hex +maxclk=2000000 > "$out/mul.log" 2>&1
grep '^O ' "$out/mul.log" > "$out/mul.trace"
printf '%s  ' "$(grep -E '^(END|TIMEOUT)' "$out/mul.log")"
if cmp -s "$out/mulref.trace" "$out/mul.trace"; then echo "PASS ($(wc -l < "$out/mul.trace") OUTs match the R800 model)"
else echo "FAIL $(diff "$out/mulref.trace" "$out/mul.trace" | head -4 | tr '\n' ' ')"; fail=1; fi

#  PCMPLY hardware player: the CPU is parked inside the 0186h fetch while the player
#  reads the samples itself, so the trace (D lines + the Z pcm summary) must be the
#  same whichever core is parked and at whatever divisor.  Its own reference run is
#  T80s, since the program is not swaptest.
( cd "$obj" && "$SJASMPLUS" --nologo --lst=pcmtest.lst "$here/pcmtest.asm" ) > "$out/asm_pcm.log" 2>&1 \
  || { echo "pcm assembly failed, see $out/asm_pcm.log"; fail=1; }
python3 -c "
import sys; d=open('$obj/pcmtest.bin','rb').read()
open('$obj/pcmtest.hex','w').write('\n'.join('%02x'%b for b in d)+'\n')"
pcmargs="+prog=$obj/pcmtest.hex +intper=0 +maxclk=4000000"
checkp() { local name=$1 expect=$2; local res
  if cmp -s "$out/pcmref.trace" "$out/$name.trace"; then res=SAME; else res=DIFF; fi
  local first=$(diff "$out/pcmref.trace" "$out/$name.trace" | head -3 | tr '\n' ' ')
  if [ "$res" = "$expect" ]; then echo "    PASS ($res) $first"; else echo "    FAIL ($res, expected $expect) $first"; fail=1; fi; }
printf '%-14s ' "pcm t80";     run pcmt80 $pcmargs +mode=0
cp "$out/pcmt80.trace" "$out/pcmref.trace"
nsmp=$(grep -c '^D ' "$out/pcmt80.trace"); nrun=$(grep -c '^Z pcm' "$out/pcmt80.trace")
[ "$nsmp" = 28 ] && [ "$nrun" = 3 ] && echo "    PASS (28 samples over 3 runs)" \
  || { echo "    FAIL ($nsmp samples, $nrun runs; expected 28 over 3)"; fail=1; }
#  Rate: the PCM grid here is 6 * 228 = 1368 clocks; runs 1 and 5 ask for q=0, run 2 for q=1.
printf '%-14s ' "pcm rate"
gaps=$(grep '^R ' "$out/pcmt80.log" | sort -u | awk '{printf "%s ", $2}')
[ "$gaps" = "1368 2736 " ] && echo "PASS (q=0 -> 1368 clocks, q=1 -> 2736)" \
  || { echo "FAIL (sample gaps: $gaps expected 1368 and 2736)"; fail=1; }
printf '%-14s ' "pcm nz";      run pcmnz  $pcmargs +mode=1;                     checkp pcmnz SAME
printf '%-14s ' "pcm swaps";   run pcmsw  $pcmargs +mode=2 +seed=3;             checkp pcmsw SAME
printf '%-14s ' "pcm ce/6";    run pcmdiv $pcmargs +mode=0 +t80div=6;           checkp pcmdiv SAME
printf '%-14s ' "pcm sdram";   run pcmsd  $pcmargs +mode=2 +seed=5 +t80div=6 +sdlat=4; checkp pcmsd SAME
#  CTRL+STOP after 20 samples: the fifth run ends early and returns carry set, so the
#  trace must differ from the reference -- and say so.
printf '%-14s ' "pcm abort";   run pcmab  $pcmargs +mode=0 +pcmstop=20;         checkp pcmab DIFF
if grep -q '^Z pcm 20 1' "$out/pcmab.trace" && grep -q '^O 20 01' "$out/pcmab.trace"; then
  echo "    PASS (aborted at 20 samples, carry set)"
else echo "    FAIL (no aborted run in the trace)"; fail=1; fi
grep -q 'CPU MOVED' "$out"/pcm*.log && { echo "pcm: the parked CPU moved"; fail=1; } || true

printf '%-14s ' "negative";    run neg +mode=2 +seed=1 +corrupt=5; check neg DIFF
[ $fail = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
