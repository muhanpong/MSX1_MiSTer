set renderer none
set throttle off
array set bw {}
debug set_watchpoint write_mem 0x7FF0 {} { set v $::wp_last_value ; if {![info exists ::bw($v)]} {set ::bw($v) 0} ; incr ::bw($v) }
after time 12 {
  set f [open $::OUT w]
  foreach base {0x0000 0x1800} { set s "" ; for {set i 0} {$i<400} {incr i} { set c [debug read VRAM [expr {$base+$i}]]; append s [expr {$c>=32&&$c<127?[format %c $c]:" "}] } ; puts $f "VRAM@$base: [string trim [regsub -all { +} $s { }]]" }
  set b "" ; foreach k [lsort -integer [array names ::bw]] { append b [format "%02X:%d " $k $::bw($k)] }
  puts $f "7FF0 writes: $b   pc=[format %04X [reg pc]] iff=[reg iff]" ; close $f ; exit }
