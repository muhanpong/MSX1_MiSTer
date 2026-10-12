#!/usr/bin/env bash
#  Read a finished sdram128-study compile and say what it measured.
#
#    tools/sdram128/check_timing.sh            (from the worktree root, after a compile)
#
#  It refuses to describe a build that is not the one it claims to be:
#   - clk_sdram must be 7.760 ns (128.86 MHz).  A build at 11.641 ns is not this study.
#   - the PCM pipeline states must be in the map report.  On 2026-10-12 msx.sv passed
#     MoonSound a literal CLK_HZ 85909090, the engine was built unpipelined, and one
#     whole compile measured nothing of the change it was meant to measure.
#   - the PCM memories must still be MLAB (RAM summary, not warnings: arrays have been
#     silently built as flops with no warning).  MLAB_EXPECT, default 33.
#  Then it lists the failing endpoints grouped by module and register.
set -u
cd "$(dirname "$0")/../.."
Q=${Q:-/home/sysop/data/intelFPGA_lite/17.0/quartus/bin}
STA=output_files/MSX1.sta.rpt; MAP=output_files/MSX1.map.rpt
FAIL=0; fail() { echo "  FAIL: $*"; FAIL=1; }
for f in $STA $MAP; do [ -s "$f" ] || { echo "RESULT FAIL: $f missing -- no compile here"; exit 1; }; done
echo "build: map $(date -r $MAP '+%F %T'), sta $(date -r $STA '+%F %T'), HEAD $(git log -1 --format=%h)"

per=$(grep -m1 "general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk *; Generated" $STA | awk -F';' '{gsub(/ /,"",$4); print $4}')
echo "clk_sdram period: $per ns"
[ "$per" = "7.760" ] || fail "clk_sdram is not 7.760 ns"

pipe=$(grep -o "sl_state\.SL_\(ADV0\|INTERP2\|INTERP3\|EGPRE\|GAIN2\|MUL1B\|MUL2B\|PANB\)" $MAP | sort -u | wc -l)
echo "PCM pipeline states synthesised: $pipe / 8"
[ "$pipe" -eq 8 ] || fail "PIPE is off in this build (check CLK_HZ passed to ymf278b_top)"

mlab=$(awk '/; Analysis & Synthesis RAM Summary/,/^$/' $MAP | grep "u_pcm" | grep -c " MLAB ")
echo "PCM memories inferred as MLAB: $mlab (expect ${MLAB_EXPECT:-33})"
[ "$mlab" -ge "${MLAB_EXPECT:-33}" ] || fail "fewer PCM MLABs than expected"

echo "setup, clk_sdram: $(awk '/; Setup Summary/,/^$/' $STA | grep 'emu|pll.*general\[0\]' | awk -F';' '{print "slack "$3" TNS "$4}' | tr -s ' ')"
T=$(mktemp)
"$Q/quartus_sta" -t tools/sdram128/sta_paths.tcl "$T" > /dev/null 2>&1 || fail "quartus_sta failed"
echo "failing endpoints: $(wc -l < "$T")"
awk -F'\t' '{n=split($4,a,"|"); t=a[n]; sub(/\[.*/,"",t); sub(/~.*/,"",t);
             m=split($3,b,"|"); s=b[m]; sub(/\[.*/,"",s); sub(/~.*/,"",s);
             mod=($4 ~ /u_pcm/)?"pcm":(($4 ~ /sdram:sdram/)?"sdram":(($4 ~ /u_moonsound/)?"moonsound":"other"));
             k=$1" "mod": "t" <- "s; c[k]++; if(!(k in w)||$2<w[k]) w[k]=$2}
     END{for(k in c) printf "%5d %7.2f  %s\n", c[k], w[k], k}' "$T" | sort -k2 -n | head -${TOP:-30}
rm -f "$T"
echo "════════════════════════════════"
[ "$FAIL" -eq 0 ] && echo "RESULT PASS: the build is the 128.86 MHz PIPE study it claims to be" \
                 || echo "RESULT FAIL: see above"
exit "$FAIL"
