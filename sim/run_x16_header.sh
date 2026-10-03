#!/usr/bin/env bash
# An ASCII16X ROM is recognised by its header whatever its size (tb_x16_header), and the
# decoder promotes the OSD "ASCII16X" entry on a <= 4MB cart (tb_subslot_dev).
#   (default)       the shipped RTL
#   MUT=nolate      no late 8MB padding            -> the header cases must fail on size/padding
#   MUT=nopromote   decoder does not promote       -> the header cases must fail on mapper
#   MUT=nostale     detector keeps the old header  -> the "stale" cases must fail
#   MUT=nopatfix    pattern switches in the pass that issues the last image byte -> "image intact" must fail
set -u
cd "$(dirname "$0")/.."
OUT=${OUT:-/tmp/x16hdr_sim}; mkdir -p "$OUT"
MU=rtl/peripheral/slots/memory_upload.sv
MD=rtl/peripheral/slots/mapper_detect.sv
W_MU="$OUT/memory_upload.sv"; W_MD="$OUT/mapper_detect.sv"
python3 - "$MU" "$MD" "$W_MU" "$W_MD" "${MUT:-}" <<'PY'
import sys
mu=open(sys.argv[1]).read(); md=open(sys.argv[2]).read(); mut=sys.argv[5]
def sub(s,a,b):
    assert s.count(a)==1,("mutation anchor missing",a[:50]); return s.replace(a,b)
if mut=="nolate":
    mu=sub(mu,"x16_late_pad != 25'd0 && ~x16_done","1'b0")
elif mut=="nopromote":
    mu=sub(mu,"wire promote_x16 = selected_mapper == MAPPER_ASCII16 && detected_mapper == MAPPER_ASCII16X;","wire promote_x16 = 1'b0;")
elif mut=="nopatfix":
    for old in ("x16_pat_pending <= 1'b1;    // 0xFF = erased flash, from the next byte on","x16_pat_pending          <= 1'b1;"):
        mu=sub(mu,old,old+" pattern <= 3'd1;")
elif mut=="nostale":
    md=sub(md,"for (int i = 0; i < 8; i++) head3[i] <= 8'h00;","")
elif mut:
    sys.exit("unknown MUT="+mut)
open(sys.argv[3],"w").write(mu); open(sys.argv[4],"w").write(md)
PY
[ $? -eq 0 ] || exit 2
verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-ENUMVALUE \
   --top-module tb_x16_header -o tbx16 -Mdir "$OUT/v" \
   rtl/package.sv sim/tb_x16_header.sv "$W_MU" "$W_MD" > "$OUT/build.log" 2>&1 \
   || { echo "COMPILE FAILED"; tail -30 "$OUT/build.log"; exit 2; }
"$OUT/v/tbx16" 2>&1 | grep -vE '^(CONF|  (LOAD|ADD|STORE|SLOT|CONFIG)|     ADD|           FILL|  CONFIG|BIOS|- )'
exit ${PIPESTATUS[0]}
