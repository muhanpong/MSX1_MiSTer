# MSX1 Cheats — Bulk Pipeline & Manual Loading Reference

> Consolidated reference for the **standard OSD `.gg` cheat track** on the MSX1
> MiSTer core. Covers (1) the bulk auto-generation pipeline that turns board
> ROMs into MiSTer-format `.gg` cheat zips, and (2) how to load a `.gg` zip by
> hand when auto-matching does not cover a ROM.
>
> Companion docs: `docs/cheat_overlay_design.md` (custom `.CHT` freeze/POKE
> engine, the *other* cheat track). The custom `.CHT` track and the standard
> `.gg` track are independent.

---

## TL;DR

- **Goal of the pipeline:** for every game ROM in `/media/fat/games/MSX1/`,
  emit a MiSTer-standard `.gg` cheat **zip** in `/media/fat/cheats/MSX1/`,
  named after the board ROM, with cheats sourced from blueMSX `.mcf` files.
- **Speed:** hash all board ROMs in **one** `sha1sum` ssh call (in place — never
  pull files; 8 MB homebrew/`.vhd` would dominate). Parse `msxromdb.xml` once
  (SHA1→title), build the `.mcf` basename set once. Whole library finishes in
  **< 20 s**.
- **The critical accuracy finding:** title→`.mcf`-id is **NOT algorithmic**.
  `.mcf` files use hand-authored short game-ids, not DB titles. Pure
  title-normalization matches only ~8 of ~36 cheatable ROMs and **silently
  drops ~20 games**. → You **must** maintain a curated **SHA1→mcf-id alias
  table** (seed with fuzzy match, human-confirm). Do **not** ship pure
  auto-matching.
- **Manual fallback:** there is **NO in-OSD cheat-file picker**. The core
  auto-loads exactly one zip (by name, then by `[CRC8]`) when the game loads via
  **Slot A "Load"**. To cheat an unmatched ROM, author a `.gg` zip in the
  webapp, name it `<rombase>.zip` or `<name> [CRC8].zip`, drop it in
  `cheats/MSX1/`, and load the game.
- **Engine limits:** 4-way set-associative BRAM, capacity ~2048 cheats, max 4
  per `addr[8:0]` set (extras evicted). Read-override semantics mean a cheat on
  a polled address can hang the game — toggle it off per-cheat.

---

# Part 1 — Bulk auto-generation pipeline

## 1.1 Goal

For each game ROM in `/media/fat/games/MSX1/`, produce a common-format `.gg`
cheat **zip** in `/media/fat/cheats/MSX1/`, named by the board ROM filename,
with cheats sourced from blueMSX `.mcf` cheat files.

## 1.2 Fast, single-pass algorithm

Do the expensive I/O once and make the per-ROM step pure dictionary lookups.

1. **Hash all board ROMs in ONE ssh call.** Run `sha1sum` *in place* on the
   board; never copy ROMs back to the host — an 8 MB homebrew megaROM or a
   `.vhd` would dominate transfer time. ~75 files hash in **~5–15 s**.
2. **Parse the blueMSX DB once.** `~/Downloads/blueMSXv282full/Databases/msxromdb.xml`
   with ElementTree into a dict keyed by **SHA1 → title**. Iterate
   `sw.iter('hash')` so you catch hashes inside `<rom>`, `<megarom>`, and the
   `sccpluscart` / `fmpac` container elements. Stats: **1184 titles**, **~2471
   unique SHA1s** (many titles have multiple dumps).
3. **Build the `.mcf` basename set once.** **752 files** under
   `Tools/Cheats/msx/`.
4. **Per-ROM = pure dict lookups.** SHA1 → title → (curated alias) → mcf-id →
   does a matching `.mcf` exist. Whole library completes in **< 20 s**.

## 1.3 Accuracy — the critical finding

### title→mcf-id is NOT algorithmic ★

blueMSX `.mcf` files are named by a **hand-authored short game-id**, not the DB
title. Pure title-normalization matches only **~8 of ~36** cheatable board ROMs;
the other **~28 SHA1-match the DB** but their `.mcf` lives under a different id.

Examples (DB title → actual `.mcf` id):

| DB title | `.mcf` id |
|---|---|
| Gradius - Nemesis | `gradius1` / `gradius1scc` |
| Salamander - Operation X | `salamander` |
| Parodius - Tako Saves Earth | `parodius` |
| Knightmare II - The Maze of Galious | `mazeofgalious` |
| Yumetairiku Adventure - Penguin Adventure | `penguinadventure` |
| F1 Spirit - The Way To Formula 1 | `f1spirit` |
| King's Valley 2 … | `kingsvalley2` |
| Majyo Densetsu - Knightmare | `knightmare` |

