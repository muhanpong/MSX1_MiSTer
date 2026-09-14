# Clock-pair relationship assertions.  A multicycle or a rounding artefact can
# move the analysed capture edge away from the one the flops use; this prints
# latch-minus-launch for the worst path of each pair and FAILS if it is not the
# value the design was argued for (docs/az80_migration_20260913.md, "진범 2").
# Edit EXPECT when the clocking changes -- deliberately, with the reason.
project_open MSX1 -revision MSX1
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set c21 {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set csd {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
#            label        from      to        expected relationship (ns)   why
set EXPECT [list \
  [list C21_to_AZ  $c21    az80_clk  46.566  "clk21m rise -> az80 edge on the next clk21m rise (set_max_delay 46.566)"] \
  [list AZ_to_C21  az80_clk $c21     23.283  "az80 edge -> clk21m fall (falling-edge flops in the fabric)"] \
  [list AZ_intra   az80_clk az80_clk 46.566  "half of the declared /8 period"] \
  [list SD_to_AZ   $csd    az80_clk  40.000  "set_max_delay 40 (SDRAM read data under the pacer)"] \
  [list AZ_to_SD   az80_clk $csd     11.641  "one clk_sdram"] ]
set fail 0
foreach e $EXPECT {
  lassign $e lbl f t want why
  set p [get_timing_paths -from_clock $f -to_clock $t -npaths 1 -setup]
  set got ""; set sl ""
  foreach_in_collection x $p { set got [expr {[get_path_info $x -latch_time] - [get_path_info $x -launch_time]}]; set sl [get_path_info $x -slack] }
  if {$got eq ""} { puts "REL $lbl: no paths"; continue }
  if {abs($got - $want) > 0.01} { puts [format "GATE-FAIL %-10s relationship %.3f, expected %.3f (%s)" $lbl $got $want $why]; set fail 1 } \
  else { puts [format "REL %-10s rel=%.3f slack=%.3f ok" $lbl $got $sl] }
}
project_close
