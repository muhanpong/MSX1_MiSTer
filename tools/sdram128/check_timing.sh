#!/usr/bin/env bash
#  Read a finished sdram128-study compile and say what it measured.
#
#    tools/sdram128/check_timing.sh            (after a compile: everything below)
#    tools/sdram128/check_timing.sh map        (after quartus_map only: the checks that
#                                               need no fit, so a bad build stops ~6 min
#                                               in instead of ~27; tools/sdram128/compile.sh)
#
#  It refuses to describe a build that is not the one it claims to be:
#   - clk_sdram must be 7.760 ns (128.86 MHz).  A build at 11.641 ns is not this study.
#   - the PCM pipeline states (10 since CHIT0 and EGPRE2) must be in the map report.  On 2026-10-12 msx.sv passed
#     MoonSound a literal CLK_HZ 85909090, the engine was built unpipelined, and one
#     whole compile measured nothing of the change it was meant to measure.
#   - every PCM memory must still be MLAB, checked by name (RAM summary, not warnings:
#     arrays have been silently built as flops with no warning).
#   - no "can't infer memory" (10999) inside the PCM engine: in 99aac4e inv_tagA/B
#     were read three times in the source, Quartus built them as flops, and the
#     MLAB count only showed it after a 27-minute compile.
#  Then it lists the failing endpoints grouped by module and register.
set -u
cd "$(dirname "$0")/../.."
Q=${Q:-/home/sysop/data/intelFPGA_lite/17.0/quartus/bin}
STA=output_files/MSX1.sta.rpt; MAP=output_files/MSX1.map.rpt
FAIL=0; fail() { echo "  FAIL: $*"; FAIL=1; }
MODE=${1:-all}
case $MODE in all) NEED="$MAP $STA";; map) NEED=$MAP;; *) echo "usage: $0 [map]"; exit 2;; esac
for f in $NEED; do [ -s "$f" ] || { echo "RESULT FAIL: $f missing -- no compile here"; exit 1; }; done
if [ "$MODE" = all ]; then
    [ "$STA" -nt "$MAP" ] || fail "sta report is older than the map report (fit/sta not rerun?)"
    echo "build: map $(date -r $MAP '+%F %T'), sta $(date -r $STA '+%F %T'), HEAD $(git log -1 --format=%h)"
    per=$(grep -m1 "general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk *; Generated" $STA | awk -F';' '{gsub(/ /,"",$4); print $4}')
    echo "clk_sdram period: $per ns"
    [ "$per" = "7.760" ] || fail "clk_sdram is not 7.760 ns"
else
    echo "build: map $(date -r $MAP '+%F %T'), HEAD $(git log -1 --format=%h) (map only)"
    #  the period is set in the PLL, not synthesised: check the PLL parameter instead
    grep -q 'output_clock_frequency0("128.863620 MHz")' rtl/pll/pll_0002.v \
        || fail "PLL output 0 (rtl/pll/pll_0002.v) is not 128.863620 MHz"
fi

pipe=$(grep -o "sl_state\.SL_\(ADV0\|CHIT0\|INTERP2\|INTERP3\|EGPRE\|EGPRE2\|GAIN2\|MUL1B\|MUL2B\|PANB\)\b" $MAP | sort -u | wc -l)
echo "PCM pipeline states synthesised: $pipe / 10"
[ "$pipe" -eq 10 ] || fail "PIPE is off in this build (check CLK_HZ passed to ymf278b_top)"

#  Every PCM memory by name, not a count: c126c6c had 33 because Quartus made a
#  second copy of inv_tagA/B (__dual_rtl_0); 4cd2115 has 31, one each, which is
#  better -- a count of 33 would have refused it, and a lost array and a dropped
#  duplicate look the same to a count.  g_f[0].u_m is absent in both (its read
#  port feeds nothing, so Quartus removes it).
have=$(awk '/; Analysis & Synthesis RAM Summary/,/^$/' $MAP | grep "u_pcm" | grep " MLAB " \
       | awk -F';' '{print $2}' | sed 's/.*u_pcm|//; s/|altdpram.*//; s/:auto_generated.*//;
                                     s/^altdpram://; s/__dual_rtl_0.*//; s/_rtl_0.*//; s/^pcm_mlab24://' | sort -u)
want="cache_tagA cache_tagB cache_w0 cache_w1 cache_w2 cache_w3 inv_tagA inv_tagB ram_dyn_m ram_header_m
      g_f[0].g_h.u_mh g_f[1].g_h.u_mh"
for i in 0 1 2 3 4 5 6 7 8 9; do want="$want g_f[$i].u_mc"; [ $i -gt 0 ] && want="$want g_f[$i].u_m"; done
miss=""; for w in $want; do grep -qxF "$w" <<< "$have" || miss="$miss $w"; done
echo "PCM memories in MLAB: $(wc -l <<< "$have") distinct, $(wc -w <<< "$want") required"
[ -z "$miss" ] || fail "PCM memories not in MLAB:$miss"
noinf=$(grep "(10999)" $MAP | grep -c "ymf278_pcm_engine2")
echo "PCM arrays Quartus could not infer as memory (10999): $noinf"
[ "$noinf" -eq 0 ] || { grep "(10999)" $MAP | grep "ymf278_pcm_engine2" | sed 's/^/    /' | cut -c1-160; fail "PCM array built as flops"; }

if [ "$MODE" = map ]; then
    echo "════════════════════════════════"
    [ "$FAIL" -eq 0 ] && echo "RESULT PASS: map stage is the 128.86 MHz PIPE study (fit may go on)" \
                     || echo "RESULT FAIL: see above -- do not fit this"
    exit "$FAIL"
fi

#  an SDC exception whose name pattern matches nothing is dropped without an error
#  (332049/332174).  The sdram -> sdram_tdm rename would have done exactly that to
#  the ch2 single-cycle exception, so every ignored constraint fails the gate.
ign=$(grep -E "\((332049|332174)\)" $STA | grep -o "MSX1\.sdc([0-9]*)" | sort -u | tr '\n' ' ')
echo "SDC constraints ignored by TimeQuest: ${ign:-none}"
[ -z "$ign" ] || fail "SDC constraints ignored: $ign"

echo "setup, clk_sdram: $(awk '/; Setup Summary/,/^$/' $STA | grep 'emu|pll.*general\[0\]' | awk -F';' '{print "slack "$3" TNS "$4}' | tr -s ' ')"
T=$(mktemp)
"$Q/quartus_sta" -t tools/sdram128/sta_paths.tcl "$T" > /dev/null 2>&1 || fail "quartus_sta failed"
echo "failing endpoints: $(wc -l < "$T")"
awk -F'\t' '{n=split($4,a,"|"); t=a[n]; sub(/\[.*/,"",t); sub(/~.*/,"",t);
             m=split($3,b,"|"); s=b[m]; sub(/\[.*/,"",s); sub(/~.*/,"",s);
             mod=($4 ~ /u_pcm/)?"pcm":(($4 ~ /sdram(_tdm)?:sdram/)?"sdram":(($4 ~ /u_moonsound/)?"moonsound":"other"));
             k=$1" "mod": "t" <- "s; c[k]++; if(!(k in w)||$2<w[k]) w[k]=$2}
     END{for(k in c) printf "%5d %7.2f  %s\n", c[k], w[k], k}' "$T" | sort -k2 -n | head -${TOP:-30}
rm -f "$T"
echo "════════════════════════════════"
[ "$FAIL" -eq 0 ] && echo "RESULT PASS: the build is the 128.86 MHz PIPE study it claims to be" \
                 || echo "RESULT FAIL: see above"
exit "$FAIL"
