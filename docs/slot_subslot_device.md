# Expanded cart slots — the OSD "SLOT A/B sub-slot" device

Implemented 2026-08-25. Simulated with a working negative control, full sim suite
green, **not yet tested on hardware**.

Lets a plain ROM cart share its slot with a second device: subslot 0 keeps the
game, subslot 1 gets FM-PAC or GameMaster2. The point is that you no longer have
to spend both cart slots to play a ROM *and* have FM music.

```
OSD:  ...
      Reset on ROM change   Yes
      Slot expansion        No | Yes            <- new master toggle, default No
      ...
      SLOT A                ROM
      ROM                   <game>.rom
      Mapper type           auto
      SRAM size             auto
      SLOT A sub-slot       None | FM-PAC | GameMaster2   <- only when the toggle is Yes
```

**`Slot expansion` is a master switch, and its default `No` is the menu the core
has always had.** With it off the two `sub-slot` entries are hidden *and* forced to
`None` in RTL, so the cart slots are non-expanded exactly as before — a user who
never touches it cannot reach any of the new behaviour. Turning it on reveals the
per-slot sub-slot menus, and each of those additionally appears only when its slot
is set to `ROM` (it shares that condition with the slot's `ROM,Load` entry).

Hiding and forcing are deliberately separate: hiding alone would leave a stale
status word from an older build still selecting a device.

---

## Why this was small, contrary to the earlier estimate

`docs/handoff/20260823_scc_next_session.md:35` parked this as "조사만 함" and it
was later restated as a multi-day project. That estimate was wrong, and the reason
is worth recording: **expanded cart slots were never missing.** The whole path was
already built, shipping, and hardware-proven — by MFRSD, which fills all four
subslots of one cart slot (`memory_upload.sv:698-701`):

```
CART_TYP_MFRSD & subslot == 0 -> DEVICE_MFRSD0, ROM_MFRSD,  DEV_FLASH
CART_TYP_MFRSD & subslot == 1 -> MAPPER_MFRSD1,             DEV_SCC2 | DEV_FLASH
CART_TYP_MFRSD & subslot == 2 -> MAPPER_MFRSD2, ROM_RAM 32, DEV_MFRSD2 | DEV_PSG
CART_TYP_MFRSD & subslot == 3 -> MAPPER_MFRSD3,             DEV_FLASH
```

Everything downstream already handles it:

| mechanism | where | note |
|---|---|---|
| subslot 0..3 iteration | `memory_upload.sv:609-613`, `:311-315` | the config FSM already walks all four |
| expander auto-enable | `memory_upload.sv:306-308` | `subslot != 0` sets `cart_slot_expander_en` by itself |
| per-subslot layout | `memory_upload.sv:268` `slotSubslot = {slot, subslot}` -> `slot_layout[{slotSubslot,page}]` | 64 entries = 4 primary x 4 subslot x 4 page |
| per-subslot mapper | `msx_slots.sv:147` `mapper = slot_layout[layout_id].mapper` | selected per addressed entry, so two subslots hold different mappers cleanly |
| device accumulation | `memory_upload.sv:537` `cart_device[slot] <= cart_device[slot] \| conf_device` | OR-ed across subslots |
| OPLL instance per cart slot | `msx_slots.sv:547` `cart_device[1]`, `cart_device[0]` | FM-PAC in a subslot gets its own OPLL |

So the entire change is **two rows in a decode table plus a menu entry.** No FSM
change, no new state, no resource growth beyond the two table rows.

## What can go in a sub-slot — three different kinds of limit

**On real MSX, a subslot can hold anything.** The subslot expander is transparent:
each 16KB page independently selects its own (primary, subslot), so two devices in
*different* subslots are never visible in the same page at the same time and their
memory windows cannot collide. Any list of "what is allowed" is therefore not an
MSX rule — with one exception below. Keep the three kinds of limit apart:

### 1. Real MSX architecture — the only true ❌ is MFRSD

| | |
|---|---|
| **MegaFlashROM SCC+ SD** | ❌ **never put it in a subslot.** MSX has no nested expansion — there is no sub-sub-slot. MFRSD *is* an expanded cartridge; it already owns subslots 0-3 of whatever primary it sits in (`memory_upload.sv:698-701`). This is the one item on the old list that was genuinely architectural. |
| `0xFFFF` | Expanding a slot changes that slot's `0xFFFF`: `msx_slots.sv:123` `mapper_en = (cpu_addr == 16'hFFFF & slot_expander_en[active_slot] & ...)`. It only bites when the expanded primary is the one selected for **page 3**, which for a cart slot is unusual — but it is why "does the game still run?" is a real hardware-test item and not a formality. |
| everything else | no architectural objection at all |

**Guarding MFRSD is structural, not a menu rule.** The sub-slot rows in
`cart_confDecoder` require `typ == CART_TYP_ROM`, and MFRSD's own rows own
subslots 1-3, so a sub-slot device can never displace them. `msx_config` also
forces `selected_subslot_dev` to 0 for any non-ROM slot type, so selecting MFRSD
switches the feature off rather than layering on top of it. `tb_subslot_dev`
asserts all three MFRSD subslots survive with a sub-slot device requested.

### 2. I/O ports — the real conflict class, and it is slot-agnostic

I/O decoding is not slot-scoped, on real hardware or here. Two devices answering
the same port collide no matter which slot or subslot they are in. That is not
something the sub-slot menu can fix, and we reproduce it faithfully:

* **OPLL `0x7C`/`0x7D`.** `msx_slots.sv:550` drives three IKAOPLL instances whose
  outputs are summed under `cs` (`opll_ika.sv:15-17`): internal MSX-Music, cart
  slot A, cart slot B. On a machine with built-in MSX-Music — **HB-F1XV has one** —
  adding an FM-PAC gives you two OPLLs, and once software enables the cart's ports
  a single write to `0x7C` reaches both and they sound together, at double level.
  That is real FM-PAC behaviour, not a bug. It is gated the real way: the cart's
  OPLL I/O only answers when the FM-PAC's own enable bit at `0x7FF6` is set
  (`fm_pac.sv:103`, `14'h3FF6` -> `opll_io_enable`), so it is off until a program
  asks for it.
