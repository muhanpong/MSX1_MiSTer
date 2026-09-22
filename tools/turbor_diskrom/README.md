# turbor_diskrom — the turbo R disk ROM with a WD2793 driver

The Panasonic FS-A1ST / FS-A1GT keep their disk driver **and** their MSX-DOS 2
kernel in one 64 kB block of the firmware (offset 0x60000, four 16 kB banks
selected by a write to 7FF0h).  The driver talks to a TC8566AF, which this core
does not have; the core has a WD2793 (`rtl/peripheral/wd1793.sv`, Sony register
layout at 7FF8-7FFF).  Until 2026-09-23 the turbo R packs therefore carried the
Sony HB-F1XD disk ROM (DOS 1 + WD2793 driver) in slot 3-2 and a separate ASCII
MSX-DOS 2.20 kernel in slot 3-3 — and that 2.20 kernel is what broke Illusion
City and SD Snatcher (see `docs/turbor_diskrom_20260923.md` §1).

This directory holds the tooling that produces a **synthesized** 64 kB disk ROM:
the machine's own DOS 2.30 (ST) / 2.31 (GT) kernel with the TC8566AF driver
replaced by the HB-F1XD WD2793 driver.  It boots and runs both games exactly the
way the real machine does (openMSX, differential against the stock machine).

## Files

| file | what |
|---|---|
| `synth2.py` | the generator.  Reads `bank_st.rom` / `bank_gt.rom` (the 64 kB firmware block) and `hb.bin` (hb-f1xd_disk.rom), applies the 34 patches, writes `synth_{st,gt}.rom`, per-bank `.bin`, and the patch log.  **Every patch asserts the original bytes first**, so a different source ROM stops it. |
| `synth_st_patches.json`, `synth_gt_patches.json` | the 34 patches each: `[bank, address, old bytes, new bytes, why]`. |
| `analyze.py` | reproduces the static analysis that found the kernel↔driver contract (§3 of the doc). |
| `scanref.py`, `syms_b0.json` | helpers of the analysis: cross-references into the driver region, driver symbols of bank 0. |
| `omsx/BankedSonyFDC.{hh,cc}` | the openMSX device used for verification: `WD2793BasedFDC` + a TurboRFDC-style bank register at 7FF0.  openMSX has no stock device that puts a bank register and a WD2793 in one page. |
| `*.tcl`, `*.txt`, `g/`, `n/` | the openMSX probes and their logs: bank-switch watch (`bankw*`), landing points (`land*`), game milestones (`game*`), no-disk boot (`nod*`), Nextor comparison (`nx*`, `n/`). |
| `bank_st.rom`, `bank_gt.rom`, `mmcsd231.rom`, `hb.bin`, `synth_*.rom`, `*.bin` | ROM material and products.  Third-party code (ASCII / Microsoft / Sony / Panasonic); kept here for the record, not part of any distributed pack file. |

Regenerate:

    cd tools/turbor_diskrom
    python3 synth2.py          # -> synth_st.rom 94f4587d…  synth_gt.rom 86f81c71…

`bank_st.rom` = `fs-a1st_firmware.rom` (sha1 c212b11f…) bytes 0x60000-0x6FFFF;
`bank_gt.rom` = the same range of `fs-a1gt_firmware.rom` (sha1 e779c338…);
`hb.bin` = `hb-f1xd_disk.rom` (sha1 12f2cc79…).

## How the pack uses it

Block type `TURBOR_FDC` in `tools/CreateMSXpack/createMSXpack.py`
(MEMORY=FDC, MAPPER=MAPPER_TRFDC): a 4-block ROM at page 1 with the WD2793
registers in the same page.  In the pack XML:

```xml
<secondary slot="2">
  <block start="1" id="turbo R disk ROM (DOS 2.30 kernel, WD2793 driver)">
    <type>TURBOR_FDC</type>
    <block_count>4</block_count>
    <filename>fs-a1st_diskrom_wd2793.rom</filename>
    <SHA1>94f4587db749af02f82837b3dbad7fc6e55f15e9</SHA1>
  </block>
</secondary>
```

and slot 3-3 is left empty (no MSXDOS2 block).  The ROM file lives in the
untracked ROM store next to the firmware dumps
(`tools/CreateMSXpack/ROM/machines/panasonic/fs-a1{st,gt}_diskrom_wd2793.rom`).

## What the core does with it

* `rtl/peripheral/slots/msxdos2.sv` with `win_7ff0_only=1`: the bank register
  answers **only** to 7FF0 (the real TurboRFDC decodes only that; the generic
  DOS 2 cartridge windows 6000-6FFF / 7FFE would let an ASCII8 probe or a WD
  register write switch the kernel bank).
* `rtl/peripheral/slots/fdc.sv` unchanged: 7FF8-7FFB WD2793, 7FFC side, 7FFD
  drive/motor, 7FFF DRQ/IRQ status.  7FF0-7FF7 are plain ROM.
* Reset parks bank 0 (the DOS 2 kernel bank; INIT lives there).
* Benches: `sim/run_trfdc.sh` (mapper alone against openMSX semantics, and
  mapper + fdc sharing the page).  Listed in `tools/buildgate/landmines.tsv`
  under `trfdc`.

## Verification status

* openMSX (BankedSonyFDC, 2026-09-23): synth ST/GT boot to the same DOS 2
  prompt as the stock machine, take the same bank-switch sequence, and run
  Illusion City and SD Snatcher along the stock machine's path (same sector
  sequence, same stack, same boot-sector call).  Details and numbers in
  `docs/turbor_diskrom_20260923.md` §5.
* Hardware: **not yet** (needs a build with `MAPPER_TRFDC` and new packs).
