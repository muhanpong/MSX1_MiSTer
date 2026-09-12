#!/usr/bin/env bash
# Every throttled VDP command, timed in scanlines, against the openMSX reference.
#
# vdp_wait_control.vhd throttles seven opcodes (SRCH, LINE, LMMV, LMMM, HMMV,
# HMMM, YMMM) but only the HMMM entry has ever been calibrated.  This runs all
# seven through the real VDP RTL under the same conditions the openMSX harness
# uses (G4, display ON, sprites ON, NTSC 192 lines) and prints each duration
# next to its reference, so a table entry can be tuned without a board build.
#
# usage:  sim/run_vdpcmd7.sh [CMDSEL]      CMDSEL 0..6 runs one command only
#         (0 HMMV  1 HMMM  2 LMMV  3 LMMM  4 YMMM  5 LINE  6 SRCH)
# env:    OUT=<dir>   (default /tmp/vdpcmd7)
#
# --ieee-asserts=disable is not cosmetic: the VDP feeds X into TO_INTEGER on
# every uninitialised VRAM read, and the resulting warning flood both buries
# the results and costs more run time than the simulation itself.
#
# The openMSX reference is produced by driving CMDCMP.COM under the emulator
# and reading emulated time across each command with breakpoints; see
# tools/vdpprobe/cmdcmp.s and the header of sim/tb_vdpcmd7.vhd.
set -eu
OUT=${OUT:-/tmp/vdpcmd7}
RTL=rtl/video/VDP
rm -rf "$OUT"; mkdir -p "$OUT"

# vdp_graphic4567 and vdp_linebuf instantiate Altera megafunctions; the sim/
# copies are behavioural stand-ins with the same entity names, so they replace
# the synthesis sources rather than joining them.
# Both packages must be analysed before anything that uses them.
SRC="$RTL/vdp_package.vhd $RTL/vdp_slot_pack.vhd $(ls $RTL/*.vhd | grep -v -e vdp_graphic4567.vhd -e vdp_linebuf.vhd -e vdp_package.vhd -e vdp_slot_pack.vhd)"
# vdp_sprite/vdp_register/the g4567 stand-in all instantiate the shared RAM
# entity, which lives outside the VDP directory.
SRC="$SRC rtl/peripheral/ram.vhd $RTL/sim/g4567_sim.vhd $RTL/sim/linebuf_sim.vhd $RTL/sim/tb_vdpcmd7.vhd"

FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed-rules"
ghdl -a --workdir="$OUT" $FLAGS -Wno-hide $SRC 2>/dev/null
# The mcode backend JITs: -e only checks elaboration, -r runs.
ghdl -e --workdir="$OUT" $FLAGS TB_VDPCMD7 2>/dev/null
SEL=${1:--1}
BOARDREGS=${BOARDREGS:-0}
DATACHECK=${DATACHECK:-0}
ghdl -r --workdir="$OUT" $FLAGS TB_VDPCMD7 -gCMDSEL=$SEL -gBOARDREGS=$BOARDREGS -gDATACHECK=$DATACHECK --ieee-asserts=disable \
     > "$OUT/run.log" 2>&1 || true
grep -E "lines +\(openMSX|DATACHECK" "$OUT/run.log" || { echo "no results -- see $OUT/run.log"; tail -5 "$OUT/run.log"; }