* Same class: cart PSG `0x10-0x17` (`msx_slots.sv:603`), memory mapper `0xFC-0xFF`.

### 3. Our implementation — why the menu is short, and how to lengthen it

None of these are MSX rules. They are ours, and each is fixable.

| limit | on real hardware | what it would take |
|---|---|---|
| **Mapper state is per cart *slot*, not per subslot** — `konami_scc.sv:21` `bank[2][4]`, `sccMode[2]`, indexed by `cart_num`. Two subslots of one slot share `cart_num`, so two devices with the same mapper would share bank registers. | a non-issue: every real cartridge carries its own registers | index `[cart_num][subslot]`. **Costed below — essentially free.** |
| **One ROM file per cart slot** — `ioctl_size[2]/[3]`, two DDR3 staging regions (`0xC00000` / `0x3000000`) | host-side only, nothing to do with MSX | no silicon cost; ioctl indices + staging regions + one `F` entry per subslot in CONF_STR |
| **`cart_gamemaster2` has one global bank set** — `gamemaster2.sv:15`, no `cart_num` port at all, unlike `konami_scc`/`ascii8`/`ascii16x` (which index `[cart_num]`) or `fm_pac` (which instantiates twice, `:44,58`) | per-cartridge | the whole module is **11 ALUT / 18 reg**; ~10 lines + a bench |
| **`fdc_enabled` looks at the slot type only** — `msx_config.sv:103` — so an FDC in a subslot would never raise it and the drive-mount menu would not appear | — | a few lines |

### Costed against the real fit

Baseline (`output_files/MSX1.fit.summary`, 2026-08-26): **ALM 29,406 / 41,910 (70%)**,
**38,073 registers**, **M10K 351 / 553 (63%)**, block memory 41%.
Per-entity figures from `MSX1.map.rpt`'s *Resource Utilization by Entity*.
Cyclone V packs 2 ALUTs per ALM, so ALM ≈ ALUT / 2.

Mapper modules are tiny — they are just bank registers:

| module | ALUT | reg |
|---|---|---|
| `cart_konami_scc` | 45 | 76 |
| `cart_ascii8` | 113 | 144 |
| `cart_ascii16` | 66 | 36 |
| `cart_ascii16x` | 51 | 53 |
| `cart_fm_pac` (both inner instances) | 44 | 44 |
| `cart_gamemaster2` | 11 | 18 |

