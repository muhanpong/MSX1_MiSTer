# fullsys — simulating the whole machine, instead of probing it

`sim/` holds 25 block-level Verilator benches, each compiling one to three RTL
leaves.  Until 2026-09-20 **nothing simulated `rtl/msx.sv`**, so every question of
the form "the board misbehaves and the reference does not" had to be answered by
building a bitstream (20 min), deploying it, asking the user to reproduce the
fault, and reading a 2048-word JTAG ring — about 40 minutes and one human per
question, for a ring that holds **24 ms** of a machine that emits ~10^5 events a
second.

The blocker was language: the CPU (`T80*.vhd`) and both VDPs are VHDL, which
Verilator cannot read.  `ghdl synth --out=verilog` clears it.

## Use

    sim/fullsys/prep.sh                     # -> sim/fullsys/gen/ (gitignored)
    verilator --binary --timing -Wno-fatal --top-module <tb> \
              $(cat sim/fullsys/gen/filelist.txt) sim/fullsys/tb_<name>.sv

`prep.sh` emits `gen/filelist.txt`: **exactly the files Quartus compiles**, read
out of `files.qip` and its includes, minus `MSX1.sv` (the MiSTer top, not the
machine), with the VHDL replaced by generated Verilog, the patched SystemVerilog
copies substituted, and `rtl/package.sv` first.  Regenerate it after any change
to a `.qip` — a file added to the build but not to the bench is the classic way
a bench passes while the hardware does not.

## What is generated, and why each patch is safe

| generated | from | note |
|---|---|---|
| `t80s.v` | `rtl/cpu/T80*.vhd` | 5 modules.  A machine-translated copy also exists at `rtl/cpu/cpuswap/sim/obj/t80/t80s.v` from the cpuswap lockstep bench — this one is regenerated from source instead. |
| `vdp.v` | `rtl/video/VDP/*.vhd` | 19 modules, the MSX2 VDP |
| `vdp18_core.v` | `rtl/video/vdp18/*.vhd` | 9 modules.  Both VDPs are instantiated unconditionally in msx.sv and muxed on `bios_config.MSX_typ`, so both must exist even for an MSX2-only run. |
| `rtc.v` | `rtl/peripheral/rtc.vhd` | I/O B4h/B5h.  Pulls in `rtl/peripheral/ram.vhd`. |
| `sv/wd1793.sv` | `rtl/peripheral/wd1793.sv` | two hoisted declarations, below |

`stubs.sv` replaces `rtl/peripheral/bram.vhd` (`spram`/`dpram`/`dpram_dif`) and
bare `altsyncram`.  bram.vhd is both VHDL *and* a megafunction wrapper, so
neither tool carries it across.  The replacements match it where it matters:
registered address, unregistered output (one cycle from `address` to `q`),
read-during-write returns the new data, and — the one that decides whether this
bench can see the bug at all — **`cs = 0` drives `q` to all ones**.  An MSX reads
FFh from a deselected slot, FFh executes as `RST 38h`, and a machine walking
through FFh is exactly the runaway being chased.  `MSX1.sv:1267` does the same
for the CPU bus: unmapped reads return `8'hFF`.

Six things Quartus accepts and the language does not.  Each is patched in a
**copy**, never in `rtl/`, and each is hardware-neutral:

1. `T80.vhd`: `ioq and x"7"` — a 9-bit vector ANDed with a 4-bit literal.
   Quartus zero-extends (masking the low three bits, which is what the
   INI/IND/OUTI/OUTD flag rule wants); ghdl synth refuses unequal lengths.
   Replaced with an explicit 9-bit mask.
2. `vdp_graphic4567.vhd`: a CASE on a 2-bit `std_logic_vector` with no
   `WHEN OTHERS`.  Strict VHDL wants all nine `std_logic` values covered.
3. `label : work.thing port map (...)` — that is a *component* instantiation
   naming a component called `work.thing`, which does not exist.  The entity
   form needs the keyword.  vdp18 and rtc use the shorthand throughout.
4. ghdl synth bakes generics in and emits a module with **no parameter list**,
   but msx.sv instantiates `T80s` and `vdp18_core` with parameters by name.  The
   values it passes are the VHDL defaults, so the hardware is already right; the
   generated modules just have to accept the names.  prep.sh asserts the values
   still match before patching the header.
