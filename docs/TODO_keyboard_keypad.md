# DONE — the MSX numeric keypad (matrix rows 9 and 10) is mapped

Status: **implemented 2026-08-25**, simulated with a working negative control,
**not yet tested on hardware**. Previously deferred twice (2026-08-21, re-confirmed
2026-08-23) on the belief that it required regenerating 44 machine XMLs and the
ROM PACKs. **That belief was wrong** — see *What the earlier analysis got wrong*.

> **First build carrying this:** `MSX1_20260826b_opllpace.rbf` (built by the turbo
> session from the tree at `3567edf`, timing closed, worst slack +0.321). Defaults
> are Off, so it is a regression check for the classic path until someone turns
> the switch on. Hardware results pending.

---

## What was missing

The MSX keyboard matrix is 11 rows x 8 columns, read through PPI port C
(`rtl/msx.sv:564`, `kb_row = ppi_out_c[3:0]`). The map filled **rows 0-8 only**.
Rows 9 and 10 are the numeric keypad and were entirely empty:

```
row  9 :  NUM*  NUM+  NUM/  NUM0  NUM1  NUM2  NUM3  NUM4
row 10 :  NUM5  NUM6  NUM7  NUM8  NUM9  NUM-  NUM,  NUM.
```

Every host keypad scancode read `0xFF` = unmapped, so software that reads the MSX
keypad could not receive those keys at all — there was no host key that produced
them. 73 of 512 entries were mapped; now 91.

Not a regression — inherited from upstream, which has the same gap
(`git show origin/main:rtl/keyboard.vhd` only ever references `keyMatrix(0..8)`).

## The map

Value format is `{row[3:0], col[3:0]}`; the address is the 9-bit
`{extended, ps2_code}`. `keyboard.sv:16` already declared `row_state[16]`, so
**no RTL change was needed for rows 9/10 to work** — only data.

| PS/2 | host key | value | matrix | source |
|---|---|---|---|---|
| `0x7C` | keypad `*` | `0x90` | 9.0 | shipped pack |
| `0x79` | keypad `+` | `0x91` | 9.1 | shipped pack |
| `E0 4A` (`0x14A`) | keypad `/` | `0x92` | 9.2 | **added here** |
| `0x70` | keypad 0 | `0x93` | 9.3 | shipped pack |
| `0x69` | keypad 1 | `0x94` | 9.4 | shipped pack |
| `0x72` | keypad 2 | `0x95` | 9.5 | shipped pack |
| `0x7A` | keypad 3 | `0x96` | 9.6 | shipped pack |
| `0x6B` | keypad 4 | `0x97` | 9.7 | shipped pack |
| `0x73` | keypad 5 | `0xA0` | 10.0 | shipped pack |
| `0x74` | keypad 6 | `0xA1` | 10.1 | shipped pack |
| `0x6C` | keypad 7 | `0xA2` | 10.2 | shipped pack |
| `0x75` | keypad 8 | `0xA3` | 10.3 | shipped pack |
| `0x7D` | keypad 9 | `0xA4` | 10.4 | shipped pack |
| `0x7B` | keypad `-` | `0xA5` | 10.5 | shipped pack |
| `0x7E` | **ScrollLock** | `0xA6` | 10.6 | **added here** |
| `0x71` | keypad `.` | `0xA7` | 10.7 | shipped pack |
| `E0 5A` (`0x15A`) | keypad Enter | `0x77` | 7.7 (RET alias) | **added here** |
| `0x6A` | JIS yen | `0x14` | 1.4 | shipped pack |

**The 15 "shipped pack" values were not derived — they were lifted.**
`releases/CreateMSXpack/MSX/Sony/Sony_HB-F1XV_128KB.MSX` carries a `kbd_layout`
blob (sha1 `5782fd49d147…`) that differs from `kbd.mif` in exactly 15 bytes, and
every one of them is a keypad entry. An independent derivation from the MSX
standard matrix agreed byte-for-byte. `sim/check_keypad_consts.py` re-anchors
against that pack on every run, when it is present locally.

Three judgement calls, all documented in the RTL:

* **NUM `,` has no PC equivalent.** ScrollLock (`0x7E`) stands in — it was free and
  the framework does not special-case it.
  ⚠️ **NumLock `0x77` is unusable**: the Pause sequence makes `sys/hps_io.sv:301`
  emit a plain `0x77` **press** whose matching release is rewritten to `0x377`
  (`hps_io.sv:304`), so a key mapped there would latch stuck-down after any Pause.
* **PC keypad Enter has no MSX counterpart**, so it aliases RET — the same pattern
  already accepted for LShift/RShift, which both map to `0x60`. Known artifact:
  holding both Enters and releasing one clears the bit.
* **Plain `0x7C` (keypad `*`) does not collide with STOP.** STOP is the *extended*
  `E0 7C` = `0x17C`; PrtScr always sets the extended bit, so the two never alias.
  All 18 target addresses were `0xFF` before the change — zero collisions.

## What the earlier analysis got wrong

The mechanism it described was right; the conclusion was not.

