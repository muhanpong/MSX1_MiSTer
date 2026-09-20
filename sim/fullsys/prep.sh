#!/usr/bin/env bash
#  Prepare every source rtl/msx.sv needs so that the WHOLE machine simulates in
#  Verilator, instead of being probed on hardware.
#
#      sim/fullsys/prep.sh [outdir]         # default: sim/fullsys/gen
#
#  Output: gen/{t80s,vdp,vdp18_core,rtc}.v, gen/sv/ (patched SystemVerilog) and
#  gen/filelist.txt -- the exact set Quartus compiles, minus MSX1.sv, with the
#  VHDL replaced and package.sv first.  Feed that list to verilator.
#
#  Why this exists (2026-09-20): every "it only misbehaves on the board" hunt so
#  far has cost a 20-minute Quartus build plus a board round trip per question,
#  because sim/ holds 25 block-level benches and NOTHING that runs rtl/msx.sv.
#  The blocker was language: the CPU (T80*.vhd) and both VDPs are VHDL, which
#  Verilator cannot read.  `ghdl synth --out=verilog` emits a Verilog netlist
#  that Verilator compiles and simulates, so the blocker is gone.
#
#  Every patch below is applied to a COPY under $OUT, so rtl/ stays exactly what
#  the board runs.  The VHDL ones:
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
cp rtl/video/vdp18/*.vhd "$OUT/src/"
cp rtl/peripheral/rtc.vhd "$OUT/src/"
cp rtl/peripheral/ram.vhd "$OUT/src/"   # COMPONENT RAM: three VDP blocks AND rtc.vhd:589
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
#  `label : work.thing port map (...)` is a COMPONENT instantiation naming a
#  component called work.thing, which does not exist; the entity form needs the
#  keyword.  Quartus accepts the shorthand, ghdl says "component name expected,
#  found entity".  vdp18 and rtc use it throughout.
import re
n = 0
for p in sorted(d.glob("*.vhd")):
    s = p.read_text()
    t = re.sub(r'(?mi)^(\s*\w+\s*:\s*)work\.', r'\1entity work.', s)
    if t != s: p.write_text(t); n += 1
print(f"patches applied ({n} files needed the entity keyword)")
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
ghdl -a $GHDL_FLAGS ../src/vdp_package.vhd ../src/vdp_slot_pack.vhd \
                    ../src/vdp18_pack-p.vhd ../src/vdp18_col_pack-p.vhd
#  Leaves before tops.  vdp18 instantiates its sub-entities DIRECTLY (rather than
#  through a component declaration, the way the MSX2 VDP does), so ghdl must have
#  compiled them first -- and *_core.vhd sorts before *_cpuio.vhd.
for f in ../src/*.vhd; do
   case "$(basename "$f")" in
      vdp_package.vhd|vdp_slot_pack.vhd|vdp18_pack-p.vhd|vdp18_col_pack-p.vhd|T80*.vhd)
         continue;;
      vdp.vhd|vdp18_core.vhd|rtc.vhd) continue;;     # tops, below
   esac
   ghdl -a $GHDL_FLAGS "$f"
done
ghdl -a $GHDL_FLAGS ../src/vdp.vhd ../src/vdp18_core.vhd ../src/rtc.vhd
ghdl synth $GHDL_FLAGS --latches --out=verilog VDP        > "$OUT/vdp.v"
ghdl synth $GHDL_FLAGS --latches --out=verilog vdp18_core > "$OUT/vdp18_core.v"
ghdl synth $GHDL_FLAGS --latches --out=verilog rtc        > "$OUT/rtc.v"

cd "$ROOT"

#  ghdl synth bakes the generics in and emits a module with no parameter list,
#  but msx.sv instantiates these two WITH parameters.  The values it passes are
#  the VHDL defaults, so the hardware is already right; the generated modules
#  just have to accept the names.  If msx.sv ever passes something else, this is
#  where it would silently stop mattering -- so assert the values here.
grep -q 'T80s #(.Mode(0), .T2Write(1), .IOWait(1))' rtl/msx.sv \
  || { echo "GEN-FAIL: msx.sv no longer instantiates T80s with the VHDL default generics"; exit 1; }
grep -q 'vdp18_core #(.compat_rgb_g(0))' rtl/msx.sv \
  || { echo "GEN-FAIL: msx.sv no longer instantiates vdp18_core with compat_rgb_g(0)"; exit 1; }
sed -i 's/^module T80s$/module T80s #(parameter Mode = 0, T2Write = 1, IOWait = 1)/' "$OUT/t80s.v"
sed -i 's/^module vdp18_core$/module vdp18_core #(parameter compat_rgb_g = 0)/' "$OUT/vdp18_core.v"
grep -q '^module T80s #' "$OUT/t80s.v"      || { echo "GEN-FAIL: T80s parameter header not applied"; exit 1; }
grep -q '^module vdp18_core #' "$OUT/vdp18_core.v" || { echo "GEN-FAIL: vdp18_core parameter header not applied"; exit 1; }

#  VHDL is case-insensitive, Verilog is not: ghdl emits `module VDP` and msx.sv
#  writes `vdp vdp_vdp`.  Rename the top only -- the sub-entities keep theirs.
sed -i 's/^module VDP$/module vdp/' "$OUT/vdp.v"
grep -q '^module vdp$' "$OUT/vdp.v" || { echo "GEN-FAIL: VDP top not renamed"; exit 1; }

check() {   # file  top-module
   [ -s "$1" ] || { echo "GEN-FAIL: $1 is empty"; exit 1; }
   verilator --lint-only -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
             -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-BLKSEQ -Wno-CASEINCOMPLETE \
             --top-module "$2" "$1" "$ROOT/sim/fullsys/stubs.sv" > /dev/null \
      || { echo "GEN-FAIL: verilator rejects $1"; exit 1; }
   echo "ok  $(basename "$1")  $(wc -l < "$1") lines, $(grep -c '^module' "$1") modules"
}
check "$OUT/t80s.v"      T80s
check "$OUT/vdp.v"       vdp
check "$OUT/vdp18_core.v" vdp18_core
check "$OUT/rtc.v"       rtc

#  ----------------------------------------------------------------------------
#  SystemVerilog the build accepts and Verilator does not.  Patched copies, so
#  rtl/ stays exactly what the board runs.
mkdir -p "$OUT/sv"
cp rtl/peripheral/wd1793.sv "$OUT/sv/"
python3 - "$OUT/sv" <<'PY'
import pathlib, sys, re
d = pathlib.Path(sys.argv[1])
#  spt_addr is declared inside `generate if(EDSK)` but assigned from the main
#  always block outside it.  Quartus resolves that; Verilator will not, and with
#  EDSK=0 (which is how fdc.sv instantiates it) the declaration is not even
#  emitted.  Hoist the declaration to module scope: unused when EDSK=0,
#  identical when EDSK=1.
p = d / "wd1793.sv"; s = p.read_text()
#  Two regs are declared INSIDE a `generate if(...)` and assigned from the main
#  always blocks outside it: spt_addr (in the EDSK block) and buff_wr (in the
#  RWMODE block).  Quartus resolves that; Verilator will not, and when the
#  generate arm is not taken the declaration does not even exist.  Hoist both to
#  module scope: unused when the arm is off, identical when it is on.
for decl, anchor in (("\t\treg  [7:0] spt_addr;\n", "generate\n\tif(EDSK) begin\n"),
                     ("\t\treg buff_wr;\n",         "generate\n\tif(RWMODE) begin\n")):
    assert decl in s, f"wd1793.sv: {decl.strip()} not found"
    assert anchor in s, f"wd1793.sv: generate for {decl.strip()} not found"
    s = s.replace(decl, "")
    s = s.replace(anchor, decl.strip() + "   // sim: hoisted out of the generate below\n" + anchor, 1)
p.write_text(s)
print("sv patches applied")
PY

#  ----------------------------------------------------------------------------
#  The file list the bench compiles: exactly what Quartus compiles, with the
#  VHDL replaced by the generated Verilog, the patched copies substituted, and
#  package.sv first (Verilator will not look ahead for the struct typedefs).
python3 - "$ROOT" "$OUT" <<'PY' > "$OUT/filelist.txt"
import os, re, sys
root, out = sys.argv[1], sys.argv[2]
seen, files = set(), []
def scan(qip):
    qip = os.path.normpath(qip)
    if qip in seen or not os.path.exists(qip): return
    seen.add(qip); d = os.path.dirname(qip)
    for line in open(qip, errors="ignore"):
        s = line.split("#")[0].strip()
        m = re.search(r"-name\s+(QIP_FILE|SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE)\s+(.*)$", s)
        if not m: continue
        kind, rest = m.group(1), m.group(2).strip()
        mm = re.search(r"qip_path\)\s+([^\s\]]+)", rest)
        p = os.path.normpath(os.path.join(d, mm.group(1) if mm else rest.strip('"[] ')))
        if kind == "QIP_FILE": scan(p)
        elif kind != "VHDL_FILE": files.append(p)
os.chdir(root); scan("files.qip")
sub = {"rtl/peripheral/wd1793.sv": out + "/sv/wd1793.sv"}
files = [f for f in files if f != "MSX1.sv"]           # MiSTer top: not the machine
print("rtl/package.sv")
for f in files:
    if f == "rtl/package.sv": continue
    print(sub.get(f, f))
for g in ("stubs.sv",): print(root + "/sim/fullsys/" + g)
for g in ("t80s.v", "vdp.v", "vdp18_core.v", "rtc.v"): print(out + "/" + g)
PY
echo "filelist: $(wc -l < "$OUT/filelist.txt") files -> $OUT/filelist.txt"
