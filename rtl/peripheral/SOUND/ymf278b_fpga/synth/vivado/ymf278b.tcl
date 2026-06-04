# Vivado TCL: Create project, synthesize, and report for YMF278B
# Target: Zynq XC7Z020 (ZYBO-Z7-20) or XC7Z010 (ZYBO)
# Usage: vivado -mode batch -source ymf278b.tcl

set PART "xc7z020clg400-1"   ;# ZYBO-Z7-20 (change to xc7z010clg400-1 for ZYBO)
set PROJECT_NAME "ymf278b"
set PROJ_DIR   "./vivado_proj"
set RTL_ROOT   "../../rtl"

# ── Create project ────────────────────────────────────────────────────
create_project $PROJECT_NAME $PROJ_DIR -part $PART -force
set_property TARGET_LANGUAGE Verilog [current_project]

# ── Add source files ──────────────────────────────────────────────────
set rtl_files [list \
  $RTL_ROOT/pcm/ymf278_pcm_envelope.sv \
  $RTL_ROOT/pcm/ymf278_pcm_lfo.sv \
  $RTL_ROOT/pcm/ymf278_pcm_interpolator.sv \
  $RTL_ROOT/pcm/ymf278_pcm_volume.sv \
  $RTL_ROOT/pcm/ymf278_pcm_memory.sv \
  $RTL_ROOT/pcm/ymf278_pcm_top.sv \
  $RTL_ROOT/ymf278b_regs.sv \
  $RTL_ROOT/ymf278b_top.sv \
]

set opl3_files [list \
  $RTL_ROOT/opl3/modules/top_level/pkg/opl3_pkg.sv \
  $RTL_ROOT/opl3/modules/misc/src/pipeline_sr.sv \
  $RTL_ROOT/opl3/modules/misc/src/mem_simple_dual_port.sv \
  $RTL_ROOT/opl3/modules/misc/src/mem_simple_dual_port_async_read.sv \
  $RTL_ROOT/opl3/modules/misc/src/mem_multi_bank.sv \
  $RTL_ROOT/opl3/modules/misc/src/mem_multi_bank_reset.sv \
  $RTL_ROOT/opl3/modules/clks/src/clk_div.sv \
  $RTL_ROOT/opl3/modules/clks/src/reset_sync.sv \
  $RTL_ROOT/opl3/modules/operator/src/opl3_log_sine_lut.sv \
  $RTL_ROOT/opl3/modules/operator/src/opl3_exp_lut.sv \
  $RTL_ROOT/opl3/modules/operator/src/calc_envelope_shift.sv \
  $RTL_ROOT/opl3/modules/operator/src/calc_phase_inc.sv \
  $RTL_ROOT/opl3/modules/operator/src/calc_rhythm_phase.sv \
  $RTL_ROOT/opl3/modules/operator/src/phase_generator.sv \
  $RTL_ROOT/opl3/modules/operator/src/tremolo.sv \
  $RTL_ROOT/opl3/modules/operator/src/operator.sv \
  $RTL_ROOT/opl3/modules/channels/src/control_operators.sv \
  $RTL_ROOT/opl3/modules/channels/src/dac_prep.sv \
  $RTL_ROOT/opl3/modules/channels/src/channels.sv \
  $RTL_ROOT/opl3/modules/timers/src/timer.sv \
  $RTL_ROOT/opl3/modules/timers/src/timers.sv \
  $RTL_ROOT/opl3/modules/top_level/src/opl3.sv \
]

add_files -norecurse [concat $opl3_files $rtl_files]
set_property file_type SystemVerilog [get_files *.sv]

# ── Set top ───────────────────────────────────────────────────────────
set_property top ymf278b_top [current_fileset]

# ── Clock constraints ─────────────────────────────────────────────────
set XDC_FILE "$PROJ_DIR/constraints.xdc"
set fp [open $XDC_FILE w]
puts $fp {# Clock constraints}
puts $fp {create_clock -name clk      -period 29.53 [get_ports clk]}
puts $fp {create_clock -name clk_opl3 -period 69.84 [get_ports clk_opl3]}
puts $fp {set_clock_groups -asynchronous -group [get_clocks clk] -group [get_clocks clk_opl3]}
close $fp
add_files -fileset constrs_1 $XDC_FILE

# ── Synthesize ────────────────────────────────────────────────────────
synth_design -top ymf278b_top -part $PART \
    -flatten_hierarchy rebuilt \
    -keep_equivalent_registers

# ── Reports ───────────────────────────────────────────────────────────
report_utilization  -file "$PROJ_DIR/utilization.rpt"
report_timing_summary -file "$PROJ_DIR/timing.rpt" -max_paths 10
report_power        -file "$PROJ_DIR/power.rpt"

puts ""
puts "=== Synthesis complete ==="
puts "Utilization report: $PROJ_DIR/utilization.rpt"
puts "Timing report:      $PROJ_DIR/timing.rpt"

# Print brief resource summary to stdout
puts ""
puts "--- Resource Summary ---"
report_utilization -no_header -return_string
