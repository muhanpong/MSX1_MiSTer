# Per source (T80 IORQ_n, RD_n, and the clk21m flops that gate them), max (setup
# analysis) and min (hold analysis) data delay to the address and request-edge
# registers of sdram_tdm.  Race = address can arrive later than the request.
set out [lindex $argv 0]
project_open MSX1 -revision MSX1
create_timing_netlist
read_sdc
update_timing_netlist
set f [open $out w]
foreach sp {{*T80s:T80|IORQ_n} {*T80s:T80|RD_n} {*T80s:T80|MREQ_n} {*msx:MSX|iack} {*T80s:T80|A[*]}} {
  set src [get_registers -nowarn $sp]
  if {[get_collection_size $src] == 0} { puts $f "$sp\tNO-SOURCES"; continue }
  foreach {dg dpat} {caddr {*sdram_tdm:sdram|ch2_caddr[*]} cpend {*sdram_tdm:sdram|ch2_cpend} req1 {*sdram_tdm:sdram|ch2_req_1}} {
    set mx -1; set mn 1e9; set n 0
    foreach_in_collection p [get_timing_paths -setup -from $src -to [get_registers $dpat] -npaths 2000 -nworst 2000 -pairs_only] { set d [get_path_info $p -data_delay]; if {$d > $mx} {set mx $d}; incr n }
    foreach_in_collection p [get_timing_paths -hold  -from $src -to [get_registers $dpat] -npaths 2000 -nworst 2000 -pairs_only] { set d [get_path_info $p -data_delay]; if {$d < $mn} {set mn $d} }
    puts $f "$sp\t$dg\tpaths $n\tmax [format %.3f $mx]\tmin [format %.3f $mn]"
  }
}
# clock relationship: clk21m edge vs the clk_sdram edges after it
set s [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set c [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
puts $f "clk_sdram period [get_clock_info -period $s] waveform [get_clock_info -waveform $s] | clk21m period [get_clock_info -period $c] waveform [get_clock_info -waveform $c]"
close $f
