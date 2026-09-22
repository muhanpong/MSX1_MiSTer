set renderer none
set throttle off
after time 0.5 {
  set f [open "/tmp/claude-1000/-home-muhanpong-Documents-github-MSX1-MiSTer-sonydos2/20a36377-a863-4f49-95d5-7add2e20673b/scratchpad/dos23/probe.txt" w]
  foreach d [debug list] { if {[string match -nocase "*fdc*" $d] || [string match -nocase "*disk*" $d]} { puts $f "debuggable: $d size=[debug size $d]" } }
  set nm "Memory Mapped FDC ROM"
  puts $f "before: [format %02X [debug read $nm 0x10]] [format %02X [debug read $nm 0x11]]"
  if {[catch {debug write_block $nm 0x10 [binary format c3 {0x11 0x22 0x33}]} e]} { puts $f "write_block error: $e" }
  puts $f "after : [format %02X [debug read $nm 0x10]] [format %02X [debug read $nm 0x11]] [format %02X [debug read $nm 0x12]]"
  close $f ; exit }
