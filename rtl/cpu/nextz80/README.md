# NextZ80 — imported source

NextZ80 v1.0, Nicolae Dumitrache 님, 2011.  OpenCores project `nextz80`,
LGPL 2.1 or later.  Copied verbatim from the OCM-PLD Pack v3.9.2
(`ocm_sm/src_addons/sound/opl3/`), where OCM uses it as the embedded CPU of
the OPL3 add-on -- not as a system CPU.  The v3.8.1, v3.9.1 and v3.9.2 copies
in that pack are byte-identical to each other, i.e. the 2011 original with no
downstream fixes.  Do not edit these three files in place; keep local changes
as separate patches so the provenance stays checkable.  The patches live in
`patches/` (see its README), the result that gets built in `patched/`, and
`patches/check.sh` proves the two agree.

| file | lines | md5 |
|---|---|---|
| nextz80cpu.v | 1501 | 73a2762a… |
| nextz80alu.v |  372 | d4e84309… |
| nextz80reg.v |  202 | 38039c73… |

## Why it is here

The command-engine work established that our CPU ceiling is structural: T80pa
advances one T-state per CEN_p/CEN_n pair, so it cannot go past clk21m/2 =
10.74 MHz, and P5 measurements showed the WAIT fraction does not grow with
clock (10.9% at 3.58, 23% at 5.37, 20.3% at 10.7) -- we are not memory-bound,
we are cycles-per-instruction bound.  NextZ80 spends mainly one clock per
machine cycle instead of Z80's three to six, which is the only route to
R800-class speed in this repo.  See `docs/nextz80_review_20260912.html`.

It cannot replace T80: it has no cycle-accurate mode, and stock 3.58 MHz has
to stay cycle-accurate because games time loops in T-states.  So it goes
*beside* T80 as a turbo-only second CPU.

## The bus contract, and the one thing the reference wiring already solves

Signals are ACTIVE HIGH (`MREQ`, `IORQ`, `WR`, `M1`, `HALT`), there is no RD
strobe and no refresh cycle, so `rd = MREQ & ~WR` and `iord = IORQ & ~WR` are
unambiguous.  `ADDR` is combinational straight out of ALU16
(`nextz80cpu.v:160-165`).  `WAIT` is active high and freezes the whole core --
state machine and register file alike (`nextz80cpu.v:168`,
`nextz80reg.v:96,106,112`) -- so it is our clock enable, inverted.

The worry going in was that the core samples `DI` on the same edge it presents
`ADDR`, while our VRAM/RAM are clocked spram with registered `q`.  OCM's own
wiring answers it (`opl3fm.sv:162-180`): run the core at half the memory clock
and the spare cycle is exactly the BRAM's read latency.

    edge N    CE=1  core advances, ADDR settles combinationally
    edge N+1  CE=0  BRAM registers ADDR, q becomes valid
    edge N+2  CE=1  core samples DI  -- valid

Our `ce_cpu_p` already sits in that position, so `WAIT = ~ce_cpu` reuses the
existing divider.  Note OCM also gates the write strobe with CE
(`we1(CPU_MREQ & CPU_WR & CE)`); ungated it would fire on both clocks.

## Bring-up result (2026-09-13)

`sim/tb_nextz80_bringup.v` wires the core exactly as OCM does -- `WAIT = ~CE`
with CE toggling every clock, write strobe gated `MREQ & WR & CE` -- against a
memory model with the same registered-q behaviour as `rtl/peripheral/bram.vhd`,
and runs a program that stores a computed value and then reads it back.  The
read-back is a separate check on purpose: if the DI timing is wrong the store
still looks correct and only the load is corrupt, which is the silent-damage
shape this project has been bitten by before.

    HALT at cycle 106 (core advances = 49)
    mem[1000h] = 37   mem[1001h] = 37
    RESULT: PASS

So the review's biggest unknown is closed: the half-rate enable does absorb the
BRAM latency, and no wait-state machinery is needed for the simple case.  The
same program would cost a real Z80 upwards of 200 T-states against 49 core
advances here, which is consistent with the author's "over 4 times faster".

Warm reset was checked separately and is fine: RESET restarts execution at
PC=0.  Note that it does NOT clear the general register file -- and should not,
since a real Z80 leaves those undefined after reset; only PC, I, R, IFF and IM
are specified.

★ TESTBENCH TRAP.  `RAM16X8D_regs` (`nextz80reg.v:195`) declares
`reg [7:0]data[15:0]` with no initial value.  On the FPGA that is distributed
RAM and powers up zeroed, which the design relies on; in simulation it starts X,
and since `ADDR` is combinational out of the register file the core looks
completely dead -- `ADDR=xxxx` forever, no bus activity, no HALT.  Every
testbench must zero both `regs_lo.data` and `regs_hi.data` through a
hierarchical reference before releasing reset.  Mistaking this for "the core
does not work" costs an afternoon.

## Known gaps (from the review, restated as work items)

1. No cycle-accurate mode — structural, drives the dual-CPU design.
2. ZEXALL fails four entries: `CPx(R)`, `LDx(R)`, `BIT n,(IX/IY+d)`,
   `BIT n,(HL)` — undocumented XF/YF only.  The ALU already branches
   `FOUT[3]`/`FOUT[5]` per operation (`nextz80alu.v:160-262`); `BIT n,(HL)`
   additionally needs WZ (MEMPTR) high byte, i.e. one new register.
3. No `REG[211:0]` dump, so the freeze diagnostics that tap `t80_reg`
   (`msx.sv:1693`) lose their source on this core.
4. No BUSRQ/BUSAK — unused here, we tie BUSRQ_n high today anyway.
