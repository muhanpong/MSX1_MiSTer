# Read the CPU event recorder (rtl/evt_trace.sv, ISM instance "EVTR",
# 2048 x 80) over JTAG.  usage: quartus_stp -t tools/dump_evtrace.tcl
# then: python3 tools/parse_evtrace.py /tmp/evtrace_dump.txt
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
    if {[lsearch -exact $inst "EVTR"] >= 0} { set target $idx }
    incr idx
}
if {$target < 0} { puts "NO-EVTR-INSTANCE: is a core with evt_trace loaded?"; exit 2 }
puts "EVTR = instance_index $target"
if {[catch {
    begin_memory_edit -hardware_name $hw -device_name $dev
    set data [read_content_from_memory -instance_index $target -start_address 0 -word_count 2048 -content_in_hex]
    end_memory_edit
} err]} { catch { end_memory_edit }; puts "READ-ERROR: $err"; exit 1 }
set fp [open "/tmp/evtrace_dump.txt" w]
set s [string map {" " "" "\n" ""} $data]
set n [expr {[string length $s] / 20}]
for {set i 0} {$i < $n} {incr i} { puts $fp [string range $s [expr {$i*20}] [expr {$i*20+19}]] }
close $fp
puts "WROTE $n words to /tmp/evtrace_dump.txt"
