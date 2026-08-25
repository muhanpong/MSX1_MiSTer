# B3 — Cheat Tooling Assets Inventory (MSX1_MiSTer)

Cataloged 2026-06-27. Facts only, no judgement. All paths absolute.

---

## 1. Webapp — `msx1_cheat_editor.html`

- **Path:** `/home/muhanpong/Documents/github/MSX1_MiSTer/tools/msx1_cheat_editor.html`
- **Size:** 26,643 bytes (mtime 2026-06-25 22:42). Single self-contained HTML+JS file, no deps.
- **Title:** "MSX1_MiSTer Cheat (.CHT) Editor"
- **What it does:** Browser GUI to author/edit cheats as a table of rows `{on, name, addr(hex), val(hex)}`. Imports and exports several formats.

### Import paths
- **Load `.mcf` (blueMSX):** parses `type,address,value,flag,description` (decimal addr/value). Loads ALL rows, default ON. addr range 0..0xFFFF enforced.
- **Load existing `.cht`:** reads 4-byte records `{addr_lo, addr_hi, value, flags}`; restores rows (`on = b[i+3]&1`). Names are NOT stored in `.cht`, so import shows blank names.
- **Load `.zip` (MiSTer):** parses zip central directory, reads `.gg` entries.

### Export A — raw `.cht` (custom F9 loader)
- 4 bytes/cheat, little-endian: **`{addr_lo, addr_hi, value, flags}`**, `flags` bit0 = enable (0x01).
- Exports ALL valid rows (on and off). Target engine is 4-way set-associative, 512 sets × 4 ways; `SET_MASK = 0x1FF` (set index = addr & 0x1FF). UI warns on >4 cheats colliding in one set.
- Deploy: copy to `/media/fat/games/MSX1/`.

### Export B — MiSTer-standard `.zip` of `.gg`
- One `.gg` file per cheat inside a STORE-only zip (hand-built zip writer in JS, valid CRC32, date 1980-01-01).
- `.gg` entry filename (minus `.gg`) = description shown in OSD.
- **`.gg` byte layout (16 bytes = 4 LE uint32):** `addr32, compare32=0, replace32=value, flag32=0`.
  - JS code: `data[0]=addr&0xFF; data[1]=(addr>>8); data[8]=value;` (rest zero).
  - **This is the addr-first "self-consistent {addr,0,value,0}" form, NOT NES-standard `{flags,addr,compare,replace}`.**
- Deploy: `/media/fat/cheats/<CoreName>/<romname>.zip` (base name must match ROM name/CRC).
- **Status:** Not unit-tested directly, but the byte format it emits is identical to `mcf2mister.py` output and to what TB `tb_std` (index 255) PASSES against (see §4).

---

## 2. `mcf2cht.py` — blueMSX `.mcf` → custom 4-byte `.cht`

- **Path:** `/home/muhanpong/Downloads/blueMSXv282full/Tools/Cheats/mcf2cht.py` (4,240 bytes, 2026-06-23)
- **Input:** dir of blueMSX `.mcf` (`type,address,value,flag,description`, decimal). Only `type==0` converted; non-0/out-of-range/multi-byte skipped with notes.
- **Output:** one `.cht` per game (binary). **EXACT format per cheat, 4 bytes LE:**
  ```
  byte0 = addr & 0xFF
  byte1 = (addr >> 8) & 0xFF
  byte2 = value & 0xFF
  byte3 = 0x01            ; flags, enable forced on
  ```
  Cheats concatenated; empty `.cht` still written for 1:1 mapping. Writes `_manifest.tsv`.
- **Target:** core's F9 `.CHT` loader (ioctl index 6/9 per docstring). HW applies first N=16 entries (register design) but all valid cheats written.
- **Output dir:** `/home/muhanpong/Downloads/blueMSXv282full/Tools/Cheats/msx_cht/`
  - 753 `.cht` files + `_manifest.tsv` (14,806 bytes). Dir 3.0M. (Task said "752"; actual on disk = 753.)
- **Status:** Present, runs; output verified against twinbee (see §6).

---

## 3. `mcf2mister.py` — blueMSX `.mcf` → standard `.zip`/`.gg`

