#!/usr/bin/env bash
#  Convert the core's VHDL blocks to Verilog, so that the WHOLE machine can be
#  simulated in Verilator instead of being probed on hardware.
#
#      sim/fullsys/vhd2v.sh [outdir]        # default: sim/fullsys/gen
#
#  Why this exists (2026-09-20): every "it only misbehaves on the board" hunt so
#  far has cost a 20-minute Quartus build plus a board round trip per question,
#  because sim/ holds 25 block-level benches and NOTHING that runs rtl/msx.sv.
#  The blocker was language: the CPU (T80*.vhd) and both VDPs are VHDL, which
#  Verilator cannot read.  `ghdl synth --out=verilog` emits a Verilog netlist
#  that Verilator compiles and simulates, so the blocker is gone.
#
#  Two source patches are needed, and they are applied to COPIES under $OUT/src
#  so rtl/ is never touched:
#
#   * T80.vhd `ioq and x"7"` -- a 9-bit vector ANDed with a 4-bit literal.
#     Quartus zero-extends it (masking the low three bits, which is what the
#     INI/IND/OUTI/OUTD flag rule wants); ghdl synth refuses unequal lengths.
#     Replaced with an explicit 9-bit mask -- same hardware.
#   * vdp_graphic4567.vhd, the FIFO select CASE on a 2-bit std_logic_vector with
#     no WHEN OTHERS.  Strict VHDL wants all nine std_logic values covered.
#     Adds `WHEN OTHERS => NULL;` -- same hardware.
#
#  Anything else that fails here is a real difference between what Quartus
#  accepts and what the language says; fix it the same way, in a patch, with a
#  comment saying why the hardware is unchanged.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD
OUT=${1:-$ROOT/sim/fullsys/gen}
GHDL_FLAGS="--std=08 -frelaxed -fsynopsys"

rm -rf "$OUT"; mkdir -p "$OUT/src" "$OUT/work"

cp rtl/cpu/T80_Pack.vhd rtl/cpu/T80_ALU.vhd rtl/cpu/T80_Reg.vhd \
   rtl/cpu/T80_MCode.vhd rtl/cpu/T80.vhd rtl/cpu/T80s.vhd "$OUT/src/"
cp rtl/video/VDP/*.vhd "$OUT/src/"
cp rtl/peripheral/ram.vhd "$OUT/src/"          # COMPONENT RAM, used by three VDP blocks
rm -f "$OUT/src"/tb_*.vhd "$OUT/src"/*_sim.vhd

python3 - "$OUT/src" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])

p = d / "T80.vhd"; s = p.read_text()
a = 'ioq := (ioq and x"7") xor (\'0\'&BusA);'
assert a in s, "T80.vhd: ioq mask not found -- check whether the source changed"
p.write_text(s.replace(a, 'ioq := (ioq and "000000111") xor (\'0\'&BusA);'))

p = d / "vdp_graphic4567.vhd"; s = p.read_text()
a = '                WHEN "11" =>    FF_FIFO3    <= FIFODATA_OUT;\n                END CASE;'
assert a in s, "vdp_graphic4567.vhd: FIFO case not found -- check whether the source changed"
p.write_text(s.replace(a, '                WHEN "11" =>    FF_FIFO3    <= FIFODATA_OUT;\n'
                          '                WHEN OTHERS =>  NULL;\n                END CASE;'))
print("patches applied")
PY

cd "$OUT/work"
ghdl -a $GHDL_FLAGS ../src/T80_Pack.vhd ../src/T80_ALU.vhd ../src/T80_Reg.vhd \
                    ../src/T80_MCode.vhd ../src/T80.vhd ../src/T80s.vhd
ghdl synth $GHDL_FLAGS --latches --out=verilog T80s > "$OUT/t80s.v"

#  Analyse the packages ONCE.  Listing them again inside a *.vhd glob re-analyses
#  them, which obsoletes every unit already compiled against them -- ghdl then
#  black-boxes those entities and the netlist comes out with five empty holes
#  (VDP_COMMAND, VDP_INTERRUPT, VDP_HVCOUNTER, VDP_NTSC_PAL, VDP_ACCESS_SLOTS)
#  and a zero exit status.  Verilator is what catches it, so the lint below is
#  part of the conversion, not a nicety.
ghdl -a $GHDL_FLAGS ../src/vdp_package.vhd ../src/vdp_slot_pack.vhd
for f in ../src/*.vhd; do
   case "$(basename "$f")" in
      vdp_package.vhd|vdp_slot_pack.vhd|T80*.vhd) continue;;
   esac
   ghdl -a $GHDL_FLAGS "$f"
done
ghdl synth $GHDL_FLAGS --latches --out=verilog VDP > "$OUT/vdp.v"

cd "$ROOT"
for f in "$OUT/t80s.v" "$OUT/vdp.v"; do
   [ -s "$f" ] || { echo "GEN-FAIL: $f is empty"; exit 1; }
   verilator --lint-only -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
             -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-BLKSEQ -Wno-CASEINCOMPLETE \
             --top-module "$(basename "${f%.v}" | tr 'a-z' 'A-Z' | sed 's/T80S/T80s/;s/VDP/VDP/')" "$f" \
      || { echo "GEN-FAIL: verilator rejects $f"; exit 1; }
   echo "ok  $(basename "$f")  $(wc -l < "$f") lines, $(grep -c '^module' "$f") modules"
done
