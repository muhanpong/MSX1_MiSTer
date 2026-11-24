set renderer none
set throttle off
set ::LOG [open test_all.txt w]
proc say {s} { puts $::LOG $s; flush $::LOG }
proc text {} {
    set base [expr {([vdpreg 2] & 0x7C) << 10}]
    set out {}
    set w [expr {([vdpreg 0] & 4) ? 80 : 40}]
    for {set y 0} {$y < 24} {incr y} {
        set s ""
        for {set x 0} {$x < $w} {incr x} {
            set c [vpeek [expr {$base + $y*$w + $x}]]
            if {$c < 32 || $c > 126} {set c 32}
            append s [format %c $c]
        }
        set s [string trimright $s]
        if {$s ne ""} {lappend out "$y: $s"}
    }
    return $out
}
proc istext {} { expr {([vdpreg 1] & 0x18) == 0x10 && ([vdpreg 0] & 0x0A) == 0} }
proc key {row bit} { keymatrixdown $row $bit; after time 0.15 [list keymatrixup $row $bit] }
# item, seconds before ESC (0 = runs to its end), time limit
set ::plan {{0 0 400} {1 0 400} {2 10 60} {3 10 60} {4 6 60} {5 0 300} {6 0 300} {7 0 120}}
set ::k 0
proc next {} {
    if {$::k >= [llength $::plan]} { say "ALL DONE"; exit }
    lassign [lindex $::plan $::k] item esc lim
    set ::t0 [machine_info time]
    say "### item $item start t=[format %.1f $::t0]"
    # to the top first (8 x up), then down item times
    for {set i 0} {$i < 8} {incr i} { after time [expr {0.4 * $i + 0.2}] {key 8 0x20} }
    for {set i 0} {$i < $item} {incr i} { after time [expr {3.4 + 0.4 * $i + 0.2}] {key 8 0x40} }
    after time [expr {3.4 + 0.4 * $item + 0.5}] {key 8 0x01}
    if {$esc > 0} { after time [expr {3.4 + $esc + 0.4 * $item}] {say "  (ESC sent)"; key 7 0x04} }
    after time [expr {3.4 + 0.4 * $item + 3}] [list wait_back $lim]
}
proc wait_back {lim} {
    if {[istext]} {
        set t [text]
        if {[string match "*ESC or B: back*" [join $t]]} {
            say "  ended at t=[format %.1f [machine_info time]] ([format %.1f [expr {[machine_info time] - $::t0}]] s):"
            foreach l $t { say "    $l" }
            key 7 0x04
            after time 2 check_menu
            return
        }
    }
    if {[machine_info time] - $::t0 > $lim} {
        say "  TIMEOUT, R#0=[format %02x [vdpreg 0]] R#1=[format %02x [vdpreg 1]]"
        foreach l [text] { say "    $l" }
        exit
    }
    after time 2 [list wait_back $lim]
}
proc check_menu {} {
    set t [join [text]]
    if {[string match "*V9968 VDP check tools*" $t]} { say "  menu back OK" } else { say "  MENU NOT BACK"; foreach l [text] { say "    $l" }; exit }
    incr ::k
    after time 1 next
}
after time 12 next
after time 3000 {say "global timeout"; exit}
