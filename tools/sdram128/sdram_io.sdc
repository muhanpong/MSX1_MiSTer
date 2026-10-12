# SDRAM pin timing for the sdram128 study (sdram_tdm at 128.86 MHz).
#
# Chip numbers: AS4C32M16SB-7 class (CL3): tAC 5.4 ns, tOH 2.5 ns, tIS 1.5 ns,
# tIH 0.8 ns.  Board: one trace each way, 0.3-0.7 ns assumed (the MiSTer SDRAM
# module sits on the GPIO header; not measured).
#
# SDRAM_CLK is clk_sdram inverted through a DDIO output (sdram_tdm.sv sdramclk_ddr).
# The chip samples commands on its rising edge, half a clock after the FPGA
# launches them; read data launched by the chip edge before the "valid" edge is
# taken by the FPGA rising edge 1.5 clocks after that launch (sdram_tdm.sv: dq_p).
#
# Read by tools/sdram128/io_sta.tcl on top of MSX1.sdc (analysis only for now).

set clk_s   {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set t_ac    5.4
set t_oh    2.5
set t_is    1.5
set t_ih    0.8
set brd_max 0.7
set brd_min 0.3

create_generated_clock -name sdram_clk_pin -source [get_pins $clk_s] -invert [get_ports {SDRAM_CLK}]

# commands, address (incl. DQM = A12/A11), write data: chip setup/hold
set sdram_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_DQML SDRAM_DQMH SDRAM_DQ[*]}]
set_output_delay -clock sdram_clk_pin -max [expr {$t_is + $brd_max}]        $sdram_out
set_output_delay -clock sdram_clk_pin -min [expr {-$t_ih + $brd_min}]       $sdram_out

# read data: launched by the chip edge (tAC max, tOH min), plus the trace back
set_input_delay  -clock sdram_clk_pin -max [expr {$t_ac + $brd_max}] [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk_pin -min [expr {$t_oh + $brd_min}] [get_ports {SDRAM_DQ[*]}]
# the capture is dq_n, a clk_sdram FALLING-edge register, at the falling edge about
# 1.5 clocks after the launching chip edge (sdram_tdm.sv: the window measured on
# a253d77 holds no rising edge).  TimeQuest's default latch is the first falling
# edge after the launch; -end 2 moves it one clock on.
set_multicycle_path -setup -end 2 -from [get_clocks sdram_clk_pin] -to [get_clocks $clk_s]
set_multicycle_path -hold  -end 1 -from [get_clocks sdram_clk_pin] -to [get_clocks $clk_s]