Subtitle-stripping (drop everything after `" - "`) fixes *some* of these but
**breaks others**. There is no rule that works for all.

**→ REQUIRED:** a curated **SHA1→mcf-id alias table**, seeded by fuzzy match but
**human-confirmed**. Do **NOT** ship pure-normalization auto-matching — it
silently drops ~20 games.

### Other accuracy rules

- **Multi-dump / region:** key the map by **SHA1** (this collapses the many
  SHA1s that share one title). Clean + `[a1]` dumps → same title → same `.mcf` →
  one zip per ROM filename (this is fine/expected).
- **Headered / odd-size ROMs** hash differently than the clean DB dump, so they
  **won't SHA1-match** — flag them. Note the asymmetry: MiSTer's *cheat-CRC*
  uses a header-skip of `size & 0x3FF`, but **SHA1 DB matching uses the whole
  file**. Real flagged cases: `Aleste2(K).rom` (739152 bytes),
  `aleste2 (1).rom` (753664 bytes).
- **MegaROM / 8 MB homebrew** is absent from the 2009-era DB (Neon Horizon ×4,
  Pampas ×6, MSXdev25, EGGY) → no SHA1 match. **Only the custom `.CHT` track can
  cheat these.**
- **`.zip` board files:** `SHA1(zip) ≠ SHA1(inner rom)` → they **never match**
  (Space Manbow hacks, Title Memory, Valis, `konami.zip`, …). Extract the inner
  ROM first if you want a match.
- **Exclude non-games:** `0_fmpac.rom`, `boot.rom`, `*_bios.rom`,
  `msxdiag.rom`, `SCC_DOS2.ROM`, `TESTRAM.ROM`, `*.dsk`, `*.MSX` (CART_FW),
  `*.vhd`, `*.cht`.

## 1.4 Triage checklist (needs user decision)

Carry these lists verbatim. Resolve each before generating zips.

### C1 — ambiguous variant (pick the right `.mcf`)
- [ ] Gradius (J) & `[a1]` → `gradius1` vs `gradius1scc`
- [ ] Gradius 2 (J) & `[a1]` → `gradius2` vs `gradius2beta`
- [ ] Zanac (J) → `zanac` vs `zanacex`
- [ ] Maze of Galious → confirm `mazeofgalious` (not `knightmare`)
- [ ] Metal Gear 2 → `metalgear2`
- [ ] Iga Ninpouten 2 → `iganinpouten2`

### C2 — confirm alias (else missed)
- [ ] Salamander → `salamander`
- [ ] Parodius → `parodius`
- [ ] Penguin Adventure → `penguinadventure`
- [ ] F1 Spirit (+ `[a1]`) → `f1spirit`
- [ ] Fairy Land Story → `fairylandstory`
- [ ] Fantasy Zone 2 → `fantasyzone2`
- [ ] Dragon Quest 1 / 2 → `dragonquest1` / `dragonquest2`
- [ ] King's Valley 2 → `kingsvalley2`
- [ ] Ninja Kun - Majyo no Bouken → `ninjakun`
- [ ] Majyo Densetsu → `knightmare`

### C3 — DB-matched but NO `.mcf` exists (confirm skip)
- [ ] Gall Force
- [ ] Gofer no Yabou Ep2 (Nemesis 3) ×2
- [ ] Title Memory `[SCC]` / `[KonamiSCCi]`
- [ ] `shin10x` (Game Master 2)
- [ ] Ninja-kun Ashura no Sho

### C4 — NO DB match: homebrew / hacks / translations (ask skip or supply manual)
- [ ] Hi no Tori variants
- [ ] Hype (patched)
- [ ] Space Manbow hacks ×3 + GoodMSX
- [ ] Pampas variants
- [ ] MetalGear_Kor
- [ ] Zarth_ko
- [ ] Aleste2 Korean / odd-size
- [ ] All homebrew megaROMs
- [ ] ZIPs needing inner-ROM extraction

### C5 — exclude (not games)
- [ ] See the exclude list in §1.3.

### CLEAN auto-matches — safe now (8)
These already match via plain normalization and need no alias entry:

| ROM | `.mcf` |
|---|---|
| Cross Blaim | `crossblaim` |
| Fantasy Zone 1 | `fantasyzone1` |
| Ninja Jajamaru Kun | `ninjajajamarukun` |
| Ninja Princess | `ninjaprincess` |
| Q-bert | `qbert` |
| Thexder | `thexder` |
| Twinbee | `twinbee` |
| King's Knight | `kingsknight` |

## 1.5 Engine limits to keep in mind

