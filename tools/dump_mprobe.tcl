# Dump the MPRB In-System-Memory BRAM (slot-0 multi-probe) over JTAG.
# Usage: quartus_stp -t tools/dump_mprobe.tcl
# 96-bit x 1024 words.  Writes one hex word per line (24 hex chars) to /tmp/mprobe_dump.txt
set hw [lindex [get_hardware_names] 0]
puts "HW: $hw"
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $hw] 1] }
puts "DEV: $dev"

set insts [get_editable_mem_instances -hardware_name $hw -device_name $dev]
set target -1; set idx 0
foreach inst $insts {
    puts "  \[$idx\] $inst"
    foreach tok $inst { if {$tok == 1024} { set target $idx } }
    incr idx
}
if {$target < 0} { puts "NO-1024-INSTANCE: MPRB not found — is the mprobe core loaded?"; exit 2 }
puts "MPRB = instance_index $target"

if {[catch {
    begin_memory_edit -hardware_name $hw -device_name $dev
    set data [read_content_from_memory -instance_index $target \
              -start_address 0 -word_count 1024 -content_in_hex]
    end_memory_edit
} err]} {
    catch { end_memory_edit }
    puts "READ-ERROR: $err"; exit 1
}

set fp [open "/tmp/mprobe_dump.txt" w]
set s [string map {" " "" "\n" ""} $data]
# 96 bits = 24 hex chars per word
set n [expr {[string length $s] / 24}]
for {set i 0} {$i < $n} {incr i} {
    puts $fp [string range $s [expr {$i*24}] [expr {$i*24+23}]]
}
close $fp
puts "WROTE $n words to /tmp/mprobe_dump.txt"
