# Verilator builds for the sdram word-latch testbenches
RTL   = ../rtl/package.sv sdram_sim.sv tb_common.sv
FLAGS = --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
        -Wno-BLKANDNBLK -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN

.PHONY: all latch nolatch guard clean
all: nolatch latch guard

sdram_sim.sv: ../rtl/peripheral/sdram.sv mkshim.py
	@python3 mkshim.py $< $@

nolatch: sdram_sim.sv
	@verilator $(FLAGS) --top-module sdram_tb -GWORD_LATCH=0 \
		--Mdir obj_nolatch -o sim $(RTL) sdram_tb.sv >/dev/null
	@./obj_nolatch/sim

latch: sdram_sim.sv
	@verilator $(FLAGS) --top-module sdram_tb -GWORD_LATCH=1 \
		--Mdir obj_latch -o sim $(RTL) sdram_tb.sv >/dev/null
	@./obj_latch/sim

guard: sdram_sim.sv
	@verilator $(FLAGS) --top-module guard_tb -GP4=0 \
		--Mdir obj_guard0 -o sim $(RTL) guard_tb.sv >/dev/null
	@./obj_guard0/sim
	@verilator $(FLAGS) --top-module guard_tb -GP4=1 \
		--Mdir obj_guard -o sim $(RTL) guard_tb.sv >/dev/null
	@./obj_guard/sim

clean:
	rm -rf obj_latch obj_nolatch obj_guard obj_guard0 sdram_sim.sv
