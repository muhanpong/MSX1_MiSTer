# field_race.tcl -- per field, on which clk_sdram edge after its launch the ch2
# capture registers of sdram_tdm see a new value, against the request.
#
#   quartus_sta -t tools/sdram128/field_race.tcl <out_file> [tdm|sdram]   (project dir, fitted DB)
#     tdm   (default) sdram_tdm, 128.86 MHz, T = 7.760, clk21m = 6 T
#     sdram sdram.sv (nextz80 / release), 85.909 MHz, T = 11.640, clk21m = 4 T
#   then: git checkout -- MSX1.qsf   (project_open touches it)
#
# core_builder's request 2026-10-18.  sdram_tdm takes the CPU request on the first
# clk_sdram edge that sees ch2_req high and captures address / rnw / data on that
# same edge.  MSX1.sdc relaxes CPU -> *sdram*ch2_* to 6 cycles, so the ordinary
# report does not check that the fields are there by then.
#
# Edge number k of a path: clk21m and clk_sdram come from one PLL, phase 0, ratio
# 6, so a clk21m launch at L is followed by clk_sdram edges at L + m*T (m >= 1).
#   setup (late):  t = arrival - (required - latch) - launch    (capture clock
#                  latency, tsu, uncertainty folded in);  k = ceil(t / T)
#                  = the edge by which the new value is surely in.
#   hold (early):  same with the hold required time;  k = ceil(t / T)
#                  = the earliest edge that can already take the new value.
# A field is at risk if, in one corner, its late k is above the request's early k
# (the request seen on an edge the field has not reached).  A field launched L
# edges before the request (sim LEAD, tb_msx.sv) is at risk if k_late - L > k_early
# (request).  Launch offsets are not STA's: read them from the bench.
#
# Classes (paths separated by the nets they pass, as tools/buildgate/strobe_race.tcl):
#   req     strobe -> msx_slots|sdram_ce -> {ch2_req_1, ch2_cpend, ch2_rq}, NOT through
#           the unmap gate nets (a plain access: the gate does not move)
#   gate_ffff  strobe -> {mapper_wr, mapper_en} -> sdram_ce -> same regs (the FFFFh
#           write: enable rises on the req path, the gate closes later = a glitch
#           request if gate_ffff.late > req.early)
#   gate_any   strobe -> any *mem_unmaped* node -> sdram_ce (every mapper's unmap /
#           register decode; most do not move on a given access -- INFO)
#   rnw     strobe -> msx_slots|ram_rnw* -> {ch2_rnw_1, ch2_brnw, ch2_cpend, ch2_caddr*,
#           ch2_rq}, NOT through sdram_ce
#   din     data registers (T80 DO, NextZ80 state) -> {ch2_din_1*, ch2_bdin*}
#   addr    address-side registers (T80 u0 except DO, NextZ80 state) -> {ch2_addr_1*,
#           ch2_caddr*, ch2_hl*, ch2_baddr*}, NOT through sdram_ce, the unmap gate,
#           kanji ram_ce or ram_rnw -- the negative control (it leads, it must pass)
#   kanji   T80 IORQ_n -> kanji|ram_ce* -> the address regs, NOT through sdram_ce
#           (repeat of kanji_race3 / strobe_race on the same DB)
set out [lindex $argv 0]
set mode [expr {[llength $argv] > 1 ? [lindex $argv 1] : "tdm"}]
project_open MSX1 -revision MSX1
set f [open $out w]
if {$mode eq "sdram"} {
    set T 11.640; set M {*sdram:sdram}
} else {
    set T 7.760;  set M {*sdram_tdm:sdram}
}
puts $f "# field_race  [clock format [clock seconds] -format %Y-%m-%dT%H:%M]  mode=$mode T=$T"
#  (patterns that match nothing in one controller -- ch2_b*, ch2_hl in sdram.sv -- are dropped)
set REQ   [list $M|ch2_req_1* $M|ch2_cpend* $M|ch2_rq*]
set RNWD  [list $M|ch2_rnw_1* $M|ch2_brnw* $M|ch2_cpend* "$M|ch2_caddr\[*\]" $M|ch2_rq*]
set DIND  [list "$M|ch2_din_1\[*\]" "$M|ch2_bdin\[*\]"]
set ADRD  [list "$M|ch2_addr_1\[*\]" "$M|ch2_caddr\[*\]" $M|ch2_hl* "$M|ch2_baddr\[*\]"]
set GATEN {emu|MSX|msx_slots|mem_unmaped* emu|MSX|msx_slots|mapper_wr emu|MSX|msx_slots|mapper_en}
set GATEX {*mem_unmaped* *msx_slots|mapper_wr* *msx_slots|mapper_en*}
set FFFFX {*msx_slots|mapper_wr* *msx_slots|mapper_en*}

