#!/usr/bin/env bash
# Simulation runner for ymf278b_fpga using Icarus Verilog
# Usage: ./run_sim.sh [tb_name]   default: all

set -e
cd "$(dirname "$0")/.."

RTL="rtl"
TB="tb"
SIM="sim"

OPL3_MODULES="
  rtl/opl3/modules/top_level/pkg/opl3_pkg.sv
  rtl/opl3/modules/misc/src/pipeline_sr.sv
  rtl/opl3/modules/misc/src/mem_simple_dual_port.sv
  rtl/opl3/modules/misc/src/mem_simple_dual_port_async_read.sv
  rtl/opl3/modules/misc/src/mem_multi_bank.sv
  rtl/opl3/modules/misc/src/mem_multi_bank_reset.sv
  rtl/opl3/modules/clks/src/clk_div.sv
  rtl/opl3/modules/clks/src/reset_sync.sv
  rtl/opl3/modules/operator/src/opl3_log_sine_lut.sv
  rtl/opl3/modules/operator/src/opl3_exp_lut.sv
  rtl/opl3/modules/operator/src/calc_envelope_shift.sv
  rtl/opl3/modules/operator/src/calc_phase_inc.sv
  rtl/opl3/modules/operator/src/calc_rhythm_phase.sv
  rtl/opl3/modules/operator/src/phase_generator.sv
  rtl/opl3/modules/operator/src/tremolo.sv
  rtl/opl3/modules/operator/src/operator.sv
  rtl/opl3/modules/channels/src/control_operators.sv
  rtl/opl3/modules/channels/src/dac_prep.sv
  rtl/opl3/modules/channels/src/channels.sv
  rtl/opl3/modules/timers/src/timer.sv
  rtl/opl3/modules/timers/src/timers.sv
  rtl/opl3/modules/i2s/src/i2s.sv
  rtl/opl3/modules/top_level/src/opl3.sv
"

PCM_MODULES="
  rtl/pcm/ymf278_pcm_envelope.sv
  rtl/pcm/ymf278_pcm_lfo.sv
  rtl/pcm/ymf278_pcm_interpolator.sv
  rtl/pcm/ymf278_pcm_volume.sv
  rtl/pcm/ymf278_pcm_memory.sv
  rtl/pcm/ymf278_pcm_top.sv
  rtl/ymf278b_regs.sv
  rtl/ymf278b_top.sv
"

IVFLAGS="-g2012 -Wall"

run_tb() {
    local name=$1
    local extra_src="${2:-}"
    echo ""
    echo "────────────────────────────────────────"
    echo "Running: $name"
    echo "────────────────────────────────────────"
    iverilog $IVFLAGS \
        -I rtl/opl3/modules/top_level/pkg \
        $extra_src \
        tb/${name}.sv \
        -o sim/${name}.vvp 2>&1 | head -50
    if [ -f sim/${name}.vvp ]; then
        vvp sim/${name}.vvp | tee sim/${name}.log
    else
        echo "Compilation failed for $name"
        return 1
    fi
}

TARGET="${1:-all}"

mkdir -p sim

case "$TARGET" in
    tb_pcm_envelope)
        run_tb tb_pcm_envelope "$PCM_MODULES"
        ;;
    tb_pcm_slot)
        run_tb tb_pcm_slot "rtl/pcm/ymf278_pcm_interpolator.sv"
        ;;
    tb_ymf278b_top)
        run_tb tb_ymf278b_top "$OPL3_MODULES $PCM_MODULES"
        ;;
    all)
        run_tb tb_pcm_envelope "$PCM_MODULES" || true
        run_tb tb_pcm_slot "rtl/pcm/ymf278_pcm_interpolator.sv" || true
        run_tb tb_ymf278b_top "$OPL3_MODULES $PCM_MODULES" || true
        ;;
    *)
        echo "Usage: $0 [tb_pcm_envelope|tb_pcm_slot|tb_ymf278b_top|all]"
        exit 1
        ;;
esac

echo ""
echo "Done. VCD files and logs saved to sim/"
