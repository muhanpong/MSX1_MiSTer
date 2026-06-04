# Quartus resource report script
# Run from Quartus Shell: quartus_sh -t report_resources.tcl

package require ::quartus::project
package require ::quartus::flow
package require ::quartus::report

set project_name "ymf278b"

project_open $project_name

execute_flow -compile

# Load reports
load_report $project_name

set rpt [open "resource_report.txt" w]

# Summary
puts $rpt "=== Resource Report: YMF278B OPL4 ==="
puts $rpt ""

# Logic utilization
set panel_name "Fitter||Summary"
if {[is_report_panel_exists $panel_name]} {
    set num_rows [get_number_of_rows -name $panel_name]
    puts $rpt "--- Fitter Summary ---"
    for {set i 0} {$i < $num_rows} {incr i} {
        puts $rpt [get_report_panel_row -name $panel_name -row $i]
    }
}

# Resource usage by entity
set panel_name "Analysis & Synthesis||Analysis & Synthesis Resource Usage Summary"
if {[is_report_panel_exists $panel_name]} {
    set num_rows [get_number_of_rows -name $panel_name]
    puts $rpt ""
    puts $rpt "--- Resource Usage ---"
    for {set i 0} {$i < $num_rows} {incr i} {
        puts $rpt [get_report_panel_row -name $panel_name -row $i]
    }
}

# Timing summary
set panel_name "TimeQuest Timing Analyzer||Clocks"
if {[is_report_panel_exists $panel_name]} {
    puts $rpt ""
    puts $rpt "--- Timing (Clocks) ---"
    set num_rows [get_number_of_rows -name $panel_name]
    for {set i 0} {$i < $num_rows} {incr i} {
        puts $rpt [get_report_panel_row -name $panel_name -row $i]
    }
}

close $rpt
project_close

puts "Resource report written to resource_report.txt"
