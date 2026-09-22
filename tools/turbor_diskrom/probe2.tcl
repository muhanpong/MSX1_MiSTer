set renderer none
set throttle off
after time 3 { set f [open "/tmp/claude-1000/-home-muhanpong-Documents-github-MSX1-MiSTer-sonydos2/20a36377-a863-4f49-95d5-7add2e20673b/scratchpad/dos23/probe2.txt" w]
  puts $f "pc=[format %04X [reg pc]] slots: [string map {"\n" " | "} [slotselect]]"
  set s ""; for {set i 0} {$i<120} {incr i} { set c [debug read VRAM $i]; append s [expr {$c>=32&&$c<127?[format %c $c]:"."}] }
  puts $f "VRAM: $s"; close $f; exit }
