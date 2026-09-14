# Read the A-Z80 bus trace ring (rtl/cpu/az80/az80_trace.sv, ISM instance "CPUT",
# 1024 x 48) over JTAG.  usage: quartus_stp -t tools/dump_aztrace.tcl
# then: python3 tools/parse_aztrace.py /tmp/aztrace_dump.txt
set hw [lindex [get_hardware_names] 0]
puts "HW: $hw"
set dev ""
foreach d [get_device_names -hardware_name $hw] { if {[string match -nocase "*5CSE*" $d]} { set dev $d } }
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $hw] 1] }
puts "DEV: $dev"
set insts [get_editable_mem_instances -hardware_name $hw -device_name $dev]
set target -1; set idx 0
foreach inst $insts {
    puts "  \[$idx\] $inst"
    if {[lsearch -exact $inst "CPUT"] >= 0} { set target $idx }
    incr idx
}
if {$target < 0} { puts "NO-CPUT-INSTANCE: is the aztrace core loaded?"; exit 2 }
puts "CPUT = instance_index $target"
if {[catch {
    begin_memory_edit -hardware_name $hw -device_name $dev
    set data [read_content_from_memory -instance_index $target -start_address 0 -word_count 1024 -content_in_hex]
    end_memory_edit
} err]} { catch { end_memory_edit }; puts "READ-ERROR: $err"; exit 1 }
set fp [open "/tmp/aztrace_dump.txt" w]
set s [string map {" " "" "\n" ""} $data]
set n [expr {[string length $s] / 12}]
for {set i 0} {$i < $n} {incr i} { puts $fp [string range $s [expr {$i*12}] [expr {$i*12+11}]] }
close $fp
puts "WROTE $n words to /tmp/aztrace_dump.txt"
