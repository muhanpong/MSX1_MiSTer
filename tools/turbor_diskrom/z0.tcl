set renderer none
set throttle off
set n 0
debug set_bp 0x0000 {} { if {[machine_info time]>1 && [incr ::n]<=2} { set f [open $::OUT a]; puts $f [format "t=%.3f PC=0000 sp=%04X  ret=%02X%02X" [machine_info time] [reg sp] [debug read memory [expr {[reg sp]+1}]] [debug read memory [reg sp]]]; close $f } }
after time 11 exit