5. VHDL is case-insensitive and Verilog is not: ghdl emits `module VDP`, msx.sv
   writes `vdp vdp_vdp`.
6. `wd1793.sv` declares `spt_addr` inside `generate if(EDSK)` and `buff_wr`
   inside `generate if(RWMODE)`, and assigns both from always blocks *outside*
   those blocks.  Quartus resolves it; Verilator will not, and when the arm is
   not taken the declaration does not exist at all.  Hoisted to module scope.

## Two ordering traps

* **Analysing a VHDL package twice obsoletes every unit already compiled against
  it.**  ghdl then black-boxes those entities and `ghdl synth` still **exits 0**
  — the netlist comes out with five empty holes where VDP_COMMAND,
  VDP_INTERRUPT, VDP_HVCOUNTER, VDP_NTSC_PAL and VDP_ACCESS_SLOTS should be.
  The Verilator lint is the only thing that catches this, which is why the lint
  is part of the conversion and not a nicety.
* **Leaves before tops.**  The MSX2 VDP uses component declarations and does not
  care, but vdp18 instantiates its sub-entities directly — and `vdp18_core.vhd`
  sorts alphabetically *before* `vdp18_cpuio.vhd`.

## Status

`prep.sh` runs clean and the whole machine elaborates:

    verilator --lint-only --top-module msx $(cat sim/fullsys/gen/filelist.txt)

Still to build, in this order:

1. the SDRAM side — reuse `tb/sdram_sim.sv` (produced from the real
   `rtl/peripheral/sdram.sv` by `tb/mkshim.py`, which splits the `inout
   SDRAM_DQ`), `tb/tb_common.sv`'s behavioural `sdram_model`, and the clk21m /
   clk_sdram phase relationship documented in `tb/README.md`; plus the ch1/ch2
   mux from `MSX1.sv:1267-1315`, since there is no arbiter module to reuse.
2. a DDR3 model that serves a real `.MSX` pack to `memory_upload`'s
   `ddr3_addr/ddr3_rd/ddr3_dout/ddr3_ready`.  Pack bytes never arrive through
   `ioctl_dout` — HPS puts the file in DDR3 and `memory_upload` reads it back.
   `sim/tb_device_reload.sv` has a toy DDR3 model to copy the shape from; no
   bench in the tree has ever read a real file (`$fopen`/`$readmem` appear
   nowhere in `sim/` or `tb/`).
3. an HPS block-device model for the floppy: on `sd_rd`, assert `sd_ack` and
   stream 512 bytes through `sd_buff_addr/sd_buff_dout/sd_buff_wr`.  `wd1793` is
   what drives `sd_lba`/`sd_rd`/`sd_wr`, via `fdc.sv` and `msx_slots.sv`.
4. a branch-target trace, to diff against the same stream from openMSX and
   bisect to the first diverging instruction.

Useful fact for (4): the machine always boots on **T80s**; `turbor.sv:174` resets
the S1990 CPU status to Z80, and NextZ80 takes the bus only after OUT E4h/E5h,
BIOS CHGCPU, or the OSD one-shot.  A-Z80 is **not** in the machine at all
(`rtl/files.qip:3`), despite `rtl/cpu/az80/` and its seven benches existing.

## How work here gets verified

Three independent legs, and a result is only trusted when at least two agree:

* **This bench** — the machine's own RTL, cycle-accurate, fully observable,
  repeatable, and free to re-run.
* **openMSX** — the reference machine.  Delegated to the peer session (see the
  memory note); it produced the FS-A1ST boot milestones, the RAM-search
  measurement that matched ours to three digits, and the negative results that
  cleared the WD2793 substitution and the missing slot 3-3.
* **A remote cloud agent** — an isolated checkout, given the hardware evidence
  and asked to audit a specific RTL path (slot/subslot decode, the mapper ports,
  the SDRAM ch2 read cache) without seeing our working hypothesis.

Cross-check everything that comes back from a delegate before acting on it.  In
this session's first mapping pass a subagent reported `rtl/peripheral/ram.vhd`
as instantiated nowhere; `rtc.vhd:589` instantiates it, and the conversion would
have come out with a hole if that had been taken on trust.
