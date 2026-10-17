# Data delay of the CPU-side paths into sdram_tdm's ch2 request-edge registers:
# the address (ch2_caddr, ch2_hl) against the request decision (ch2_cpend, and
# ch2_req_1 for the edge).  Multicycle-relaxed in MSX1.sdc, so slack says nothing;
# the question is whether the address arrives within ONE clk_sdram (7.76 ns at
# 128.86 MHz) of the clk21m edge that launches the request, because the controller
# captures it at the first clk_sdram edge that sees the request.
# Usage: quartus_sta -t tools/sdram128/kanji_race.tcl <out_file>
set out [lindex $argv 0]
project_open MSX1 -revision MSX1
create_timing_netlist
read_sdc
update_timing_netlist
set f [open $out w]
foreach {tag pat} {
    caddr   {*sdram_tdm:sdram|ch2_caddr[*]}
    hl      {*sdram_tdm:sdram|ch2_hl*}
    cpend   {*sdram_tdm:sdram|ch2_cpend}
    req1    {*sdram_tdm:sdram|ch2_req_1}
} {
  set n 0
  foreach_in_collection p [get_timing_paths -setup -to [get_registers $pat] -npaths 4000 -nworst 4000 -pairs_only] {
    set from [get_node_info -name [get_path_info $p -from]]
    set to   [get_node_info -name [get_path_info $p -to]]
    puts $f "$tag\t[format %.3f [get_path_info $p -data_delay]]\t[format %.3f [get_path_info $p -slack]]\t[get_object_info -name [get_path_info $p -from_clock]]\t$from\t$to"
    incr n
  }
  puts "$tag: $n paths"
}
close $f
