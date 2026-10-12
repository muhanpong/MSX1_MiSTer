#!/usr/bin/env bash
#  Compile the sdram128 study in stages, and stop after synthesis when the build is
#  not the one it claims to be.
#
#    tools/sdram128/compile.sh            (from the worktree root)
#    FROM=fit tools/sdram128/compile.sh   (map report already current and checked)
#
#  map (~6 min) -> check_timing.sh map -> fit (~20 min) -> sta -> check_timing.sh
#  99aac4e spent a whole 27-minute compile to find, at the end, that two PCM arrays
#  had been built as flops; Quartus had said so in the map report 20 minutes earlier.
#  The fit settings are the project's own (MSX1.qsf), so slacks stay comparable with
#  the earlier `quartus_sh --flow compile` builds.  The PRE_FLOW build_id script only
#  runs under --flow; these bitstreams are timing studies and never go on a board.
#  MSX1.qsf is restored at the end (Quartus rewrites its version line).
set -u
cd "$(dirname "$0")/../.."
Q=${Q:-/home/sysop/data/intelFPGA_lite/17.0/quartus/bin}
pgrep -x "quartus_(map|fit|sta|asm|sh)" > /dev/null && { echo "RESULT FAIL: another Quartus job is running"; exit 3; }
rc=0
stage() {
    local st=$1 t0=$(date +%s)
    "$Q/quartus_$st" MSX1 -c MSX1 > "output_files/stage_$st.log" 2>&1; local r=$?
    echo "stage $st rc=$r $(( $(date +%s)-t0 ))s errors=$(grep -c '^Error' output_files/stage_$st.log)"
    return $r
}
echo "compile $(git log -1 --format='%h %s') at $(date '+%F %T')"
[ -n "$(git status --porcelain -- rtl sys MSX1.sv MSX1.sdc)" ] && echo "note: uncommitted RTL changes are in this build"
mkdir -p output_files
if [ "${FROM:-map}" = fit ]; then
    [ output_files/MSX1.map.rpt -nt rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv ] \
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
git checkout -- MSX1.qsf
exit $rc
