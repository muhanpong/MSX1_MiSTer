proc vdplog_start {fname} {
  set ::vlog [open $fname w]
  set ::vdp_first 1; set ::vdp_b0 0
  set ::wp_w [debug set_watchpoint write_io 0x99 {} {
    set v $::wp_last_value
    if {$::vdp_first} { set ::vdp_b0 $v; set ::vdp_first 0 } else {
      if {$v & 0x80} { puts $::vlog [format "W %d %d R%d=%02X pc=%04X" [machine_info VDP_frame_count] [machine_info VDP_line_in_frame] [expr {$v & 0x3f}] $::vdp_b0 [reg pc]] }
      set ::vdp_first 1
    }
  }]
  set ::wp_r [debug set_watchpoint read_io 0x99 {} {
    set ::vdp_first 1
    puts $::vlog [format "S %d %d S%d pc=%04X" [machine_info VDP_frame_count] [machine_info VDP_line_in_frame] [expr {[debug read {VDP regs} 15] & 0x0f}] [reg pc]]
  }]
}
proc vdplog_stop {} { debug remove_watchpoint $::wp_w; debug remove_watchpoint $::wp_r; close $::vlog }
