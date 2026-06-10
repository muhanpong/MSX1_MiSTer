# Auto-run timing analysis script.
# Invoked from the Makefile after `quartus_sh --flow compile`.
# Produces:
#   output_files/MSX1.worst_setup.rpt  — top 10 worst paths (compact)
#   output_files/MSX1.worst5_full.rpt  — top 5 with full path detail
#   output_files/MSX1.timing_summary.txt — concise summary printed to console
#
# Usage: quartus_sta -t report_paths.tcl

project_open MSX1

create_timing_netlist -model slow
read_sdc
update_timing_netlist

# ─── Compact top 10 worst-case setup paths ──────────────────────────────────
report_timing -setup -npaths 10 \
    -detail summary \
    -file output_files/MSX1.worst_setup.rpt

# ─── Top 5 with full path/routing for diagnosis ─────────────────────────────
report_timing -setup -npaths 5 \
    -detail full_path \
    -file output_files/MSX1.worst5_full.rpt

# ─── Per-clock fmax summary into its own file (built-in helper) ─────────────
report_clock_fmax_summary -file output_files/MSX1.fmax.rpt

# ─── Concise console-friendly summary ───────────────────────────────────────
set fp [open output_files/MSX1.timing_summary.txt w]
puts $fp "================================================================"
puts $fp " MSX1 Timing Summary  (slow 1100mV 100C corner)"
puts $fp "================================================================"
puts $fp ""
puts $fp "Worst-case setup paths (Top 10):"
puts $fp [format "%-3s %9s  %s" "#" "Slack(ns)" "From -> To"]
puts $fp [string repeat "-" 130]

set paths [get_timing_paths -setup -npaths 10]
set i 0
foreach_in_collection path $paths {
    incr i
    set slack [get_path_info $path -slack]
    set from  [get_node_info -name [get_path_info $path -from]]
    set to    [get_node_info -name [get_path_info $path -to]]
    if {[string length $from] > 50} {
        set from_short [string range $from end-49 end]
    } else {
        set from_short $from
    }
    if {[string length $to] > 70} {
        set to_short [string range $to end-69 end]
    } else {
        set to_short $to
    }
    puts $fp [format "%-3d %9.3f  %-50s -> %s" $i $slack $from_short $to_short]
}
puts $fp ""
puts $fp "Full reports:"
puts $fp "  output_files/MSX1.worst_setup.rpt — top 10 path summary"
puts $fp "  output_files/MSX1.worst5_full.rpt — top 5 with cell-level detail"
puts $fp "  output_files/MSX1.fmax.rpt        — per-clock fmax"
close $fp

# Also echo to stdout so it lands in the build log
set fp [open output_files/MSX1.timing_summary.txt r]
puts [read $fp]
close $fp

delete_timing_netlist
project_close
