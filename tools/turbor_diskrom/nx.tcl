set throttle off
set minframeskip 0
set maxframeskip 0
proc W {s} { set f [open "$::DIR/$::TAG.log" a]; puts $f $s; close $f }
proc T {} { return [format %8.3f [machine_info time]] }
set nd 0 ; set crash 0 ; array set bw {}
debug set_bp 0x4010 {} { if {[machine_info time]>5} { incr ::nd
  if {[reg de]==0x000B || $::nd<=2} { W "[T] DSKIO sec=[format %04X [reg de]] n=[format %02X [expr {[reg bc]>>8}]] dst=[format %04X [reg hl]] sp=[format %04X [reg sp]] FE=[debug read MapperIO 2] FF=[debug read MapperIO 3]" } } }
debug set_watchpoint write_mem 0xF2CF {} { W "[T] F2CF<-[format %02X $::wp_last_value]" }
debug set_bp 0xC01E {} { W "[T] C01E CY=[expr {[reg f]&1}]" }
debug set_bp 0x0000 {} { if {[machine_info time]>9 && !$::crash} { set ::crash 1 ; W "[T] *** PC=0000 sp=[format %04X [reg sp]]" } }
debug set_watchpoint write_mem 0x7FF0 {} { set a8 [debug read ioports 0xA8]
  if {(($a8>>2)&3)==3} { set v $::wp_last_value ; if {![info exists ::bw($v)]} { set ::bw($v) 0 ; W "[T] first bank $v" } ; incr ::bw($v) } }
foreach t {6 9 12 16 20} { after time $t "catch {screenshot $::DIR/$::TAG.b$t.png}" }
proc key {row mask} { keymatrixdown $row $mask ; after time 0.10 "keymatrixup $row $mask" }
if {$::GAME eq "ic"} {
  after time 33.0 {key 8 0x40} ; after time 33.5 {key 8 0x40} ; after time 35.0 {key 7 0x80}
  after time 80 { catch {screenshot "$::DIR/$::TAG.t80.png"} ; W "[T] end DSKIO=$::nd crash=$::crash" ; exit }
} else {
  foreach t {26 28 30 32 34 36 38 40 42 44} { after time $t "catch {screenshot $::DIR/$::TAG.$t.png}" }
  after time 45 { W "[T] end DSKIO=$::nd crash=$::crash" ; exit }
}