- **Path:** `/home/muhanpong/Downloads/blueMSXv282full/Tools/Cheats/mcf2mister.py` (6,520 bytes, 2026-06-25) — **EXISTS on disk** (a prior agent's note that it might be absent is stale/incorrect).
- **Input:** dir of `.mcf`. Splits each line into max 5 fields (description may contain commas). addr 0..65535, value 0..255 enforced; others skipped.
- **Output:** one `.zip` per game (ZIP_STORED, fixed 1980-01-01 timestamp). Each cheat = one `.gg` entry; entry name = sanitized description + `.gg`; duplicate names suffixed `_2`, `_3`.
- **EXACT record (the struct.pack):**
  ```python
  struct.pack("<IIII", addr & 0xFFFFFFFF, 0, value & 0xFFFFFFFF, 0)
  # => addr32 | compare32=0 | replace32=value | flag32=0   (16 bytes LE)
  ```
- **OPEN QUESTION (resolved by evidence):** layout produced is **`{addr, compare=0, replace=value, flag=0}`** (addr in first uint32, value in 3rd/"replace" slot). This is the **self-consistent {addr,0,value,0} form that the core's own standard loader expects** (TB `tb_std` drives index 255, 16B/rec, `{addr32,cmp32,replace32,flag32}` and PASSES — §4). It is **NOT** the NES-standard `{flags,addr,compare,replace}` ordering. mcf2mister.py, the HTML editor, and tb_std all agree on this addr-first layout.
- **Output dir:** `/home/muhanpong/Downloads/blueMSXv282full/Tools/Cheats/msx_mister/`
  - 753 `.zip` files + `_manifest.tsv` (16,425 bytes). Dir 3.3M. (Task said "752"; actual = 753.)
- **Status:** Present, runs; output verified against twinbee and matches the zip deployed on the board byte-for-byte (§6).

### Source `.mcf` corpus
- `/home/muhanpong/Downloads/blueMSXv282full/Tools/Cheats/msx/` — 753 `.mcf` files, 3.1M. (Other dirs present but out of scope: `coleco/`, `sega/`, `svi/`.)
- No `cheat_stats.tsv` found anywhere (task mentioned it). Only per-output `_manifest.tsv` files exist.

---

## 4. Verilator testbenches

All built with Verilator 5.048; all three **RUN and report `ALL PASS`** when executed now.

| Dir | TB / DUT | Tests | Status |
|---|---|---|---|
| `/tmp/cheat_test/` | `tb_cheat.sv` / `cheat_test.sv` | Original register-based F9 engine. Load 4-byte entry at ioctl_index=9; freeze override, 0xFF-over-0x00 (wired-AND bypass), non-cheat passthru, disabled-entry passthru, IO-read (mreq_n=1) no override, master-off passthru. | **ALL PASS** (7/7) |
| `/tmp/cheat_sa/` | `tb_sa.sv` / `cheat_sa.sv` | 4-way **set-associative** engine. Same-set placement, 5-in-one-set wrap (5th evicts way0 → passthru), other ways retained, master-off + IO-read gating. | **ALL PASS** |
| `/tmp/cheat_std/` | `tb_std.sv` / `cheat_std.sv` | **Standard `.gg` stream loader, ioctl_index=255, 16B/record** `{addr32,cmp32,replace32,flag32}` LE. Fuel DC78=0x80, C050=0x63, 1942 lives ED2F=0x09, non-cheat passthru, reload invalidation (new generation), empty download (2 bytes) clears. | **ALL PASS** |

- `tb_std` is the authoritative confirmation of the `.gg` layout: `gg()` task writes `addr(LE16),00,00 | 00,00,00,00 | val,00,00,00` and the engine pokes correctly → confirms **byte8 = value** convention used by both Python and HTML exporters.
- Build logs: `build.log` in each dir (build only; PASS/FAIL is from running `obj/sim`).

### Adjacent (NOT cheat tooling — flash byte-program, listed for completeness)
- `/tmp/flash_probe_test/` — ASCII16X JEDEC byte-program TBs: `tb_flash_probe.sv`, `tb_byteprog.sv`, `tb_ascii16x_prog.sv` with `flash_orig.sv`/`flash_fixed.sv`/`flash_syn.sv` variants + build logs. Verifies ascii16x self-contained byte-program (flash.sv not involved). Separate subsystem from cheats.

---

## 5. Board (ssh root@192.168.1.86)

- **`/media/fat/cheats/MSX1/`** — exactly ONE file:
  - `Twinbee (1986) (Konami) (J).zip` — 6,462 bytes, dated 1980 (matches mcf2mister timestamp convention). 36 `.gg` entries.
  - First entry `lives player 1.gg` = `70e00000 00000000 99000000 00000000` → addr=0xE070, compare=0, replace=0x99, flag=0. **Confirms addr-first `{addr,0,value,0}` layout on real deployed asset.**
- **`/media/fat/games/MSX1/`** — matching ROM `Twinbee (1986) (Konami) (J).rom`, 32,768 bytes (32KB), dated 2016. Base name matches the cheats zip.
- (`crc32` not available on board to print ROM CRC.)

---

## 6. Cross-check: twinbee consistency

- `msx/twinbee.mcf` (source) → 37 cheat lines (e.g. `0,57456,153,...lives player 1` → addr 0xE070, value 0x99=153).
- `msx_cht/twinbee.cht`: 37 records × 4 bytes = 148 bytes. First = `70 e0 99 01` = {addr_lo,addr_hi,value,flags=enable}. Matches `mcf2cht.py` spec.
- `msx_mister/twinbee.zip` (6,462 bytes) first entry `lives player 1.gg` = `70e00000 00000000 99000000 00000000` — **byte-identical to the zip deployed on the board** (§5). Matches `mcf2mister.py` and HTML `.gg` layout.
- Note: zip has 36 `.gg` entries vs 37 mcf lines — two lines share description-derived names and/or one collapsed; both Python and board zip agree at 36.

---

## Summary of byte formats (one-glance)

| Format | Producer(s) | Bytes/cheat | Layout |
|---|---|---|---|
| `.cht` (custom F9) | mcf2cht.py, HTML "Download .cht" | 4 LE | `addr_lo, addr_hi, value, flags(bit0=enable)` |
| `.gg` (standard, ioctl 255) | mcf2mister.py, HTML "Download .zip", board zip | 16 LE | `addr32, compare32=0, replace32=value, flag32=0` (addr-first; NOT NES `{flags,addr,cmp,repl}`) |
| `.mcf` (blueMSX, input) | source corpus | text line | `type,address,value,flag,description` (decimal) |

**Count correction:** task said "752 files"; actual on disk is **753** `.cht` and **753** `.zip` (+ one `_manifest.tsv` each), from **753** source `.mcf`.
