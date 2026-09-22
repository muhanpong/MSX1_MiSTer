set renderer none
set throttle off
array set cnt {} ; set first {}
debug set_watchpoint write_mem 0x7FF0 {} {
  set a8 [debug read ioports 0xA8]
  if {(($a8>>2)&3)==3} {
    set v $::wp_last_value
    if {![info exists ::cnt($v)]} { set ::cnt($v) 0 ; lappend ::first [format "%02X@t=%.3f pc=%04X" $v [machine_info time] [reg pc]] }
    incr ::cnt($v) } }
proc key {row mask} { keymatrixdown $row $mask ; after time 0.10 "keymatrixup $row $mask" }
after time 33.0 {key 8 0x40}
after time 33.5 {key 8 0x40}
after time 35.0 {key 7 0x80}
after time 60 {
  set f [open $::OUT w]
  foreach k [lsort -integer [array names ::cnt]] { puts $f [format "bank %02X : %d writes" $k $::cnt($k)] }
  puts $f "first seen: $::first" ; close $f ; exit }
