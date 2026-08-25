#!/usr/bin/env bash
# Expanded cart slots (OSD "SLOT A/B sub-slots").  Two benches:
#   tb_subslot_dev  -- cart_confDecoder rows + msx_config menu rules
#   tb_scc_subslot  -- cart_konami_scc state is per (cart slot, subslot)
# NEGCTL=1 reverts each DUT to the pre-feature behaviour; the feature checks MUST
# then fail (see the header of each bench).
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/subslot_sim}; mkdir -p "$OUT"
DEF=""; [ "${NEGCTL:-0}" = "1" ] && DEF="+define+NEGCTL"
rc=0
build_run() {  # top, binary, sources...
   local top=$1 bin=$2; shift 2
   verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-ENUMVALUE $DEF \
      --top-module "$top" -o "$bin" -Mdir "$OUT/v_$top" "$@" > "$OUT/build_$top.log" 2>&1 \
      || { echo "COMPILE FAILED: $top"; tail -25 "$OUT/build_$top.log"; return 2; }
   "$OUT/v_$top/$bin" 2>&1 | grep -vE '^- '
   return ${PIPESTATUS[0]}
}
build_run tb_subslot_dev tbsubslot rtl/package.sv sim/tb_subslot_dev.sv rtl/msx_config.sv rtl/peripheral/slots/memory_upload.sv || rc=1
build_run tb_scc_subslot tbsccsub  rtl/package.sv sim/tb_scc_subslot.sv rtl/peripheral/slots/konami_scc.sv || rc=1
echo "rc=$rc"; exit $rc
