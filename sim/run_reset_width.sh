#!/usr/bin/env bash
#  The stretched machine reset (MSX1.sv `rst_hold`) is load-bearing in BOTH
#  directions, and nothing above the leaf benches used to check it:
#
#    * too WIDE  -- the 1-clock `load_sram` pulse from memory_upload lands inside
#                   the stretch; the save/load benches (sim/run_flash_autosave.sh,
#                   sim/run_nvram_load_reset.sh) model the stretch as 63 clk21m,
#                   so a wider reset is a change those benches never see.
#    * too SHORT -- the MoonSound PCM engine keeps its slot registers in MLAB,
#                   which cannot be reset; it sweeps zeros through 24 entries
#                   WHILE rst_n is low and needs rst_n >= 24 clk_sdram
#                   (ymf278_pcm_engine2.sv, "LOAD-BEARING ASSUMPTION" -- this
#                   engine arrives with origin/pcm-mlab ced5ea1; before it lands
#                   the engine states no minimum and this script says so).
#                   clk_sdram = 4 x clk21m (85.909 / 21.477 MHz), so the hold
#                   must be >= 6 clk21m.
#
#  This script reads the reload constant out of MSX1.sv -- not a copy of it --
#  and fails when it leaves [PCM_MIN_CLK21M, SAVE_MAX_CLK21M].  It also checks
#  that the PCM engine still states the 24-clk requirement, so a changed engine
#  requirement fails here too instead of silently widening the gap.
#
#      sim/run_reset_width.sh                 # the tree as it is
#      sim/run_reset_width.sh --selftest      # two deliberately wrong copies must FAIL
#      MSX1_SRC=/path/MSX1.sv  sim/run_reset_width.sh    # check another copy
#
#  Scope: a text check on the constants, not a simulation.  It cannot see a new
#  reset term added elsewhere (a longer `upload_hold`, a second stretch); those
#  still need the leaf benches.
set -u
cd "$(dirname "$0")/.."
SRC=${MSX1_SRC:-MSX1.sv}
ENGINE=${PCM_ENGINE_SRC:-rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv}
CLK_RATIO=4              # clk_sdram / clk21m
PCM_MIN_CLK=24           # what the engine's in-reset sweep needs, in clk_sdram
SAVE_MAX_CLK21M=63       # what tb_flash_autosave / tb_nvram_load_reset model

