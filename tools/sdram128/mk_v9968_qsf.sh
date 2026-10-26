#!/usr/bin/env bash
#  MSX1_V9968.qsf from MSX1.qsf: the V9968 build (plan S5).  Same settings, the macro
#  MSX_V9968 on, rtl/video/video_v9968.qip instead of video.qip.  Regenerate after any
#  change to MSX1.qsf; build with:  quartus_map MSX1 -c MSX1_V9968  (and fit/sta/asm).
#  V9968_UPSTREAM=1 tools/sdram128/mk_v9968_qsf.sh: upstream V9968/Geo3D (see below); default custom.
set -eu
cd "$(dirname "$0")/../.."
grep -q 'QIP_FILE rtl/video/video.qip' MSX1.qsf || { echo "MSX1.qsf has no video.qip line"; exit 1; }
sed -e 's|QIP_FILE rtl/video/video.qip|QIP_FILE rtl/video/video_v9968.qip|' MSX1.qsf > MSX1_V9968.qsf
printf '\n# the V9968 build\nset_global_assignment -name VERILOG_MACRO "MSX_V9968=1"\n' >> MSX1_V9968.qsf
#  V9968_UPSTREAM=1: the V9968 and Geo3D RTL as upstream ships them (every local change in
#  rtl/video/{v9968,geo3d}/ORIGIN.md switched off by `ifdef V9968_UPSTREAM; the extra ports stay).
#  Default (unset) = the MSX1 core's custom build.
if [ "${V9968_UPSTREAM:-0}" = 1 ]; then
    printf 'set_global_assignment -name VERILOG_MACRO "V9968_UPSTREAM=1"\n' >> MSX1_V9968.qsf
    echo "V9968_UPSTREAM=1: upstream V9968/Geo3D behaviour"
fi
echo "MSX1_V9968.qsf written ($(wc -l < MSX1_V9968.qsf) lines)"
