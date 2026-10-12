# STA of the SDRAM pins on a finished sdram128 compile, with sdram_io.sdc added to
# the project SDC (analysis only -- the fit did not see these constraints).
#   quartus_sta -t tools/sdram128/io_sta.tcl <report_file>
# Prints IOSTA lines: the worst setup/hold slack of the output group and of the
# read capture, and how many constraints TimeQuest ignored (must be 0).
set out [lindex $argv 0]
project_open MSX1 -revision MSX1
create_timing_netlist
read_sdc
read_sdc tools/sdram128/sdram_io.sdc
update_timing_netlist
set clk_s {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set f [open $out w]
foreach {tag from to} [list OUT_SETUP $clk_s sdram_clk_pin IN_SETUP sdram_clk_pin $clk_s] {
    set p [get_timing_paths -setup -from_clock [get_clocks $from] -to_clock [get_clocks $to] -npaths 1]
    foreach_in_collection q $p { puts $f "IOSTA $tag slack [get_path_info $q -slack] from [get_node_info -name [get_path_info $q -from]] to [get_node_info -name [get_path_info $q -to]]" }
    set h [get_timing_paths -hold -from_clock [get_clocks $from] -to_clock [get_clocks $to] -npaths 1]
    foreach_in_collection q $h { puts $f "IOSTA [string map {SETUP HOLD} $tag] slack [get_path_info $q -slack] from [get_node_info -name [get_path_info $q -from]] to [get_node_info -name [get_path_info $q -to]]" }
}
report_timing -setup -from_clock [get_clocks sdram_clk_pin] -to_clock [get_clocks $clk_s] -npaths 1 -detail full_path -file ${out}.in_setup.rpt
report_timing -setup -from_clock [get_clocks $clk_s] -to_clock [get_clocks sdram_clk_pin] -npaths 1 -detail full_path -file ${out}.out_setup.rpt
close $f
