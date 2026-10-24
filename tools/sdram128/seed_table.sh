#!/usr/bin/env bash
#  Compare fitted seeds by their worst margin, not by clk_sdram alone.
#    tools/sdram128/seed_table.sh [REV=MSX1_V9968] <project dir>...
#  Per dir: worst setup / hold / recovery / removal slack over every clock (with the clock),
#  total negative slack, and the overall minimum.  Sorted by that minimum, best first: among
#  seeds that all pass, the one with the largest minimum is the one to ship.
REV=${REV:-MSX1_V9968}
for d in "$@"; do
    f=$d/output_files/$REV.sta.summary
    [ -f "$f" ] || { echo "$d: no $REV.sta.summary"; continue; }
    seed=$(grep -hoE "SEED [0-9]+" "$d/output_files/compile.log" "$d/output_files/compile_$REV.log" 2>/dev/null | tail -1 | awk '{print $2}')
    awk -v d="$d" -v seed="${seed:-?}" '
        /^Type/ { k=$3; c=$4; for (i=5;i<=NF;i++) c=c" "$i; gsub(/\x27/,"",c)
                  if (c ~ /general\[0\]/) c="clk_sdram"; else if (c ~ /general\[1\]/) c="clk21m"
                  else if (c ~ /general\[2\]/) c="clk_vdp"; else if (c ~ /general\[3\]/) c="clk_geo"
                  else if (c ~ /pll_hdmi/) c="hdmi"; else if (c ~ /pll_audio/) c="audio" }
        /^Slack/ { s=$3; if (!(k in m) || s<m[k]) { m[k]=s; mc[k]=c }; if (s<mn) mn=s }
        /^TNS/ { t+=$3 }
        BEGIN { mn=1e9 }
        END {
            printf "%8.3f  seed %-3s setup %7.3f (%s)  hold %6.3f (%s)", mn, seed, m["Setup"], mc["Setup"], m["Hold"], mc["Hold"]
            if ("Recovery" in m) printf "  recov %6.3f", m["Recovery"]
            if ("Removal" in m)  printf "  remov %6.3f", m["Removal"]
            printf "  TNS %.3f  %s\n", t, d
        }' "$f"
done | sort -k1,1 -rn
