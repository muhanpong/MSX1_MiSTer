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
#   label           from      to-clock  to-register filter ("" = all)     expected  why
set EXPECT [list \
  [list C21_to_AZ      $c21     az80_clk ""                                  46.566 "clk21m rise -> next az80 edge (set_max_delay 46.566)"] \
  [list AZ_to_C21      az80_clk $c21     ""                                  23.283 "az80 edge -> clk21m fall (falling-edge fabric flops)"] \
  [list AZ_intra       az80_clk az80_clk ""                                  46.566 "half of the declared /8 period"] \
  [list SD_to_AZ_dout  $csd     az80_clk "*data_pins:data_pins_|dout*"      40.000 "SDRAM read data, set_max_delay 40"] \
  [list SD_to_AZ_wait  $csd     az80_clk "*az80_wrapper:CPU*clk_delay*"     11.641 "clk_sdram pacer release -> nWAIT sampler, single cycle"] \
  [list AZ_to_SD_ch2   az80_clk $csd     "*sdram*ch2_*"                     34.923 "A-Z80 address -> ch2 capture on the 3rd clk_sdram edge"] \
  [list AZ_to_SD_div   az80_clk $csd     "*az80_clkgen*|speed_q*"           23.282 "bus-idle -> divisor latch, -end 2"] \
  [list AZ_to_SD_tgl   az80_clk $csd     "*az80_clkgen*|az80_clk"           11.641 "the clock's own toggle flop, single cycle"] \
  [list AZ_to_SD_sync  az80_clk $csd     "*msx:MSX|az_win_s1"               34.923 "read window -> pacer synchroniser, -end 3"] ]
set fail 0
foreach e $EXPECT {
  lassign $e lbl f t filt want why
  if {$filt eq ""} { set p [get_timing_paths -from_clock $f -to_clock $t -npaths 1 -setup] } \
  else { set p [get_timing_paths -from_clock $f -to_clock $t -to [get_registers $filt] -npaths 1 -setup] }
  set got ""; set sl ""
  foreach_in_collection x $p { set got [expr {[get_path_info $x -latch_time] - [get_path_info $x -launch_time]}]; set sl [get_path_info $x -slack] }
  if {$got eq ""} { puts "GATE-FAIL $lbl: no paths (filter '$filt' matched nothing?)"; set fail 1; continue }
  if {abs($got - $want) > 0.01} { puts [format "GATE-FAIL %-14s relationship %.3f, expected %.3f (%s)" $lbl $got $want $why]; set fail 1 } \
  else { puts [format "REL %-14s rel=%.3f slack=%.3f ok" $lbl $got $sl] }
}
project_close
