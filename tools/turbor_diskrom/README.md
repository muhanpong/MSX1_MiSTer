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
| `synth_diskrom.py` | the generator.  Finds your own dumps by sha1 in the pack builder's ROM store (`fs-a1st_firmware.rom` / `fs-a1gt_firmware.rom`, or an already cut 64 kB disk ROM, and `hb-f1xd_disk.rom`), cuts 0x60000-0x6FFFF, applies the 34 patches and writes `fs-a1{st,gt}_diskrom_wd2793.rom` next to the firmware.  **Every patch asserts the original bytes first**, the output is checked against the known sha1, and an existing output is never overwritten unless identical.  The file holds addresses and the few jump/call bytes we write, no ROM content. |
| `synth_st_patches.json`, `synth_gt_patches.json` | the 34 patches each: `[bank, address, old bytes, new bytes, why]`. |
| `analyze.py` | reproduces the static analysis that found the kernel↔driver contract (§3 of the doc).  Reads `hb.bin` (= hb-f1xd_disk.rom) and the firmware from the working directory; copy your dumps in first, they are git-ignored here. |
| `scanref.py`, `syms_b0.json` | helpers of the analysis: cross-references into the driver region, driver symbols of bank 0. |
| `omsx/BankedSonyFDC.{hh,cc}` | the openMSX device used for verification: `WD2793BasedFDC` + a TurboRFDC-style bank register at 7FF0.  openMSX has no stock device that puts a bank register and a WD2793 in one page. |
| `*.tcl`, `*.txt`, `g/`, `n/` | the openMSX probes and their logs: bank-switch watch (`bankw*`), landing points (`land*`), game milestones (`game*`), no-disk boot (`nod*`), Nextor comparison (`nx*`, `n/`). |

No ROM material is kept in this directory (`.gitignore` blocks `*.rom`, `*.bin`):
the inputs are third-party code (ASCII / Microsoft / Sony / Panasonic) and stay in
the untracked ROM store.  Generate from your own dumps:

    python3 tools/turbor_diskrom/synth_diskrom.py          # both; or: st / gt
    # st: OK  fs-a1st_diskrom_wd2793.rom  sha1 94f4587d  patches 34  written
    # gt: OK  fs-a1gt_diskrom_wd2793.rom  sha1 86f81c71  patches 34  written

Inputs it looks for (by sha1, anywhere under `--store`, default
`tools/CreateMSXpack/ROM`): `fs-a1st_firmware.rom` c212b11f… (disk ROM at
0x60000 = 84a44ecf…), `fs-a1gt_firmware.rom` e779c338… (0527fb75…),
`hb-f1xd_disk.rom` 12f2cc79….  `--out DIR` writes elsewhere, `--patches`
rewrites the two patch logs (they come out identical to the committed ones).

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
* Hardware (2026-09-24, `MSX1_20260923d_kanjifix`): Illusion City runs on the
  ST DOS2 pack and on the GT DOS2 pack (as `FS-A1GT DOS2-ILLUK`, the Korean
  translation with its own kanji font); SD Snatcher runs on ST.
