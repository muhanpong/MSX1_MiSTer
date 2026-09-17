# Clock-pair relationship assertions.  A multicycle or a rounding artefact can
# move the analysed capture edge away from the one the flops use; this prints
# latch-minus-launch for the worst path of each pair and FAILS if it is not the
# value the design was argued for (docs/az80_migration_20260913.md, "진범 2";
# the NextZ80 rules are argued in MSX1.sdc and rtl/cpu/cpuswap/README.md).
# Edit EXPECT when the clocking changes -- deliberately, with the reason.
project_open MSX1 -revision MSX1
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set c21 {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set csd {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
#   label           from      to-clock  to-register filter ("" = all)     expected  why  [from-register filter]
#  The last field is optional: a source register filter, for rules that have -from.
set EXPECT [list \
  [list NZ_intra       $c21     $c21     "*msx:MSX|NextZ80:NZ|*"            93.132 "NextZ80 -> NextZ80, -end 2 (writes >= 2 clk21m apart, nz_bus)" "*msx:MSX|NextZ80:NZ|*"] \
  [list NZ_to_SD_ch2   $c21     $csd     "*sdram*ch2_*"                     69.846 "NextZ80 address -> ch2 capture, generic -end 6" "*msx:MSX|NextZ80:NZ|*"] \
  [list NZ_to_fabric   $c21     $c21     "*systemRAM*"                      93.132 "NextZ80 -> clk21m fabric, clock-based -end 2" "*msx:MSX|NextZ80:NZ|*"] \
  [list NZ_to_SCC_fall $c21     $c21     "*IKASCC_player_memory_s*"         69.849 "NextZ80 -> SCC wave RAM falling edge, -end 2" "*msx:MSX|NextZ80:NZ|*"] \
  [list NZ_to_ctl_exc  $c21     $c21     "*msx:MSX|cpuswap_ctl:CPUSWAP|*"   46.566 "exception: SWAPPT -> controller single-cycle" "*msx:MSX|NextZ80:NZ|*"] \
  [list NZ_to_cheat_exc $c21    $c21     "*msx:MSX|a_q[*]"                  46.566 "exception: cheat address register single-cycle" "*msx:MSX|NextZ80:NZ|*"] \
  [list T80_to_NZ      $c21     $c21     "*msx:MSX|NextZ80:NZ|*"            93.132 "T80s REG -> NextZ80 LOAD, -end 2" "*msx:MSX|T80s:T80|*"] ]
set fail 0
foreach e $EXPECT {
  lassign $e lbl f t filt want why ffilt
  set args [list -from_clock $f -to_clock $t -npaths 1 -setup]
  if {$filt ne ""}                           { lappend args -to   [get_registers $filt] }
  if {[info exists ffilt] && $ffilt ne ""}   { lappend args -from [get_registers $ffilt] }
  set p [get_timing_paths {*}$args]
  unset -nocomplain ffilt
  set got ""; set sl ""
  foreach_in_collection x $p { set got [expr {[get_path_info $x -latch_time] - [get_path_info $x -launch_time]}]; set sl [get_path_info $x -slack] }
  if {$got eq ""} { puts "GATE-FAIL $lbl: no paths (filter '$filt' matched nothing?)"; set fail 1; continue }
  if {abs($got - $want) > 0.01} { puts [format "GATE-FAIL %-14s relationship %.3f, expected %.3f (%s)" $lbl $got $want $why]; set fail 1 } \
  else { puts [format "REL %-14s rel=%.3f slack=%.3f ok" $lbl $got $sl] }
}
project_close