proc via {p pats} {
    foreach_in_collection pt [get_path_info $p -arrival_points] {
        set nd [get_point_info $pt -node]
        if {$nd eq ""} continue
        set nm [get_node_info -name $nd]
        foreach pat $pats { if {[string match $pat $nm]} { return 1 } }
    }
    return 0
}
proc rel {p} {
    return [expr {[get_path_info $p -arrival_time] - ([get_path_info $p -required_time] - [get_path_info $p -latch_time]) - [get_path_info $p -launch_time]}]
}
# {n late early k_late k_early worst_late_path}
#  Not -pairs_only: that keeps the worst path of each (from, to) pair, and for a
#  strobe that is a cartridge mapper's decode (mfrsd3 rd_edge, yamanooto scc_req ->
#  mem_unmaped -> sdram_ce), so excluding the gate left no request path at all.
#  -nworst gives several routes per endpoint; each is classified by its nodes.
#  req: if non-empty, a path must also pass a node matching one of these.
proc span {src dpats thr excl {req {}}} {
    global T
    set dst [get_registers -nowarn $dpats]
    if {[get_collection_size $dst] == 0} { return [list 0 0 0 0 0 "no dst"] }
    set mx -1e9; set mn 1e9; set wx ""; set n 0
    foreach an {setup hold} {
        set a [list -$an -from $src -to $dst -npaths 20000 -nworst 400]
        if {$thr ne ""} {
            set tn [get_nets -nowarn $thr]
            if {[get_collection_size $tn] == 0} { return [list 0 0 0 0 0 "no net $thr"] }
            lappend a -through $tn
        }
        foreach_in_collection p [get_timing_paths {*}$a] {
            if {[llength $excl] && [via $p $excl]} continue
            if {[llength $req] && ![via $p $req]} continue
            set t [rel $p]
            if {$an eq "setup"} {
                incr n
                if {$t > $mx} { set mx $t; set wx "[get_node_info -name [get_path_info $p -from]] -> [get_node_info -name [get_path_info $p -to]]" }
            } elseif {$t < $mn} { set mn $t }
        }
    }
    if {$n == 0} { return [list 0 0 0 0 0 ""] }
    return [list $n $mx $mn [expr {int(ceil($mx / $T))}] [expr {int(ceil($mn / $T))}] $wx]
}
proc line {f model cls src r} {
    set cls [format %-9s $cls]
    lassign $r n mx mn kx kn wx
    if {$n == 0} { puts $f "$model\t$cls\t$src\tNO-PATH\t$wx"; return }
    puts $f [format "%s\t%s\t%-12s\tlate %7.3f ns k=%d\tearly %7.3f ns k=%d\t%5d paths\t%s" $model $cls $src $mx $kx $mn $kn $n $wx]
}

set T80S {*T80s:T80|IORQ_n *T80s:T80|MREQ_n *T80s:T80|RD_n *T80s:T80|WR_n}
foreach model {slow fast} {
    create_timing_netlist -model $model
    read_sdc
    update_timing_netlist
    set strobes [list T80_MREQ_n {*T80s:T80|MREQ_n} T80_RD_n {*T80s:T80|RD_n} T80_WR_n {*T80s:T80|WR_n} T80_IORQ_n {*T80s:T80|IORQ_n} NZB_ph {*nz_bus:NZB|ph}]
    foreach {sn sp} $strobes {
        set src [get_registers -nowarn $sp]
        if {[get_collection_size $src] == 0} { puts $f "$model\tsrc\t$sn\tNO-SOURCE"; continue }
        line $f $model req  $sn [span $src $REQ {emu|MSX|msx_slots|sdram_ce*} $GATEX]
        line $f $model gate_ffff $sn [span $src $REQ {emu|MSX|msx_slots|sdram_ce*} {} $FFFFX]
        line $f $model gate_any  $sn [span $src $REQ {emu|MSX|msx_slots|sdram_ce*} {} $GATEX]
        line $f $model rnw  $sn [span $src $RNWD {emu|MSX|msx_slots|ram_rnw*} {*msx_slots|sdram_ce*}]
    }
    #  data and address sources
    set t80do [get_registers -nowarn {*T80s:T80|T80:u0|DO[*]}]
    line $f $model din T80_DO [span $t80do $DIND {} {}]
    set nzs [get_registers -nowarn {*NextZ80:NZ|*}]
    line $f $model din NZ_state [span $nzs $DIND {} {}]
    set t80a [remove_from_collection [get_registers -nowarn {*T80s:T80|T80:u0|*}] $t80do]
    #  address sources may pass the unmap mux (mapper_addr = mem_unmaped ? DEAD : raw):
    #  that is the address value's own route.  In the sdram.sv DB every address bit
    #  goes through a mem_unmaped~ node, so excluding the gate here left NO-PATH.
    set AX {*msx_slots|sdram_ce* *msx_slots|kanji|ram_ce* *msx_slots|ram_rnw*}
    line $f $model addr T80_u0 [span $t80a $ADRD {} $AX]
    line $f $model addr NZ_state [span $nzs $ADRD {} $AX]
    line $f $model kanji T80_IORQ_n [span [get_registers {*T80s:T80|IORQ_n}] $ADRD {emu|MSX|msx_slots|kanji|ram_ce*} {*msx_slots|sdram_ce*}]
    delete_timing_netlist
}
close $f
project_close
