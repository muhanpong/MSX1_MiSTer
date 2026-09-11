# ASO: a black screen that was the core destroying its own interrupt flag

2026-09-11. Fixed in `c7ff270`, shipped as `MSX1_20260911d_fhfix.rbf`, confirmed
on hardware together with Zanac EX, Go Figure and Putty Camiyon showing no
regression.

## The report

ASO is a turboR-only title patched to run on a Z80 MSX2+: its 24 R800
`MULUB`/`MULUW` instructions were replaced with `RST 08h`/`RST 10h` trampolines
into Z80 routines, and the turboR check was removed. On the core it reached its
title screen, and pressing SPACE left it on a permanently black, silent screen.
The same build played correctly in openMSX.

## What it was

The core cleared the VDP's horizontal (line) interrupt flag at vertical
blanking, on top of the S#1 read that is supposed to clear it:

```vhdl
-- rtl/video/VDP/vdp_interrupt.vhd, before the fix
IF( CLR_HSYNC_INT = '1' OR (W_VSYNC_INTR_TIMING = '1' AND V_BLANKING_START = '1') )THEN
    FF_HSYNC_INT_N <= '1';
```

That is not what the chip does. openMSX resets `irqHorizontal` in exactly three
places -- chip reset, the S#1 read while IE1 is on, and an R#0 write that turns
IE1 off (`src/video/VDP.cc`) -- and never at blanking. The V9938 documentation
agrees: FH is the CPU's to clear by reading S#1.

On its own that looks harmless, because blanking is far from where a line
interrupt normally fires. It is not harmless, because **the blanking point moves
with R#9**:

```vhdl
-- rtl/video/VDP/vdp_ssg.vhd
W_V_BLANKING_START <= '1' WHEN( (REG_R9_Y_DOTS = '0' AND FF_MONITOR_LINE = 192) OR
                                (REG_R9_Y_DOTS = '1' AND FF_MONITOR_LINE = 212) )ELSE '0';
```

This reads the **live** R#9, not the value latched when the frame began. So a
handler that switches to 212-line mode mid-frame drags that frame's flag
destruction from line 192 to line 212.

ASO does exactly that. Its frame runs two line interrupts:

| | line | handler does |
|---|---|---|
| first | 104 (`R#19 = 68h`) | sets `R#19 = D2h` (210) and **`R#9 = 212 lines`** |
| second | 210 (`R#19 = D2h`) | draws the split, then sets the frame flag at `9402h` |

The main loop waits on that flag:

```
065D: LD HL,9402h / XOR A
0661: OR (HL)          <- where the core was stuck
0662: JR Z,0661h
```

So: the first handler moves the blanking point to counter 212, which is **two
lines** after its own match at 210. ASO's interrupt chain -- RAM `0038h`, the
DOS handler, `CALSLT` into the BIOS `0038h`, `KEYI`, `H.KEYI`, and finally the
resident blob's `IN A,(99h)` at `80F2h` -- takes **3.60 lines** to reach that
S#1 read. The flag was gone before the ISR looked at it, every time. The handler
took its no-FH branch, `9402h` was never set, and the main loop waited forever
with the display still off from the first handler.

Later cycles would have survived: once `R#23` becomes 18h the second match moves
to counter 186, 26 lines clear of the destruction. But the game never gets past
the first one.

The fix is to stop clearing FH at blanking. `CLR_HSYNC_INT` -- the S#1 read, and
this core's long-standing R#19 / IE1-on writes -- is the whole clear path now.

## The route there, including the wrong turns

Worth recording, because most of the elapsed time went into hypotheses that were
wrong, and two of them were wrong in instructive ways.

**Everything that was ruled out.** The Panasonic turbo port (ASO never touches
I/O 40h/41h, statically or dynamically). The turbo VDP pacer (the OTIR that
loads the command registers spaces its writes 21 T-states apart, 42 clk21m even
at 10.7 MHz, against a worst-case 28 clk21m VRAM slot period). The SDRAM ch2
read path. The SCC+ mapper, on the grounds that it and plain SCC share
`MAPPER_KONAMI_SCC` and differ only in a RAM overlay. The DOS kernel -- the
user's SCC-ported DOS2 reproduces fine in openMSX. MoonSound's `/INT`. The
machine pack, since a Sony pack failed identically. Command size, VDP command
throttling, and the HR flag, all of which were shown to be structurally incapable
of stalling.

**The measurement that was wrong.** Early on I claimed the command engine was
about 3.8x faster than openMSX, from reading the wait tables as nanoseconds per
byte. They are not. `ACTIVE <= FF_WAIT_CNT(15)` is a duty gate sitting on top of
however many slots the arbiter has left over after display fetches, so the same
table value means different speeds with the display on and off -- which is why
the display-off table holds *smaller* numbers than the display-on one and is
still faster. The tell was right there and I walked past it. Retracted, after a
companion session had already built analysis on top of it.

**The reasoning that was wrong.** Once the vblank clear was found, I dismissed
it: the second match sits 26 lines before the end of the frame, so 1.65 ms of
slack, so the CPU has plenty of time. That measured the wrong interval. What has
to fit is not "interrupt accepted" but "ISR reaches the S#1 read", and it is not
measured against the end of the frame but against wherever `V_BLANKING_START`
happens to be that frame -- which the game had just moved. Both corrections came
from the companion session, and they are what closed the case.

**What actually found it.** Two things. The user's screenshot, which showed the
machine was black rather than frozen on the title, and which happened to have
the debug overlay on -- the overlay already draws the live PC, and reading
`0x0661` out of the pixels gave the address that the other session then
identified. And the freeze detectors in `rtl/msx.sv`, all seven of them dark,
which ruled out an IRQ storm, a WAIT deadlock and a halted CPU in one look. The
CPU was alive and spinning; that narrowed it to a software wait loop.

## What is still wrong

A second FH defect, found during this hunt and deliberately left alone because
ASO does not depend on it: **with IE1 off, this core reports S#1 bit 0 as 0**,
where openMSX computes a position-derived window roughly 288 ticks wide starting
at the R#19 match (316 in text mode) -- `VDP.cc`, the `else` branch of the S#1
read. Software that polls FH for raster timing without enabling the interrupt
works there and hangs here.

Fixing it needs care. The suppression is not an accident: it was put in for
Zanac EX, whose game-over R#23 roll let a wandering match set a flag that the
title screen's handler then acted on. The way out is openMSX's shape -- a
transient positional window rather than a sticky latch -- which satisfies Zanac
too, since the flag would read 0 by the time its VBLANK handler looks. That is a
design note, not a tested change.

## For next time

- Detectors have a scope. `dbg_irq_stuck` watches `ms_irq_n_sync`, the MoonSound
  line, not "any interrupt". It happened to be complete here only because the
  Z80's `/INT` has exactly two sources and the other one was disabled.
- The debug overlay is a usable instrument at a distance. A photograph of it
  carries the live PC, the register probes and all seven freeze detectors, and
  `tools/overlay/decode_probe.py` reads the bars out of a PNG so nobody has to
  count pixels.
- When a divergence is measured against a reference, check what the reference
  actually does rather than what its comments say. The vblank clear survived for
  years behind a comment about `scheduleHScan` gating on IE1, which is true of
  the interrupt scheduling and not of the flag.
