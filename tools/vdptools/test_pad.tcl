set renderer none
set throttle off
set ::LOG [open test_pad.txt w]
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
proc key {row bit} { keymatrixdown $row $bit; after time 0.15 [list keymatrixup $row $bit] }
proc st {tag} { say "== $tag t=[format %.1f [machine_info time]] R0=[format %02x [vdpreg 0]] R1=[format %02x [vdpreg 1]] R2=[format %02x [vdpreg 2]]"; if {([vdpreg 1] & 0x18) == 0x10} { foreach l [text] { say "  $l" } } }
set ::fa 0; set ::fb 0; set ::pa 0; set ::pb 0
proc gt {} {
    set a [reg a]
    if {($a == 1 && $::fa > 0) || ($a == 3 && $::fb > 0)} {
        if {$a == 1} {incr ::fa -1} else {incr ::fb -1}
        say "  [format %.3f [machine_info time]] GTTRIG($a) -> pressed"
        set sp [reg sp]
        reg a 0xFF
        reg pc [expr {[peek $sp] | ([peek [expr {$sp+1}]] << 8)}]
        reg sp [expr {$sp + 2}]
    }
}
set ::ca 0; set ::cb 0
proc pa {} { incr ::ca; if {$::pa > 0} { incr ::pa -1; reg a [expr {[reg a] & 0xEF}] } }
proc pb {} { incr ::cb; if {$::pb > 0} { incr ::pb -1; reg a [expr {[reg a] & 0xDF}] } }
debug set_bp 0x00D8 {[pc_in_slot 0 0]} gt
debug set_bp $::env(PAD_TA) {} pa
debug set_bp $::env(PAD_TB) {} pb
proc runitem {n} { for {set i 0} {$i < 8} {incr i} { after time [expr {0.4 * $i + 0.2}] {key 8 0x20} }; for {set i 0} {$i < $n} {incr i} { after time [expr {3.6 + 0.4 * $i}] {key 8 0x40} }; after time [expr {4 + 0.4 * $n}] {set ::fa 1} }
# VDPVIEW
after time 12 {runitem 2}
after time 20 {st "VDPVIEW page 1"; say "  row reads so far: row8 $::ca row7 $::cb"}
after time 20.5 {set ::pa 20}
after time 23 {st "after pad A x20"}
after time 23.5 {set ::pa 20}
after time 26 {st "after pad A again"}
after time 27 {set ::pb 20}
after time 30 {st "after pad B"}
after time 31 {set ::fb 1}
after time 33 {st "after GTTRIG B"}
# VRAMSTRS
after time 34 {runitem 5}
after time 50 {st "VRAMSTRS"; set ::pb 5}
after time 56 {st "after pad B"}
after time 57 {set ::fb 1}
after time 59 {st "menu"; exit}