The sound chips are where the silicon actually is:

| chip | ALUT | reg | memory bits |
|---|---|---|---|
| `IKASCC_player_s` (one SCC) | **519** | 387 | 1,280 |
| `IKAOPLL` (one OPLL) | **~895** | ~905 | 749 (3 M10K) |

**A — mapper state per subslot (`[cart_num]` → `[cart_num][subslot]`).**
Four copies of the table above instead of two: **≈ +1,200 registers (+3.1%)** and,
allowing for the deeper read mux, **≈ +300-500 ALUT ≈ +150-250 ALM (+0.5-0.9%)**.
No memory blocks. **This is the one that matters and it is essentially free** — it
is what unblocks SCC, SCC+, Konami and the ASCII family as sub-slot devices.

**B — a second SCC *sound chip* per cart slot** (only needed if two SCC-family
devices in the *same* slot must sound at once): +2 `IKASCC_player_s` =
**+1,038 ALUT (~520 ALM, +1.8%), +774 reg, +2,560 memory bits**. Going fully
per-subslot (8 total, +6) = **+3,114 ALUT (~1,560 ALM, +5.3%), +2,322 reg**.
Affordable, but rarely needed — banking and sound are separate problems, and A
alone already lets a game and an SCC+ cart share a slot as long as only one of
them is actually making sound.

**C — a second OPLL per cart slot**: +1 IKAOPLL = **~+450 ALM (+1.5%), +905 reg,
+3 M10K**. Fully per-subslot (+6) = **~+2,685 ALM (+9.1%), +5,430 reg, +18 M10K
(351 → 369)**. This is the expensive one *and* the least useful: OPLL is addressed
through I/O ports `0x7C`/`0x7D`, which are not slot-scoped at all (see §2), so
more than one cart OPLL per slot buys nothing an MSX program can distinguish.

**The binding constraint is not the ALM count.** 12,504 ALMs are free — even C in
full fits. What this project has actually been bitten by is *fit congestion*: a
large combinational cloud in the PCM engine broke `SDRAM_DQ` IOB packing and made
2MB RAM flaky at ~95% BRAM (see `project_pcm_noise_rootcause` and
`docs/pcm_engine_optimization_study.md`), and the ASCII16X "ch1 sustained read
hang" turned out to be fit-dependent too. So the honest ordering is: **do A**
(free, unblocks the useful cases), **do B only if a concrete title needs it**, and
**treat C as not worth the placement risk**.

**So SCC and SCC+ are excluded by us, not by MSX.** `MAPPER_KONAMI_SCC` is both
pickable from the mapper menu and producible by `mapper_detect` (`:92`), so a ROM
in subslot 0 can already be using it and the two would share `bank[2][4]`. Lift
the first row of that table and "a game plus a real SCC+ sound cartridge in one
slot" opens up — which is exactly the configuration the SCMD investigation needed
(SCC-I and its RAM in the *same* subslot, see
`docs/mfrsd_scc_sound_cartridge_20260823.md`).

### What the menu offers today, and why those two are safe now

`FM-PAC` (slots A and B) and `GameMaster2` (slot A only). Both are safe under the
*current* per-slot mapper state because `MAPPER_FMPAC` and `MAPPER_GM2` are the
only cart mappers a ROM cart cannot reach in either direction:

* not in the mapper menu — `CONF_STR_MAPPER_A/B` lists `auto..WIZARDRY, Yamanooto`
  only; both are marked `/*NEXT INTERNAL*/` in `package.sv:5`;
* not producible by auto-detect — `mapper_detect.sv:90-95` emits only
  `MAPPER_UNUSED / NONE / KONAMI_SCC / KONAMI / ASCII8 / ASCII16`.

Their ROMs come from the **FW PACK** (`ROM_FMPAC` / `ROM_GM2` -> `STATE_FIND_ROM`
at `0x2000000`), so the one-ROM-file-per-slot limit does not apply either. And
`lookup_SRAM`: a ROM cart's SRAM takes index 0 (slot A only, deliberately —
`memory_upload.sv:252-259`), a non-`ROM_ROM` config takes 1 (slot A) or 2 (slot B),
which is the same index "SLOT A = FM-PAC" already uses today. No new allocation.

