# cpuswap-cores triage WITHOUT a fit: post-map netlist (synthesis-estimated
# delays, no routing) under the tree's own MSX1.sdc.  A family already negative
# here is a constraint placement and routing cannot rescue.  For each failing
# family: analysed relationship (latch - launch), data delay, count.
#   quartus_sta -t tools/sta/cpuswap_postmap_triage.tcl
# Adapted from rz80-eval/tools/sta/rz80eval_postmap_triage.tcl.
project_open MSX1
create_timing_netlist -post_map
read_sdc
update_timing_netlist

set NZ  [get_registers {*msx:MSX|NextZ80:NZ|*}]
set T80 [get_registers {*msx:MSX|T80s:T80|*}]
set NZB [get_registers {*msx:MSX|nz_bus:NZB|* *msx:MSX|cpuswap_ctl:CPUSWAP|* *msx:MSX|resume_guard *msx:MSX|rg_seen}]
puts "NextZ80 registers: [get_collection_size $NZ]  T80s registers: [get_collection_size $T80]  nz_bus/ctl/guard: [get_collection_size $NZB]"

proc fam {name} {
    regsub -all {\[[0-9]+\]} $name {[]} n
    regsub -all {~[0-9]+} $n {} n
    regsub -all {\.[0-9]+$} $n {} n
    regsub {^emu:emu\|msx:MSX\|} $n {} n
    regsub {^emu:emu\|} $n {} n
    return $n
}
proc group {title args} {
    array set cnt {}; array set worst {}; array set dd {}; array set rel {}
    set n 0; set nworst 1e9; set tns 0.0
    foreach_in_collection p [eval get_timing_paths $args -npaths 4000] {
        set s [get_path_info $p -slack]
        if {$s < $nworst} { set nworst $s }
        if {$s >= 0} { continue }
        incr n; set tns [expr {$tns + $s}]
        set k "[fam [get_node_info -name [get_path_info $p -from]]] -> [fam [get_node_info -name [get_path_info $p -to]]]"
        if {![info exists cnt($k)]} { set cnt($k) 0; set worst($k) 1e9; set dd($k) 0; set rel($k) 0 }
        incr cnt($k)
        if {$s < $worst($k)} {
            set worst($k) $s; set dd($k) [get_path_info $p -data_delay]
            set rel($k) [expr {[get_path_info $p -latch_time] - [get_path_info $p -launch_time]}]
        }
    }
    puts [format "=== %s: %d failing (of top 4000), worst %.3f, TNS(top) %.0f ===" $title $n $nworst $tns]
    set rows {}
    foreach k [array names cnt] { lappend rows [list $worst($k) $cnt($k) $dd($k) $rel($k) $k] }
    set i 0
    foreach r [lsort -real -index 0 $rows] {
        puts [format "  slack %8.3f  rel %7.3f  data %6.2f  x%-5d %s" [lindex $r 0] [lindex $r 3] [lindex $r 2] [lindex $r 1] [lindex $r 4]]
        if {[incr i] >= 25} break
    }
}
proc rel1 {title args} {
    set got ""; set sl ""
    foreach_in_collection x [eval get_timing_paths $args -npaths 1 -setup] {
        set got [expr {[get_path_info $x -latch_time] - [get_path_info $x -launch_time]}]; set sl [get_path_info $x -slack]
    }
    puts [format "REL %-40s rel=%s slack=%s" $title $got $sl]
}
set c21 {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}
set csd {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
rel1 "NZ -> NZ"                 -from $NZ -to $NZ
rel1 "NZ -> sdram ch2"          -from $NZ -to [get_registers {*sdram*ch2_*}]
rel1 "T80 -> sdram ch2"         -from $T80 -to [get_registers {*sdram*ch2_*}]
rel1 "T80 REG -> NZ (LOAD)"     -from $T80 -to $NZ
rel1 "NZ XREG -> T80 (DIRSet)"  -from $NZ -to $T80
rel1 "NZ -> cpuswap_ctl (excepted)" -from $NZ -to [get_registers {*msx:MSX|cpuswap_ctl:CPUSWAP|*}]
rel1 "NZ -> a_q (excepted)"       -from $NZ -to [get_registers {*msx:MSX|a_q[*]}]
rel1 "NZ -> cheat RAM (excepted)" -from $NZ -to [get_registers {*cheat_ram*}]
rel1 "NZ -> SCC wave RAM (fall)"  -from $NZ -to [get_registers {*IKASCC_player_memory_s*}]
rel1 "NZ -> systemRAM"            -from $NZ -to [get_registers {*systemRAM*}]
group "SETUP NextZ80 -> NextZ80"          -setup -from $NZ -to $NZ
group "SETUP into NextZ80 (all sources)"  -setup -to $NZ
group "SETUP out of NextZ80 (all dests)"  -setup -from $NZ
group "SETUP into T80s"                   -setup -to $T80
group "SETUP out of T80s"                 -setup -from $T80
group "SETUP into nz_bus/ctl/guard"       -setup -to $NZB
#  Out of NextZ80 / T80s into the fabric only (cores, nz_bus ph and SCC wave RAM excluded),
#  so the NextZ80 families can be compared with T80s' to the same destinations.
set FAB [remove_from_collection [all_registers] [add_to_collection $NZ $T80]]
group "SETUP NextZ80 -> fabric"           -setup -from $NZ -to $FAB
group "SETUP T80s -> fabric"              -setup -from $T80 -to $FAB
group "SETUP whole design"                -setup
delete_timing_netlist
project_close
