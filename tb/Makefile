# Verilator builds for the sdram word-latch testbenches
RTL   = ../rtl/package.sv sdram_sim.sv tb_common.sv
FLAGS = --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT \
        -Wno-BLKANDNBLK -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN

.PHONY: all latch nolatch guard kanji clean
all: nolatch latch guard kanji

# 'latch'/'nolatch' target names kept: cache on (8192 lines) / off

sdram_sim.sv: ../rtl/peripheral/sdram.sv mkshim.py
	@python3 mkshim.py $< $@

nolatch: sdram_sim.sv
	@verilator $(FLAGS) --top-module sdram_tb -GCACHE_LINES=0 \
		--Mdir obj_nolatch -o sim $(RTL) sdram_tb.sv >/dev/null
	@./obj_nolatch/sim

latch: sdram_sim.sv
	@verilator $(FLAGS) --top-module sdram_tb -GCACHE_LINES=8192 \
		--Mdir obj_latch -o sim $(RTL) sdram_tb.sv >/dev/null
	@./obj_latch/sim

guard: sdram_sim.sv
	@verilator $(FLAGS) --top-module guard_tb -GP4=0 \
		--Mdir obj_guard0 -o sim $(RTL) guard_tb.sv >/dev/null
	@./obj_guard0/sim
	@verilator $(FLAGS) --top-module guard_tb -GP4=1 \
		--Mdir obj_guard -o sim $(RTL) guard_tb.sv >/dev/null
	@./obj_guard/sim

#  Two bus shapes: T80s (address held past the strobe) and nz_bus/NextZ80 (next
#  stage's address on the edge the strobe falls) -- the second is the R800 kanji
#  fault of 2026-09-23 and fails on the pre-fix kanji.sv.
kanji: sdram_sim.sv
	@verilator $(FLAGS) --top-module kanji_tb \
		--Mdir obj_kanji -o sim $(RTL) ../rtl/peripheral/slots/kanji.sv kanji_tb.sv >/dev/null
	@./obj_kanji/sim
	@verilator $(FLAGS) --top-module kanji_tb -GNZ_BUS=1 \
		--Mdir obj_kanji_nz -o sim $(RTL) ../rtl/peripheral/slots/kanji.sv kanji_tb.sv >/dev/null
	@./obj_kanji_nz/sim

clean:
	rm -rf obj_latch obj_nolatch obj_guard obj_guard0 obj_kanji obj_kanji_nz sdram_sim.sv
