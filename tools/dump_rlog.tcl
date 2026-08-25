# Dump the RLOG In-System-Memory BRAM (ch4 read-address trace) over JTAG.
# Usage: quartus_stp -t tools/dump_rlog.tcl
# Enumerates ISM instances, picks the 2048-deep one (RLOG), writes 16-bit words
# (one hex word per line, MSB-first within the word) to /tmp/rlog_dump.txt
set hw [lindex [get_hardware_names] 0]
puts "HW: $hw"
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match -nocase "*5CSE*" $d]} { set dev $d }
}
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $hw] 1] }
puts "DEV: $dev"

set insts [get_editable_mem_instances -hardware_name $hw -device_name $dev]
puts "ISM INSTANCES (index depth width type ...):"
set target -1
set tdepth 0
set idx 0
foreach inst $insts {
    puts "  \[$idx\] $inst"
    # element layout: {index name ... depth width type mode}; find depth==2048
    foreach tok $inst { if {$tok == 2048} { set target $idx; set tdepth 2048 } }
    incr idx
}
if {$target < 0} {
    puts "NO-2048-INSTANCE: RLOG not found — is the rdaddrcap core loaded on the MiSTer?"
    exit 2
}
puts "RLOG = instance_index $target (depth $tdepth)"

if {[catch {
    begin_memory_edit -hardware_name $hw -device_name $dev
    set data [read_content_from_memory -instance_index $target \
              -start_address 0 -word_count 2048 -content_in_hex]
    end_memory_edit
} err]} {
    catch { end_memory_edit }
    puts "READ-ERROR: $err"
    exit 1
}

set fp [open "/tmp/rlog_dump.txt" w]
set s [string map {" " "" "\n" ""} $data]
set n [expr {[string length $s] / 4}]
for {set i 0} {$i < $n} {incr i} {
    puts $fp [string range $s [expr {$i*4}] [expr {$i*4+3}]]
}
close $fp
puts "WROTE $n words to /tmp/rlog_dump.txt"
