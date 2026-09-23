# Panasonic firmware mapper — turbo R slot 3-3 (2026-09-23)

The last block type the turbo R packs still needed. Slot 3-3 of an FS-A1ST / FS-A1GT
holds the firmware ROM behind Panasonic's own mapper, together with the machine's
battery SRAM. `MAPPER_PANASONIC` + the pack block types `PANASONIC16` / `PANASONIC32`
add it. Research branch `pana_mapper` (from `nextz80` a9260ad).

## 0. What it is

Eight **8 kB regions cover the whole address space** 0000-FFFF, each with its own
9-bit bank register. That is unlike every other mapper in this core, which bank a
16 kB page or two. A bank value selects ROM, the SRAM, or the main RAM.

| machine | ROM | openMSX `<sramsize>` | bank numbers |
|---|---|---|---|
| FS-A1ST | 2 MB (blocks 0-255) | 16 | ROM 0x000-, SRAM 0x080-0x081 |
| FS-A1GT | 4 MB (blocks 0-511) | 32 | ROM 0x000-, SRAM 0x080-0x083 |

The ST firmware dump is 4 MB but its upper half is entirely FF (measured), which is
why openMSX gives the ST `lastblock 255` and the GT `lastblock 511`.

## 1. Semantics

Taken verbatim from openMSX `RomPanasonic.cc` (`writeMem` / `peekMem`, read
2026-09-23), not from documentation or memory.

**Bank register writes.** Region = bits 12:10 of the *write* address, and **regions
5 and 6 are exchanged** (`region ^= 3` in openMSX):

| write address | region | address space it banks |
|---|---|---|
| 6000-63FF | 0 | 0000-1FFF |
| 6400-67FF | 1 | 2000-3FFF |
| 6800-6BFF | 2 | 4000-5FFF |
| 6C00-6FFF | 3 | 6000-7FFF |
| 7000-73FF | 4 | 8000-9FFF |
| 7400-77FF | **6** | C000-DFFF |
| 7800-7BFF | **5** | A000-BFFF |
| 7C00-7FEF | 7 | E000-FFFF |

- **7FF8** sets bit 8 of all eight banks at once, bit *i* → region *i*.
- **7FF9** is the control register.

**Read-back**, gated by the control register (otherwise the ROM byte is returned):

| control bit | address | returns |
|---|---|---|
| 2 (0x04) | 7FF0-7FF7 | low 8 bits of `bank[addr[2:0]]` |
| 4 (0x10) | 7FF8 | `{bank7[8] … bank0[8]}` |
| 3 (0x08) | 7FF9 | the control byte |

**Bank value decode**, in this order:

1. `0x080` ≤ bank < `0x080 + sramsize/8` → **SRAM**, block = bank − 0x80.
   Both machines set `sram-mirrored=false`, so the window is exactly the SRAM size.
2. bank ≥ `0x180` → **main RAM** — *not implemented*, see §3.
3. otherwise → **ROM**, bank × 8 kB, wrapped to the ROM size.

## 2. What was added

| file | change |
|---|---|
| `rtl/peripheral/slots/panasonic.sv` | new: the mapper (102 LUT / 80 registers in a Quartus 17.0 map) |
| `rtl/package.sv` | `MAPPER_PANASONIC` appended to `mapper_typ_t` (25 of 32 used) |
| `rtl/peripheral/slots/msx_slots.sv` | instance, address mux row, `sram_cs`/`sram_wr` merge, unmapped OR, read-back into `cpu_din` |
| `rtl/peripheral/slots/files.qip` | source registered |
| `tools/CreateMSXpack/createMSXpack.py` | block types `PANASONIC16` (SRAM 16) and `PANASONIC32` (SRAM 32) |
| `sim/tb_panasonic.sv`, `sim/run_panasonic.sh`, `sim/sim_panasonic.cpp` | the bench |

The SRAM size reaches the mapper as `size_sram` (`lookup_SRAM[].size`, in kB), which
until now no mapper read — halnote and the others hard-code their window.

## 3. Not implemented: the main-RAM banks

Banks ≥ 0x180 page the **main RAM** into this slot. openMSX wires the RAM device into
the mapper (`<device idref="Main RAM"/>`); reaching another slot's RAM allocation is
an `msx_slots`-level change, so here those banks report `mem_unmaped` — they read FF
and swallow writes. They deliberately do **not** alias ROM, so if firmware uses them
the failure is loud rather than silent corruption. The bench asserts exactly that.

Whether the turbo R firmware needs them is untested. That is the first thing to find
out on hardware or in a full-machine run.

## 4. Verification

`sim/run_panasonic.sh` — 30 checks, **PASSED**. Written for Verilator 4 (this sandbox
has 4.038, and `sim/fullsys` needs Verilator 5), so the clock comes from
`sim_panasonic.cpp` and the stimulus is an op table walked two cycles per op.

Covered: reset parks bank 0; each of the eight region-write addresses; the 5/6
exchange in both directions; bit 8 via 7FF8 on a 4 MB ROM and its wrap on a 2 MB one;
every control-gated read-back and that each is silent while its bit is clear; the SRAM
window for both 16 kB and 32 kB including the first bank past it; `sram_we` on a write
inside the window; main-RAM banks reporting unmapped and not SRAM; and that writes at
4000 and 9000 move no bank.

Mutation tested — each of these turns the run to FAIL:

| mutation | caught by |
|---|---|
| region 5/6 exchange removed | op 15, the 7400 → C000 check |
| control gating ignored (always read back) | op 27, 7FF0 while control = 0 |
| SRAM window fixed at 8 banks (`sram-mirrored=true`) | op 44, bank 0x82 on a 16 kB machine |
| main-RAM banks treated as ROM | op 55, the unmapped check |
| 7FF8 bit order reversed | op 22, bank 0x100 after bit 0 |

`quartus_map` 17.0: **0 errors**. The only port note is `rom_size[13..0]` stuck at GND,
which is the 16 kB size granularity and is identical on the existing `msxdos2` instance.

## 5. Open items

1. **Main-RAM banks** (§3) — needed or not, and if needed, how `msx_slots` reaches the
   RAM mapper's allocation.
2. **Pack XMLs.** The turbo R packs live on branch `sony-dos2-3-3`, not here, and today
   leave 3-3 empty. Adding `PANASONIC16` / `PANASONIC32` there is the next step, with
   the firmware ROM as the block file and the SRAM size picked per machine.
3. **No hardware or full-machine run yet.** `sim/fullsys` needs Verilator 5, which this
   sandbox does not have.
4. The FS-A1GT's firmware SRAM is what its "SRAMdisk by JS" option uses
   (`docs/turbor_diskrom_20260923.md` §3); with 3-3 populated that code becomes
   reachable for the first time.