check_tree() {
   local src=$1 engine=$2 fail=0
   #  reg [5:0] rst_hold = 6'h3F;      -> width 6, init 0x3F
   #  if (rst_meta[1]) rst_hold <= 6'h3F;   -> reload 0x3F
   local decl reload width init
   decl=$(grep -E "^\s*reg\s*\[[0-9]+:0\]\s*rst_hold\s*=\s*[0-9]+'h[0-9A-Fa-f]+" "$src" | head -1)
   reload=$(grep -E "rst_hold\s*<=\s*[0-9]+'h[0-9A-Fa-f]+\s*;" "$src" | grep -v -- '- *6' | head -1)
   [ -n "$decl" ]   || { echo "  FAIL: no 'reg [N:0] rst_hold = W'hXX' in $src"; return 1; }
   [ -n "$reload" ] || { echo "  FAIL: no 'rst_hold <= W'hXX' reload in $src"; return 1; }
   width=$(sed -E "s/.*\[([0-9]+):0\].*/\1/" <<<"$decl"); width=$((width+1))
   init=$((16#$(sed -E "s/.*'h([0-9A-Fa-f]+).*/\1/" <<<"$decl")))
   local rl; rl=$((16#$(sed -E "s/.*'h([0-9A-Fa-f]+).*/\1/" <<<"$reload")))
   local hold_min=$(( (PCM_MIN_CLK + CLK_RATIO - 1) / CLK_RATIO ))
   echo "  rst_hold: width=$width init=$init reload=$rl clk21m  (allowed $hold_min..$SAVE_MAX_CLK21M)"
   [ "$rl" -eq "$init" ] || { echo "  FAIL: power-on init ($init) and reload ($rl) differ"; fail=1; }
   [ "$rl" -ge "$hold_min" ] || { echo "  FAIL: reload $rl clk21m = $((rl*CLK_RATIO)) clk_sdram < PCM sweep needs $PCM_MIN_CLK"; fail=1; }
   [ "$rl" -le "$SAVE_MAX_CLK21M" ] || { echo "  FAIL: reload $rl clk21m > $SAVE_MAX_CLK21M modelled by the save/load benches (load_sram is one clock wide)"; fail=1; }
   [ "$rl" -lt $((1<<width)) ] || { echo "  FAIL: reload $rl does not fit in $width bits"; fail=1; }
   #  The engine must still say what it needs; a changed number here changes PCM_MIN_CLK above.
   if [ -e "$engine" ]; then
      if grep -qE "rst_n must stay low for >= *$PCM_MIN_CLK clk" "$engine"; then
         echo "  engine: states rst_n >= $PCM_MIN_CLK clk  ($engine)"
      elif grep -qE "rst_n must stay low for >= *[0-9]+ clk" "$engine"; then
         echo "  FAIL: engine states a different minimum than PCM_MIN_CLK=$PCM_MIN_CLK: $(grep -oE 'rst_n must stay low for >= *[0-9]+ clk' "$engine")"; fail=1
      else
         echo "  engine: no in-reset sweep requirement stated (pre-MLAB engine) -- lower bound not load-bearing yet"
      fi
   else
      echo "  engine file missing: $engine (lower bound checked against PCM_MIN_CLK=$PCM_MIN_CLK anyway)"
   fi
   return $fail
}

if [ "${1:-}" = "--selftest" ]; then
   T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
   bad=0
   #  (a) too short: 6'h03 = 12 clk_sdram < 24
   sed -E "s/rst_hold = 6'h3F/rst_hold = 6'h03/; s/rst_hold <= 6'h3F/rst_hold <= 6'h03/" "$SRC" > "$T/short.sv"
   echo "selftest short (reload 3):";  check_tree "$T/short.sv" "$ENGINE" && { echo "  SELFTEST FAIL: a 3-clock hold passed"; bad=1; }
   #  (b) too wide: 7 bits, 7'h7F = 127 > 63
   sed -E "s/reg  \[5:0\] rst_hold = 6'h3F/reg  [6:0] rst_hold = 7'h7F/; s/rst_hold <= 6'h3F/rst_hold <= 7'h7F/; s/rst_hold - 6'd1/rst_hold - 7'd1/" "$SRC" > "$T/wide.sv"
   echo "selftest wide (reload 127):"; check_tree "$T/wide.sv" "$ENGINE" && { echo "  SELFTEST FAIL: a 127-clock hold passed"; bad=1; }
   #  (c) the exact boundary: 5 clk21m = 20 clk_sdram must FAIL, 6 = 24 must PASS.
   #      The engine's "24 clk" is in ITS clock, clk_sdram = 4 x clk21m
   #      (rtl/msx.sv: ymf278b_top .clk(clk_sdram); the engine's own comment says
   #      "63 clk21m = 252 clk").
   sed -E "s/rst_hold = 6'h3F/rst_hold = 6'h05/; s/rst_hold <= 6'h3F/rst_hold <= 6'h05/" "$SRC" > "$T/b5.sv"
   sed -E "s/rst_hold = 6'h3F/rst_hold = 6'h06/; s/rst_hold <= 6'h3F/rst_hold <= 6'h06/" "$SRC" > "$T/b6.sv"
   echo "selftest boundary (reload 5):"; check_tree "$T/b5.sv" "$ENGINE" && { echo "  SELFTEST FAIL: 5 clk21m = 20 clk_sdram passed"; bad=1; }
   echo "selftest boundary (reload 6):"; check_tree "$T/b6.sv" "$ENGINE" || { echo "  SELFTEST FAIL: 6 clk21m = 24 clk_sdram must pass"; bad=1; }
   #  (d) every copy must actually differ from the source, or the case tested nothing
   for c in short wide b5 b6; do
      cmp -s "$SRC" "$T/$c.sv" && { echo "  SELFTEST FAIL: $c copy identical to source (sed matched nothing)"; bad=1; }
   done
   echo "════════════════════════════════"
   [ $bad -eq 0 ] && echo "RESET WIDTH selftest: PASS (both wrong copies fail)" || echo "RESULT FAIL: RESET WIDTH selftest"
   exit $bad
fi

echo "reset width ($SRC):"
if check_tree "$SRC" "$ENGINE"; then
   echo "════════════════════════════════"; echo "RESET WIDTH: PASS"; exit 0
else
   echo "════════════════════════════════"; echo "RESULT FAIL: RESET WIDTH"; exit 1
fi
