proc r19log_start {fname} {
  set ::rlog [open $fname w]; set ::vdp_first 1; set ::vdp_b0 0
  set ::wp_w2 [debug set_watchpoint write_io 0x99 {} {
    set v $::wp_last_value
    if {$::vdp_first} { set ::vdp_b0 $v; set ::vdp_first 0 } else {
      if {$v == 0x93} { puts $::rlog [format "%d %d %04X" [machine_info VDP_frame_count] [machine_info VDP_line_in_frame] [reg pc]] }
      set ::vdp_first 1 }
  }]
  set ::wp_r2 [debug set_watchpoint read_io 0x99 {} { set ::vdp_first 1 }]
}
proc r19log_stop {} { debug remove_watchpoint $::wp_w2; debug remove_watchpoint $::wp_r2; close $::rlog }