GameMaster2 is slot A only because of the third row above: it was reachable from
the SLOT A menu alone, so at most one could exist. The first version of this
feature offered it on slot B's sub-slot too, which made "SLOT A = GameMaster2" +
"SLOT B sub-slot = GameMaster2" reachable and the two would have shared
`bank1/2/3`. Caught before hardware; the option was removed and `msx_config`
clamps slot B so a status word from an older build cannot resurrect it.

## Known limitation — needs a ROM actually loaded

**If no ROM file is loaded in that slot, the sub-slot device does not appear.**

`memory_upload.sv:288-292`: the `ROM_ROM` branch aborts to `STATE_READ_CONF` when
`ioctl_size[..] == 0`, and that abort happens *before* the subslot advance at
`:609-613`. So the FSM never reaches subslot 1.

This was left as-is deliberately. Making the empty-slot case fall through to the
next subslot means editing a shared abort path that every cart type takes, for a
configuration ("expanded slot whose only occupant is the sub-slot device") that
has no use — the same device can just be selected as the main slot type instead.
Worth knowing when testing: **select the sub-slot device with a game loaded.**

## What landed

* `rtl/package.sv` — `config_cart_t.selected_subslot_dev` (2 bits).
* `rtl/msx_config.sv` — `CONF_STR_SLOT_EXPANSION` (master toggle, status `[60]`),
  `CONF_STR_SUBSLOT_A/B`, status bits `[50:49]` / `[53:52]`
  (both were free; the map in `MSX1.sv:255-262` is updated), decode, and the
  `CART_TYP_ROM` guard. Added to `act_config` so changing it triggers `reload`
  (`lastConfig` widened 19 -> 23 bits).
* `rtl/peripheral/slots/memory_upload.sv` — `cart_confDecoder` gains a
  `subslot_dev` input and two table rows.
* `MSX1.sv` — the toggle placed directly under "Reset on ROM change", plus the two
  sub-slot entries. `status_menumask` widened `[7:0]` -> `[9:0]` (hps_io's port is
  already 16 bits, `hps_io.sv:117`) for the new bits 7/8:
  `subslot_A_hide = ~slot_expansion_en | ROM_A_load_hide`, and the same for B.
* `sim/tb_subslot_dev.sv` + `sim/run_subslot_dev.sh` — two DUTs. 21 checks on
  `cart_confDecoder`: subslot 0 untouched, default stays non-expanded, the device
  lands in subslot 1 only (not 2/3), **MFRSD's own subslots are not overridden**,
  and no other cart type expands. `NEGCTL=1` forces `subslot_dev` to 0: exactly
  the 6 feature checks fail, the rest still pass.
  Plus 10 checks on `msx_config`, which is where the menu-side guards live:
  `Slot expansion=No` forces both sub-slots to `None` **and** hides both menus,
  `Yes` reveals them, a non-ROM slot type suppresses and hides its own, and slot B
  clamps GameMaster2 away. All four guards are mutation-proven — removing the
  master-toggle term, the hide term, or the slot B clamp each makes exactly one
  check fail.

Full `sim/run_*.sh` suite re-run: 19/19 green.

## Hardware test

1. FW PACK loaded (FM-PAC / GameMaster2 ROMs come from it).
2. SLOT A = ROM, load a game, `SLOT A sub-slot` = FM-PAC.
3. The machine should now see an **expanded** slot: subslot 0 = the game,
   subslot 1 = FM-PAC at `0x4000-0x7FFF`. Anything that scans subslots for OPLL
   (e.g. the `"APRLOPLL"` sweep in `docs/TODO_scmd_silent_exit.md`) should find it.
4. Confirm the game still runs — that is the real regression risk, since its slot
   is now expanded and `0xFFFF` becomes a subslot register in it.
5. Repeat with GameMaster2, and on slot B.
6. Set the menu back to `None`, and separately set `Slot expansion` to `No`, and
   confirm the slot is non-expanded again in both cases.

Untested combination worth checking early: a game whose own mapper is
KonamiSCC (auto-detected) together with a sub-slot device — the mappers differ,
so it should be fine, but it is the closest thing to a collision case.
