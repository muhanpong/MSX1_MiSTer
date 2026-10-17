# strobe_race.tcl -- the race MSX1.sdc's 6-cycle CPU->ch2 multicycle hides.
#
#   quartus_sta -t tools/buildgate/strobe_race.tcl <out_file>      (project dir)
#   then: git checkout -- MSX1.qsf   (project_open touches it)
#
# sdram_tdm (and sdram.sv) take the CPU request on the FIRST clk_sdram edge that
# sees it and capture address / rnw / data on that same edge (sdram_tdm.sv request-
# edge block).  MSX1.sdc relaxes every CPU path into *sdram*ch2_* to 6 cycles on the
# premise that the address is on the bus half a T-state before the strobe.  That is
# true for a memory cycle's A bus, but not for anything the strobe itself selects:
# the kanji port read (msx_slots.sv ram_addr = device_kanji_ram_ce ? ...) raises
# the request and switches the address with the same IORQ_n -- the board read
# 0-8/4096 kanji bytes on the 128.86 MHz build (2026-10-17).
#
# Paths are separated by what they pass THROUGH (first version, without this, failed
# every source: a strobe also reaches ch2_addr_1/ch2_caddr through the request
# itself -- enq / the capture enable -- and those are not address arrivals):
#   request:  strobe -> net msx_slots|sdram_ce -> {ch2_req_1, ch2_cpend, ch2_rq}
#   kanji:    strobe -> net msx_slots|kanji|ram_ce* (the ram_addr select), NOT through
#             sdram_ce -> {ch2_caddr*, ch2_addr_1*, ch2_hl*}
#   rnw:      strobe -> net msx_slots|ram_rnw*, NOT through sdram_ce -> ch2_rnw_1
#   other:    strobe -> capture registers through neither sdram_ce nor kanji ram_ce
#             (a memory cycle's mapper decode reaching the address)
# (synthesis keeps those net names; ram_addr itself does not survive.)
# For every strobe register (T80s IORQ_n/MREQ_n/RD_n/WR_n, NextZ80's nz_bus) and
# every model (slow, fast; read_sdc per model, see signoff.tcl) this prints the
# EFFECTIVE arrival of each class:
#     t = data arrival - (data required - latch edge)
# i.e. the arrival measured against the destination register's own clock edge
# (its clock latency, setup/hold and uncertainty folded in), so two groups on
# different clock-tree branches can be compared.  max from setup analysis, min from
# hold analysis.
#   request group: ch2_req_1, ch2_cpend, ch2_rq        (the decision)
#   capture group: ch2_caddr*, ch2_addr_1*, ch2_rnw_1, ch2_din_1*, ch2_hl*
# RACE verdict per (source, model):  max(capture) <= min(request) + MARGIN
# MARGIN = 0.  Whatever edge first sees the request, the captured fields must
# already be there; the request's earliest arrival is the worst case, and nothing
# ties the two groups' delays together across a die, so no credit is taken.  A
# strobe that has no path into the capture group cannot race (NO-CAPTURE-PATH).
# SKEW (INFO, not gated): ch2_req_1 and ch2_cpend must take the same request on the
# same edge (cpend = req & ~req_1; one edge apart = a lost or doubled request).
# Their arrivals through sdram_ce are printed; deciding needs the clk21m/clk_sdram
# phase of the launch, which min/max over paths cannot give.
#
# What a FAIL means: STA cannot prove the capture safe.  It does not prove the
# race happens: a strobe may reach an address bit only through logic that cannot
# change in that cycle (a memory cycle's mapper decode, say).  Read FAILs per path.
# Negative control (required, decided before the result): on the ae02602 database
# (before the kanji fix) the IORQ_n source MUST FAIL; if it passes, this check is
# invalid.
set out [lindex $argv 0]
set MARGIN 0.0
project_open MSX1 -revision MSX1
set f [open $out w]
puts $f "# strobe_race MARGIN=$MARGIN ns"
set srcs {
    T80_IORQ_n  {*T80s:T80|IORQ_n}
    T80_MREQ_n  {*T80s:T80|MREQ_n}
    T80_RD_n    {*T80s:T80|RD_n}
    T80_WR_n    {*T80s:T80|WR_n}
    NZB         {*nz_bus:NZB|*}
}
set REQ  {*sdram_tdm:sdram|ch2_req_1 *sdram_tdm:sdram|ch2_cpend *sdram_tdm:sdram|ch2_rq}
set CAPA {*sdram_tdm:sdram|ch2_caddr[*] *sdram_tdm:sdram|ch2_addr_1[*] *sdram_tdm:sdram|ch2_hl*}
set CAPR {*sdram_tdm:sdram|ch2_rnw_1}
proc eff {p} {
    return [expr {[get_path_info $p -arrival_time] - ([get_path_info $p -required_time] - [get_path_info $p -latch_time])}]
}
proc via {p pat} {
    foreach_in_collection pt [get_path_info $p -arrival_points] {
        set nd [get_point_info $pt -node]
        if {$nd eq ""} continue
        if {[string match $pat [get_node_info -name $nd]]} { return 1 }
    }
    return 0
}
# class span: paths src -> dst [-through thr], dropping those that pass a node
# matching any of $excl; returns {n max min worst_max_path}
proc span {src dpat thr excl} {
    set dst [get_registers -nowarn $dpat]
    if {[get_collection_size $dst] == 0} { return [list 0 0 0 ""] }
    set mx -1e9; set mn 1e9; set wx ""; set n 0
    foreach an {setup hold} {
        if {$thr eq ""} {
            set ps [get_timing_paths -$an -from $src -to $dst -npaths 3000 -nworst 3000 -pairs_only]
        } else {
            set tn [get_nets -nowarn $thr]
            if {[get_collection_size $tn] == 0} { return [list 0 0 0 "no net $thr"] }
            set ps [get_timing_paths -$an -from $src -through $tn -to $dst -npaths 3000 -nworst 3000 -pairs_only]
        }
        foreach_in_collection p $ps {
            set skip 0
            foreach e $excl { if {[via $p $e]} { set skip 1; break } }
            if {$skip} continue
            set t [eff $p]
            if {$an eq "setup"} { incr n; if {$t > $mx} { set mx $t; set wx "[get_node_info -name [get_path_info $p -from]] -> [get_node_info -name [get_path_info $p -to]]" } } else { if {$t < $mn} { set mn $t } }
        }
    }
    return [list $n $mx $mn $wx]
}
set fails 0
foreach model {slow fast} {
    create_timing_netlist -model $model
    read_sdc
    update_timing_netlist
    foreach {sname spat} $srcs {
        set src [get_registers -nowarn $spat]
        if {[get_collection_size $src] == 0} { puts $f "$model\t$sname\tNO-SOURCE"; continue }
        lassign [span $src $REQ {emu|MSX|msx_slots|sdram_ce} {}] nq qmax qmin qw
        if {$nq == 0} { puts $f "$model\t$sname\tno request path"; continue }
        foreach {cls dpat thr excl} [list \
                kanji $CAPA {emu|MSX|msx_slots|kanji|ram_ce*} {*msx_slots|sdram_ce*} \
                rnw   $CAPR {emu|MSX|msx_slots|ram_rnw*}      {*msx_slots|sdram_ce*} \
                other $CAPA {}                                {*msx_slots|sdram_ce* *msx_slots|kanji|ram_ce*}] {
            lassign [span $src $dpat $thr $excl] nc cmax cmin cw
            if {$nc == 0} { puts $f "$model\t$sname\t$cls\tNO-PATH\t(request min [format %.3f $qmin] max [format %.3f $qmax])"; continue }
            set ok [expr {$cmax <= $qmin + $MARGIN}]
            if {!$ok} { incr fails }
            puts $f "$model\t$sname\t$cls\t[expr {$ok ? "PASS" : "FAIL"}]\tcapture max [format %.3f $cmax] vs request min [format %.3f $qmin]  (capture min [format %.3f $cmin], request max [format %.3f $qmax], $nc paths)\t$cw"
        }
        lassign [span $src {*sdram_tdm:sdram|ch2_req_1} {emu|MSX|msx_slots|sdram_ce} {}] n1 x1 m1 w1
        lassign [span $src {*sdram_tdm:sdram|ch2_cpend} {emu|MSX|msx_slots|sdram_ce} {}] n2 x2 m2 w2
        if {$n1 > 0 && $n2 > 0} { puts $f "$model\t$sname\tSKEW-INFO\treq_1 min [format %.3f $m1] max [format %.3f $x1] | cpend min [format %.3f $m2] max [format %.3f $x2]" }
    }
    delete_timing_netlist
}
puts $f "STROBE_RACE [expr {$fails ? "FAIL" : "PASS"}] ($fails failing checks)"
close $f
project_close
