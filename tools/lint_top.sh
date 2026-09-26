#!/usr/bin/env bash
#  Lint the MiSTer TOP (MSX1.sv), not just the machine.
#
#      tools/lint_top.sh
#
#  sim/fullsys's file list deliberately leaves MSX1.sv out -- it simulates the
#  machine, not the MiSTer wrapper -- so a wrong port on an instance in there is
#  invisible to every bench and only Quartus finds it, 25 minutes into a build.
#  That happened on 2026-09-24: `.dbg_wait_ratio(...)` appears on two instances,
#  an edit meant for `msx MSX` landed on the debug overlay, and the build failed
#  in Analysis & Synthesis with "Port midi_rx does not exist in u_overlay".
#
#  MODMISSING is expected and filtered out: hps_io, pll, video_mixer, sd_card
#  and friends are the framework's, live in sys/, and are not part of this.
#  What is left is what matters -- a port that does not exist on a module
#  Verilator can see, which is everything under rtl/.
set -eu
cd "$(dirname "$0")/.."
[ -s sim/fullsys/gen/filelist.txt ] || sim/fullsys/prep.sh > /dev/null

OUT=${OUT:-/tmp/lint_top}
mkdir -p "$OUT"
verilator --lint-only -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME \
   -Wno-UNUSEDSIGNAL -Wno-PINMISSING -Wno-CASEINCOMPLETE \
   -Wno-MULTIDRIVEN -Wno-IMPLICIT -Wno-BLKANDNBLK -Wno-LATCH -Wno-SIDEEFFECT \
   -Wno-TIMESCALEMOD -Wno-ASCRANGE -Wno-SELRANGE \
   --top-module emu +incdir+sim/fullsys/gen \
   $(cat sim/fullsys/gen/filelist.txt) MSX1.sv > "$OUT/lint.log" 2>&1 || true

if grep -E '%Error' "$OUT/lint.log" | grep -qv -E 'MODMISSING|Exiting due to'; then
   echo "RESULT FAIL: top-level lint"
   grep -E '%Error' "$OUT/lint.log" | grep -v -E 'MODMISSING|Exiting due to' | head -20
   exit 1
fi
echo "top lint: clean"
