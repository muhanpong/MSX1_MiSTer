# Timing constraints for YMF278B OPL4

# Master clock: 33.8688 MHz
create_clock -name clk -period 29.53 [get_ports clk]

# OPL3 clock: 14.318 MHz
create_clock -name clk_opl3 -period 69.84 [get_ports clk_opl3]

# Treat different clock domains as asynchronous
set_clock_groups -asynchronous -group [get_clocks clk] -group [get_clocks clk_opl3]

# Input/output delays (relaxed for virtual pins)
set_input_delay  -clock clk -max 2.0 [get_ports {io_* mem_rd_*}]
set_input_delay  -clock clk -min 0.5 [get_ports {io_* mem_rd_*}]
set_output_delay -clock clk -max 2.0 [get_ports {audio_* mem_addr* mem_rd_req io_data_out* io_ack irq_n}]
set_output_delay -clock clk -min 0.0 [get_ports {audio_* mem_addr* mem_rd_req io_data_out* io_ack irq_n}]
