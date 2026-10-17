# kanji_race.tcl, narrowed: sources in the kanji device and the T80 bus-control
# registers, to the request-edge registers of sdram_tdm.  Prints the worst data
# delay per (source group, destination group).
set out [lindex $argv 0]
project_open MSX1 -revision MSX1
create_timing_netlist
read_sdc
update_timing_netlist
set f [open $out w]
foreach {sg spat} {
    kanji  {*msx_slots*kanji*}
    t80    {*T80s:T80|*}
    t80bus {*T80*IORQ* *T80*RD* *T80*MREQ* *T80*WR* *T80*A[*]*}
} {
  foreach {dg dpat} {
      caddr {*sdram_tdm:sdram|ch2_caddr[*]}
      cpend {*sdram_tdm:sdram|ch2_cpend}
      req1  {*sdram_tdm:sdram|ch2_req_1}
      hl    {*sdram_tdm:sdram|ch2_hl*}
  } {
    set src [get_registers -nowarn $spat]
    if {[get_collection_size $src] == 0} { puts $f "$sg\t$dg\tNO-SOURCES"; continue }
    set best -1; set bf ""; set bt ""; set cnt 0
    foreach_in_collection p [get_timing_paths -setup -from $src -to [get_registers $dpat] -npaths 2000 -nworst 2000 -pairs_only] {
      set d [get_path_info $p -data_delay]; incr cnt
      if {$d > $best} { set best $d; set bf [get_node_info -name [get_path_info $p -from]]; set bt [get_node_info -name [get_path_info $p -to]] }
    }
    puts $f "$sg\t$dg\t$cnt paths\tworst data delay [format %.3f $best] ns\t$bf -> $bt"
  }
}
close $f