**Confirmed:** `kbd.mif` is only the power-on default.
`rtl/peripheral/slots/memory_upload.sv:320` (`CONFIG_KBD_LAYOUT`) and `:376`
(`STATE_FILL_KBD`) stream a 512-byte record from the ROM PACK over the same BRAM at
boot. All 44 machine XMLs carry a `<kbd_layout>`, and all 44 decode to a blob
**byte-identical to `kbd.mif`** (sha1 `870402c7a072cd8a3685c5c4f9e08b25cba462a7`,
same as the checked-in `tools/CreateMSXpack/ROM/kbd_svg8240.bin`). So the pack
write is a no-op today — but it would have clobbered any new mif. Editing
`kbd.mif` alone really does change nothing once a pack loads.

**Refuted:** that a real fix therefore needs 44 XMLs regenerated and the ROM PACKs
rebuilt. The pack fill was a *single* assignment, `kbd_din <= ddr3_dout`
(now `memory_upload.sv:385`).
Substituting the keypad bytes there decouples the fix from the packs entirely.
The task was ~20 lines, not a pack-regeneration project — and it never touches the
`FC1` path.

Stale anchors in the old text, corrected: `kb_row` is `rtl/msx.sv:564` (not `:547`),
`CONFIG_KBD_LAYOUT` was `memory_upload.sv:285` (not `:271`) and `STATE_FILL_KBD`
`:341` (not `:326`) before this change; they sit at `:320` and `:376` after it.

## What landed

1. **`rtl/peripheral/kbd.mif`** — 18 bytes patched. Rows 9 and 10 now have all 8
   columns each; 73 -> 91 mapped entries. Fixes the power-on default.
2. **`rtl/peripheral/slots/memory_upload.sv`** — new `kbd_keypad()` function (`:80`), and
   `kbd_din <= (ddr3_dout == 8'hFF) ? kbd_keypad(kbd_addr) : ddr3_dout;`.
   Guarding on `0xFF` means a pack that *does* define the keypad (the
   `HB-F1XV_128KB` one) still wins. Cost: one 18-entry case in an FSM that only
   runs at upload time.
3. **`sim/tb_keypad.sv` + `sim/run_keypad.sh`** — drives real make/break codes into
   `keyboard` and reads the matrix back through `kb_row`/`kb_data`. 23 keys:
   all 16 keypad positions, keypad Enter, and 6 ordinary keys as a regression
   guard (including `main /` vs `keypad /` and `E0 7C` STOP vs plain `0x7C`).
   `NEGCTL=1` forces rows 9/10 back to `0xFF`: **exactly the 16 keypad checks
   fail**, the other 7 still pass — the negative control works.
4. **`sim/check_keypad_consts.py`** — asserts `kbd.mif` and `kbd_keypad()` agree in
   both directions, that both keypad rows are complete, and that the values still
   match the shipped pack. Mutation-proven (flipping one RTL byte makes it fail).

Not done, deliberately: `tools/CreateMSXpack/ROM/kbd_svg8240.bin` and the 44
`<kbd_layout>` blobs are unchanged. With (2) in place they are cosmetic, and
touching them means a pack rebuild, which needs the BIOS ROM set and is the
`FC1` path.

## Still to do

* **Hardware test.** BASIC `A$=INKEY$` loop, or read rows 9/10 directly. Also
  re-verify a normal-key sweep and that Pause sticks nothing — per this project's
  own history, any refit can perturb placement, so boot the whole thing, do not
  just press keypad keys.
* Decide whether ScrollLock is the right home for NUM `,`, and whether keypad
  Enter aliasing RET is wanted. Both are one-byte changes in two places
  (the mif and `kbd_keypad()`), and `check_keypad_consts.py` will catch it if only
  one of the two is edited.

## Unrelated, still open

* `SELECT` = **F11** (`0x78` -> row 7 bit 6). Correct per the MSX standard matrix;
  upstream comments it `-- F11 (SELECT)`. Left alone.
* `STOP` = **PrtScr** (`E0 7C` -> row 7 bit 4). Awkward, because `CTRL+STOP` is the
  BASIC break and PrtScr needs the framework's `E0 12 E0 7C` special case
  (`sys/hps_io.sv:302-303`). openMSX puts STOP on F8; F6/F7/F8 are all free here, so
  moving it is now genuinely a one-byte change in the same two places. Not done —
  nobody asked for it, and it changes a binding people may have learned.

## Anchors

* `rtl/peripheral/keyboard.sv:45` — the 512x8 `spram`, `mem_init_file("kbd.mif")`
* `rtl/peripheral/keyboard.sv:35-36` — `row = map[7:4]`, `pos = 1 << map[3:0]`
* `rtl/peripheral/kbd.mif` — the default table (was unchanged since `d422302`, 2023-03-19)
* `rtl/peripheral/slots/memory_upload.sv:80,320,376,385` — keypad fill + pack override path
* `tools/CreateMSXpack/createMSXpack.py:250-256` — where `<kbd_layout>` is emitted
* upstream reference: `git show origin/main:rtl/keyboard.vhd`
