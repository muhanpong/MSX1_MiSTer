set renderer none
set throttle off
set armed 0 ; set n 0 ; set prev -9
proc tr {} { set pc [reg pc]
  if {$pc != $::prev+1 && $pc != $::prev+2 && $pc != $::prev+3} { incr ::n
    set f [open $::OUT a]; puts $f [format "   %04X (from %04X) sp=%04X blk=%s" $pc $::prev [reg sp] [debug read {Memory Mapped FDC romblocks} [expr {$pc & 0xE000}]]]; close $f
    if {$::n>40} { catch {debug remove_condition $::cid}; exit } }
  set ::prev $pc ; return 0 }
debug set_watchpoint write_mem 0x7FF0 {} {
  if {$::wp_last_value==3 && !$::armed} { set ::armed 1
    set f [open $::OUT a]; puts $f "t=[format %.4f [machine_info time]] write 03 at pc=[format %04X [reg pc]] sp=[format %04X [reg sp]] ret=[format %02X%02X [debug read memory [expr {[reg sp]+1}]] [debug read memory [reg sp]]]"; close $f
    set ::cid [debug set_condition {[tr]}] } }
after time 20 {exit}
