#!/usr/bin/env bash
# run1.sh <variant dir> : build fullsys with that ymf278b_regs.sv and run mprobe Z80+R800 (one run)
set -eu
V=$(cd "$1" && pwd); W=${W:?run1.sh needs W=<worktree>}; cd $W
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
OUT=$V/b; mkdir -p $OUT; GEN=${GEN:-$W/sim/fullsys/gen}
P="/home/sysop/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack/MSX/Panasonic/Panasonic FS-A1GT.MSX"
if [ ! -f $OUT/pre.state.svh ]; then
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
   -Wno-MULTIDRIVEN -Wno-SIDEEFFECT -Wno-INITIALDLY -Wno-ASCRANGE -Wno-LATCH -Wno-ENUMVALUE \
   --top-module tb_upload32 -o tbu -Mdir "$OUT/u" \
   rtl/package.sv rtl/peripheral/slots/memory_upload.sv rtl/peripheral/slots/mapper_detect.sv \
   sim/tb_upload32.sv > "$OUT/u.build.log" 2>&1
"$OUT/u/tbu" "+pack=$P" +sdsz=3 +limit=4000000 "+dump=$OUT/pre" > "$OUT/upload.log" 2>&1
fi
FILES=$(grep -v 'rtl/peripheral/sdram\(_tdm\)\?\.sv$' "$GEN/filelist.txt" | grep -v 'memory_upload\.sv$' | grep -v 'ymf278b_regs\.sv$' | tr '\n' ' ')
FILES="$FILES $V/ymf278b_regs.sv"
FILES=$(echo "$FILES" | tr ' ' '\n' | grep -vx "$GEN/vdp\(18_core\)\?\.v" | grep -v '/gen/vdp\(18_core\)\?\.v$' | tr '\n' ' ')
FILES="$FILES $(ls rtl/video/v9968/*.v | tr '\n' ' ') rtl/video/v9968_link.sv rtl/video/v9968_bus.sv rtl/video/v9968_cmdwait.sv rtl/video/geo3d/geo3d_core.v rtl/video/geo3d/geo3d_engine.v rtl/video/geo3d/geo3d_bus.v"
DEFS="-DPRELOAD -DPRELOAD_SVH=\"$OUT/pre.state.svh\" -DTDM128 -DMSX_V9968 -DVPROBE"
verilator --binary --timing --public-flat-rw \
   -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
   -Wno-UNDRIVEN -Wno-PINMISSING -Wno-IMPLICIT -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
   -Wno-BLKSEQ -Wno-LATCH -Wno-SIDEEFFECT -Wno-ENUMVALUE -Wno-BLKANDNBLK \
   -Wno-TIMESCALEMOD \
   $DEFS --top-module tb -o tbmsx -Mdir "$OUT/v" \
   "+incdir+$GEN" $FILES "$GEN/sdram_sim.sv" "$GEN/sdram_tdm_sim.sv" sim/fullsys/tb_msx.sv \
   > "$OUT/build.log" 2>&1 || { echo "BUILD FAIL $1"; grep -E '%Error' "$OUT/build.log" | head; exit 1; }
"$OUT/v/tbmsx" "+pack=$P" +ms=${MS:-160} "+preload=$OUT/pre" +moonsound +kprobe=${HEX:-$V/../mprobe.hex} > $V/${LOG:-run.log} 2>&1 || true
grep -E "^vprobe: phase [0-9]+ (at|errors)|VPROBE RESULT" $V/${LOG:-run.log} | sed -E 's/ \(VRAM.*//'
