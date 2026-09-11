# Verilator build for the ch2 word-latch testbench
RTL   = ../rtl/package.sv sdram_sim.sv
FLAGS = --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
        -Wno-BLKANDNBLK -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN

.PHONY: all latch nolatch clean
all: nolatch latch

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

clean:
	rm -rf obj_latch obj_nolatch sdram_sim.sv
