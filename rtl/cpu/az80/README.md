# A-Z80 — imported source

A-Z80, Goran Devic 님, ~2020.  https://github.com/gdevic/A-Z80

**Licence: GNU GPL v2** (`LICENSE.txt`, and the project's own `readme.txt:49`
says "covered under the GNU GPL2.0").  Note that the OpenCores project page
advertises it as *LGPL* — that is wrong, and the difference matters if anyone
plans a combination that relies on it.  This repository is GPL v2 as well, so
the two go together without further thought.

Copied from the upstream tree: `cpu/{toplevel,alu,bus,control,registers}`,
excluding `test_*` benches and `data_pins_lattice.v` (a Lattice-specific
alternative that collides with `data_pins.v` if both are compiled).

## Why it is here

Unlike T80, A-Z80 is not built from documentation.  It was reconstructed from
die images and patents — the PLA table comes out of a photograph of the silicon
— and its timing is a per-opcode M/T matrix rather than an approximation.  What
that buys, measured rather than claimed:

| | T80 (v350) | A-Z80 |
|---|---|---|
| origin | docs + 20 years of community fixes | die + patents |
| ZEXALL | passes, SCF/CCF XF/YF fail | passes, XF/YF fail on 2 sets |
| WAIT | **broken in the core** (T80pa.vhd:51); the wrapper works around it by withholding CEN entirely | "correct behavior of nWAIT and nBUSRQ" |
| Fmax on 5CSEBA6U23I7 | our build closes at 21.5 MHz | **29.2 MHz** (measured, standalone) |
| ALMs | — | **925 (2%)** |

Bring-up (`sim/tb_az80_bringup.sv`) runs a loop that computes 55, stores it and
reads it back — the read-back is checked separately because a wrong read path
leaves the store looking correct.  It finishes in **225 clocks** where a real
Z80 needs about 222 T-states for the same code, i.e. **1.4% off**, the
remainder being reset-to-first-fetch.  The same program costs NextZ80 49 core
advances.  That is the cycle accuracy, as a number.

## The two things that shape the integration

**No clock enable.**  The ports are the Z80 pinout and nothing else, because
parts of the design latch on `~clk` (`bus/address_pins.v:66`,
`bus/data_pins.v:83`, five flops in `control/resets.v`).  So it needs a real
clock, which is what `rtl/peripheral/az80_clkgen.sv` makes — from `clk_sdram`,
not `clk21m`, because 85.909090 divides evenly by 24/16/12/8/4 to give all five
speeds at a 50% duty cycle, and a skewed duty would eat the margin of the very
half-cycle paths that cap this core.

**No REG(211:0)/DIRSet/DIR.**  T80 hands out its whole register file as one
vector; A-Z80 keeps each register in its own `reg_latch` instance on an internal
tri-state bus (`registers/reg_latch.v`), so there is no bundle to forward.
`msx.sv` has twenty `t80_reg` readers — every one was checked, including
`booted` and `im2_tbl_hi`, which read as functional and are not — and all of
them are `dbg_*` forensics.  They tie off; the machine does not lose a feature,
but the freeze / RST38-spin / IFF diagnostics go dark on this core, which is
worth remembering because a CPU swap is exactly when they would be wanted.

## The ceiling, and why it cannot be raised

29.2 MHz is not a tuning result, it is the shape of the design.  The worst path,
and the five behind it, are all the same:

    From  ir:ir_|opcode[2]        (instruction register)
    To    alu:alu_|op2_high[3]    (ALU operand latch)
    Launch CLK, Latch CLK (INVERTED), relationship 2.500, data delay 16.642 ns

Launch on the rising edge, latch on the falling one: half a period for 16.6 ns
of logic, so ~33 ns and 29.2 MHz.  Without the half cycle the same logic would
run near 58 MHz — that is the author's "50% penalty", and it is a property of
the design, not of the device.  Moving that latch to the rising edge would fix
it and would also change T-state-internal timing, which is the thing this core
exists to get right.
