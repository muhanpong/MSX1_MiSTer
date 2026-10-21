# Failing setup paths into and out of clk_sdram, one line per endpoint:
#   <SS|CS|SC>\t<slack>\t<from node>\t<to node>
# SS = clk_sdram -> clk_sdram, CS = clk21m -> clk_sdram, SC = clk_sdram -> clk21m;
# in the V9968 build also V (clk_vdp, general[2]): VV, VS, SV, VC, CV.
# Usage: quartus_sta -t sta_paths.tcl <out_file> [revision]   (from the project directory)
set out [lindex $argv 0]
set rev [expr {[llength $argv] > 1 ? [lindex $argv 1] : "MSX1"}]
project_open MSX1 -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist
set s {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set c {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set v {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
set pairs [list SS $s $s CS $c $s SC $s $c]
if {[get_collection_size [get_clocks -nowarn $v]] > 0} {
  lappend pairs VV $v $v VS $v $s SV $s $v VC $v $c CV $c $v
}
set f [open $out w]
foreach {tag from to} $pairs {
  foreach_in_collection p [get_timing_paths -setup -from_clock [get_clocks $from] \
      -to_clock [get_clocks $to] -npaths 50000 -nworst 1 -less_than_slack 0] {
    puts $f "$tag\t[get_path_info $p -slack]\t[get_node_info -name [get_path_info $p -from]]\t[get_node_info -name [get_path_info $p -to]]"
  }
}
close $f
