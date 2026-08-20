# TODO — the MSX numeric keypad is unmapped (16 matrix positions dead)

Status: **known, deliberately deferred** (2026-08-21). Not a regression — inherited
from upstream. No action taken; recorded so it is not re-discovered from scratch.

---

## What is missing

The MSX keyboard matrix is 11 rows x 8 columns, read through PPI port C
(`rtl/msx.sv:547`, `kb_row = ppi_out_c[3:0]`). Our map fills **rows 0-8 only**.
Rows 9 and 10 are the numeric keypad and are entirely empty:

```
row  9 :  NUM*  NUM+  NUM/  NUM0  NUM1  NUM2  NUM3  NUM4
row 10 :  NUM5  NUM6  NUM7  NUM8  NUM9  NUM-  NUM,  NUM.
```

Every host keypad scancode (`0x69`, `0x6B`, `0x6C`, `0x70`-`0x7D`, `E0 4A`,
`E0 5A`) reads `0xFF` = unmapped in `rtl/peripheral/kbd.mif`. Verified by decoding
all 512 LUT entries: 73 keys mapped, rows used = `[0..8]`, rows 9/10 = 0 entries.

Consequence: software that reads the MSX keypad cannot receive those keys at all —
there is no host key that produces them. Affects some Japanese titles, a few
MSX-DOS / Nextor tools, and several BASIC utilities.

Harmless in the meantime: an unmapped entry decodes as `pos = 8'b1 << 4'hF`, which
truncates to 0 in 8 bits, so `row_state` is untouched and rows 11-15 are never
scanned (`rtl/peripheral/keyboard.sv:35-40`). The `0xFF` sentinel is genuinely inert.

## This is NOT ours

Upstream `MiSTer-devel/MSX1_MiSTer` has the same gap. Its `rtl/keyboard.vhd` is a
VHDL case statement rather than a LUT, and it only ever references
`keyMatrix(0)`..`keyMatrix(8)` — `keyMatrix(9)` and `keyMatrix(10)` do not appear.
A position-by-position diff of the two maps found **zero** placement differences;
the only extra entries on our side are the right Shift (`0x59`) alias and the
extended-key addressing (`0x1XX`), which upstream expresses differently. So the
port to a LUT lost nothing.

Same for the two other "where is that key" complaints, also inherited:
* `SELECT` = **F11** (`0x78` -> row 7 bit 6). Correct per the MSX standard matrix;
  upstream's source even comments it `-- F11 (SELECT)`.
* `STOP` = **PrtScr** (`E0 7C` -> row 7 bit 4). Awkward, because `CTRL+STOP` is the
  BASIC break and PrtScr needs the framework's `E0 12 E0 7C` special case
  (`sys/hps_io.sv:302`). openMSX puts STOP on F8. F6/F7/F8 are all free here, so
  moving it is a one-byte change — but see the tail below.

## Why it is not a one-byte fix

`rtl/peripheral/kbd.mif` is only the power-on default. `memory_upload.sv:271-275`
and `:326-341` (`STATE_FILL_KBD`) stream a 512-byte `CONFIG_KBD_LAYOUT` record from
the ROM PACK straight over the same LUT at boot, and
`tools/CreateMSXpack/createMSXpack.py:250-256` emits it from a base64
`<kbd_layout>` element in the machine XML.

**44 of the 48 machine XMLs carry a `kbd_layout`, and all 44 are byte-identical to
`kbd.mif`.** So changing `kbd.mif` alone changes nothing on real hardware — the
pack overwrites it. A real fix is:

1. edit `rtl/peripheral/kbd.mif` (16 bytes for the keypad, or 1 byte to move STOP),
2. regenerate the `<kbd_layout>` blob in all 44 machine XMLs,
3. rebuild the ROM PACKs with `tools/CreateMSXpack`.

The four XMLs without a layout are the `CART_FW_*` firmware packs, not machines.

## Why deferred

No content we currently run is known to need the keypad. Revisit if a title turns
up that does. The mechanism above is also the reason a per-machine keypad layout
would be easy once someone does the pack regeneration once.

## Anchors

* `rtl/peripheral/keyboard.sv` — LUT lookup, `map[7:4]` = row, `map[3:0]` = column
* `rtl/peripheral/kbd.mif` — the 512-byte default, unchanged since `d422302` (2023-03-19)
* `rtl/peripheral/slots/memory_upload.sv:271,326` — runtime override path
* `tools/CreateMSXpack/createMSXpack.py:250` — where the blob is emitted
* upstream reference: `git show origin/main:rtl/keyboard.vhd`
