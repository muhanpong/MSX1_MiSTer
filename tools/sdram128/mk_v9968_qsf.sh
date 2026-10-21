#!/usr/bin/env bash
#  MSX1_V9968.qsf from MSX1.qsf: the V9968 build (plan S5).  Same settings, the macro
#  MSX_V9968 on, rtl/video/video_v9968.qip instead of video.qip.  Regenerate after any
#  change to MSX1.qsf; build with:  quartus_map MSX1 -c MSX1_V9968  (and fit/sta/asm).
set -eu
cd "$(dirname "$0")/../.."
grep -q 'QIP_FILE rtl/video/video.qip' MSX1.qsf || { echo "MSX1.qsf has no video.qip line"; exit 1; }
sed -e 's|QIP_FILE rtl/video/video.qip|QIP_FILE rtl/video/video_v9968.qip|' MSX1.qsf > MSX1_V9968.qsf
printf '\n# the V9968 build\nset_global_assignment -name VERILOG_MACRO "MSX_V9968=1"\n' >> MSX1_V9968.qsf
echo "MSX1_V9968.qsf written ($(wc -l < MSX1_V9968.qsf) lines)"
