#!/usr/bin/env bash
# GoFigure boot-scenario replay: the hardware-verified calibration point.
#
# tb_vdpcmd.vhd reproduces what the game does at boot -- vblank ISR, line
# interrupt at 188, then HMMM 3080 bytes -- and reports whether CE was still
# high when the game's line-188 check ran.  The game treats CE=0 there as
# "Abnormal fast VDP" and fails.  Hardware-measured boundary: a 255.8-line
# HMMM fails, 259.5 passes.  Any change to command timing must be re-checked
# here, because that threshold was found on real hardware, not in simulation.
#
# usage:  sim/run_vdpcmd_gofigure.sh
# env:    OUT=<dir>   default /tmp/vdpcmd_gofigure
#
# Look for:  RESULT: CE_at_FH188='1'   (1 = PASS, 0 = the game would fail)
set -eu
OUT=${OUT:-/tmp/vdpcmd_gofigure}
RTL=rtl/video/VDP
rm -rf "$OUT"; mkdir -p "$OUT"

FLAGS="--std=93c -fsynopsys -fexplicit -frelaxed-rules"
SRC="$RTL/vdp_package.vhd $RTL/vdp_slot_pack.vhd $(ls $RTL/*.vhd | grep -v -e vdp_graphic4567.vhd -e vdp_linebuf.vhd -e vdp_package.vhd -e vdp_slot_pack.vhd)"
SRC="$SRC rtl/peripheral/ram.vhd $RTL/sim/g4567_sim.vhd $RTL/sim/linebuf_sim.vhd $RTL/sim/tb_vdpcmd.vhd"

ghdl -a --workdir="$OUT" $FLAGS -Wno-hide $SRC 2>/dev/null
ghdl -e --workdir="$OUT" $FLAGS TB_VDPCMD 2>/dev/null
ghdl -r --workdir="$OUT" $FLAGS TB_VDPCMD --ieee-asserts=disable \
     > "$OUT/run.log" 2>&1 || true
grep -E "RESULT:|duration:|VBLANK-INT|FH-188" "$OUT/run.log" \
    || { echo "no result -- see $OUT/run.log"; tail -5 "$OUT/run.log"; }