- **4-way set-associative BRAM**, capacity **2048** cheats, **4 per
  `addr[8:0]` set** (extras are evicted). A `.mcf` with > 2048 cheats, or with
  > 4 cheats colliding in the same set, will lose some entries.
- **Read-override semantics:** cheats applied to a polled address can hang the
  game. This is per-cheat; the user toggles the offender off in the OSD.

---

# Part 2 — Manual `.gg` loading

Use this when auto-match (Part 1) doesn't cover a ROM. All behavior below is
verified against the HPS source tree `/run/media/.../Main_MiSTer/`, cited
`file:line`.

## 2.1 When the core looks for cheats

- Auto-load fires on **Slot A "Load"** (`store_name=0`): `cheats_init`
  (`menu.cpp:2688`) runs — but **only if** the core's config string contains
  `C,Cheats;` (`use_cheats`, `user_io.cpp:905-908`).
- Cheat directory is `cheats/MSX1/` (`cheats.cpp:155`, `CoreName2 = MSX1`).

## 2.2 Match order — `findGameAsset` (`file_io.cpp:2240`)

1. The ROM's **own folder**: `<rombase>.zip` (`file_io.cpp:2244-2254`).
2. `cheats/MSX1/<rombase>.zip` — **name** match (`file_io.cpp:2272-2281`).
3. **CRC fallback** via `findAssetByCrc` (`file_io.cpp:2283` → `:2142`).

### CRC fallback rule
- The zip filename must end exactly with `[8HEXDIGITS].zip`:
  - the opening bracket `[` sits at `len-14`,
  - the closing `]` sits at `len-5`,
  - the value is **zero-padded to 8** hex digits, matched
    **case-insensitively** (`%8X`).
- MiSTer's CRC is computed with a **header skip**:
  `skip = len & 0x3FF; crc = zlib.crc32(data[skip:])`
  (`user_io.cpp:2806`, `:2862`, `:2888`; printed at `:2898`).

## 2.3 There is NO in-OSD cheat-file picker (definitive)

The `C,Cheats;` OSD menu only **lists/toggles** the cheats from the single
auto-matched zip — it cannot browse or select a cheat file
(`menu.cpp:2072`, `:2458-2463`; `cheats.cpp:296`, `:324`). If nothing matches,
the menu shows **"no cheat file found"** (`cheats.cpp:170`) and the entry is
greyed out.

→ Consequence: getting the **filename** right (name match or `[CRC8]`) is the
*only* way to load a specific cheat file.

## 2.4 The `.gg` poke record format

Each cheat is a **16-byte little-endian** record:

```
[flags=0][addr][compare=0][replace=value]
```

Example — address `0xDC78`, value `0x80`:

```
00 00 00 00 78 dc 00 00 00 00 00 00 80 00 00 00
```

The `.gg` **filename** (minus the `.gg` extension) becomes the **OSD label** for
that cheat.

## 2.5 Authoring with the webapp

`tools/msx1_cheat_editor.html`:

1. Add cheat rows manually, **or** Load a `.mcf` / `.zip` to import.
2. Click **"Download .zip (MiSTer standard)"**.
3. Place the result at either:
   - `cheats/MSX1/<rombase>.zip` (name match), or
   - `cheats/MSX1/<name> [CRC8].zip` (CRC fallback).

## 2.6 Recipe — cheat a ROM that isn't in the DB

1. Author the cheats in the webapp.
2. Name the zip by the **ROM base** (`<rombase>.zip`) or by `[CRC8]`.
3. Drop it in `cheats/MSX1/`.
4. Load the game via **Slot A "Load"** — the core auto-matches and the OSD
   `C,Cheats;` menu lists the cheats.

---

## Appendix — source citation index

| Behavior | File:line |
|---|---|
| `cheats_init` on Slot A load | `menu.cpp:2688` |
| `use_cheats` requires `C,Cheats;` | `user_io.cpp:905-908` |
| Cheat dir `cheats/MSX1/` | `cheats.cpp:155` |
| `findGameAsset` entry | `file_io.cpp:2240` |
| ROM-own-folder `<rombase>.zip` | `file_io.cpp:2244-2254` |
| Name match in `cheats/MSX1/` | `file_io.cpp:2272-2281` |
| CRC fallback dispatch | `file_io.cpp:2283`, `:2142` |
| CRC compute (header skip) | `user_io.cpp:2806`, `:2862`, `:2888`, `:2898` |
| OSD list/toggle only (no picker) | `menu.cpp:2072`, `:2458-2463`; `cheats.cpp:296`, `:324` |
| "no cheat file found" | `cheats.cpp:170` |
