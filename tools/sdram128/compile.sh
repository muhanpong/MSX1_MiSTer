#!/usr/bin/env bash
#  Compile the sdram128 study in stages, and stop after synthesis when the build is
#  not the one it claims to be.
#
#    tools/sdram128/compile.sh            (from the worktree root)
#    FROM=fit tools/sdram128/compile.sh   (map report already current and checked)
#    REV=MSX1_V9968 tools/sdram128/compile.sh   (the V9968 build; MSX1_V9968.qsf is
#                                         regenerated from MSX1.qsf first)
#    ASM=1 ...                            (quartus_asm -> rbf, only after TIMING PASS)
#
#  map (~6 min) -> check_timing.sh map -> fit (~20 min) -> sta -> check_timing.sh
#  99aac4e spent a whole 27-minute compile to find, at the end, that two PCM arrays
#  had been built as flops; Quartus had said so in the map report 20 minutes earlier.
#  The fit settings are the project's own (MSX1.qsf), so slacks stay comparable with
#  the earlier `quartus_sh --flow compile` builds.  The PRE_FLOW build_id script only
#  runs under --flow, so build_id.v is written below (these bitstreams now go on the board).
#  MSX1.qsf is restored at the end (Quartus rewrites its version line).
set -u
cd "$(dirname "$0")/../.."
Q=${Q:-/home/sysop/data/intelFPGA_lite/17.0/quartus/bin}
pgrep -x "quartus_(map|fit|sta|asm|sh)" > /dev/null && { echo "RESULT FAIL: another Quartus job is running"; exit 3; }
rc=0
REV=${REV:-MSX1}; export REV
[ "$REV" = MSX1_V9968 ] && { tools/sdram128/mk_v9968_qsf.sh || exit 1; }
#  build_id.v (BUILD_DATE, shown as "MSX1 vYYMMDD" in the MiSTer OSD About/info): the
#  PRE_FLOW script sys/build_id.tcl only runs under --flow, so these stage-by-stage
#  builds kept the date of the last --flow build (the 2026-10-22 board rbf said v261019).
#  Write it here the same way, every time.
#  SEED=N: fitter seed for this revision's qsf only (placement; MSX1.qsf keeps its own)
if [ -n "${SEED:-}" ]; then
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $SEED/" "$REV.qsf"
    echo "seed: $(grep '^set_global_assignment -name SEED' "$REV.qsf")"
fi
printf '`define BUILD_DATE "%s"\n' "$(date +%y%m%d)" > build_id.v
echo "build_id.v: $(cat build_id.v)"
stage() {
    local st=$1 t0=$(date +%s)
    "$Q/quartus_$st" MSX1 -c $REV > "output_files/stage_$st.log" 2>&1; local r=$?
    echo "stage $st rc=$r $(( $(date +%s)-t0 ))s errors=$(grep -c '^Error' output_files/stage_$st.log)"
    return $r
}
echo "compile $REV $(git log -1 --format='%h %s') at $(date '+%F %T')"
[ -n "$(git status --porcelain -- rtl sys MSX1.sv MSX1.sdc)" ] && echo "note: uncommitted RTL changes are in this build"
mkdir -p output_files
if [ "${FROM:-map}" = fit ]; then
    [ output_files/$REV.map.rpt -nt rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv ] \
        || { echo "RESULT FAIL: FROM=fit but the map report is older than the engine source"; exit 1; }
    tools/sdram128/check_timing.sh map; mok=$?
else
    stage map && tools/sdram128/check_timing.sh map; mok=$?
fi
if [ $mok -eq 0 ]; then
    t0=$(date +%s)
    if stage fit && stage sta; then
        [ $(( $(date +%s)-t0 )) -lt 240 ] && echo "WARN: fit+sta under 4 min -- smart recompile may have skipped the fit"
        tools/sdram128/check_timing.sh; rc=$?
    else rc=1; fi
else
    echo "stopped after map: not fitting a build that fails the map checks"; rc=1
fi
[ $rc -eq 0 ] && [ -n "${ASM:-}" ] && { stage asm || rc=1; ls -l output_files/$REV.rbf 2>/dev/null; }
git checkout -- MSX1.qsf MSX1_V9968.qsf
exit $rc
