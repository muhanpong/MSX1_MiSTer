#!/usr/bin/env bash
# FM golden comparison: verilate gtaylormb opl3 + link Nuked-OPL3, run scenarios.
set -e
cd "$(dirname "$0")"
R=../../..
M=$R/rtl/opl3/modules

verilator --cc --exe --build -j 4 -O3 --top-module opl3 \
  -Wno-WIDTH -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-CASEINCOMPLETE \
  -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-MULTIDRIVEN \
  -Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH -Wno-SIDEEFFECT -Wno-ASCRANGE -Wno-fatal \
  $M/top_level/pkg/opl3_pkg.sv \
  $M/misc/src/pipeline_sr.sv $M/misc/src/edge_detector.sv \
  $M/misc/src/mem_simple_dual_port.sv $M/misc/src/mem_simple_dual_port_async_read.sv \
  $M/misc/src/mem_multi_bank.sv $M/misc/src/mem_multi_bank_reset.sv \
  $M/misc/src/synchronizer.sv $M/misc/src/afifo.v $M/misc/src/leds.sv \
  $M/clks/src/clk_div.sv $M/clks/src/reset_sync.sv \
  $M/operator/src/opl3_log_sine_lut.sv $M/operator/src/opl3_exp_lut.sv \
  $M/operator/src/calc_envelope_shift.sv $M/operator/src/calc_phase_inc.sv \
  $M/operator/src/calc_rhythm_phase.sv $M/operator/src/envelope_generator.sv \
  $M/operator/src/ksl_add_rom.sv $M/operator/src/phase_generator.sv \
  $M/operator/src/tremolo.sv $M/operator/src/vibrato.sv $M/operator/src/operator.sv \
  $M/channels/src/control_operators.sv $M/channels/src/dac_prep.sv \
  $M/channels/src/channels.sv \
  $M/timers/src/timer.sv $M/timers/src/timers.sv \
  $M/host_if/src/host_if.sv $M/host_if/src/trick_sw_detection.sv \
  $M/top_level/src/opl3.sv \
  sim_main.cpp ../third_party/nuked_opl3.c \
  -o fm_golden 2>&1 | tail -5

./obj_dir/fm_golden
