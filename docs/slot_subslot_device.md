# Expanded cart slots — the OSD "SLOT A/B sub-slot" device

Implemented 2026-08-25. Simulated with a working negative control, full sim suite
green, **not yet tested on hardware**.

Lets a plain ROM cart share its slot with a second device: subslot 0 keeps the
game, subslot 1 gets FM-PAC or GameMaster2. The point is that you no longer have
to spend both cart slots to play a ROM *and* have FM music.

```
OSD:  SLOT A            ROM
      ROM               <game>.rom
      Mapper type       auto
      SRAM size         auto
      SLOT A sub-slot   None | FM-PAC | GameMaster2      <- new
```

Default is `None`, which reproduces the previous behaviour exactly: a
non-expanded primary slot with only subslot 0 filled.

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

## Why only FM-PAC and GameMaster2

Not arbitrary — it is what provably cannot collide.

Mapper state is per-mapper-module, not per-subslot. If the subslot device used a
mapper the ROM in subslot 0 might also use, both subslots would share one set of
bank registers and corrupt each other. `MAPPER_FMPAC` and `MAPPER_GM2` are the
only cart mappers that are **unreachable** for a ROM cart, in both directions:

* not in the user's mapper menu — `CONF_STR_MAPPER_A/B` lists only
  `auto..WIZARDRY, Yamanooto` (`msx_config.sv:11,15`); both are marked
  `/*NEXT INTERNAL*/` in `package.sv:5`;
* not producible by auto-detect — `mapper_detect.sv:90-95` can only ever emit
  `MAPPER_UNUSED / NONE / KONAMI_SCC / KONAMI / ASCII8 / ASCII16`.

SCC+ was considered and rejected for exactly this reason: it is `MAPPER_KONAMI_SCC`,
which the user can pick *and* auto-detect can produce.

Two further constraints, both respected rather than worked around:

* **One ROM file per slot** (`ioctl_size[2]/[3]`, two DDR3 staging regions at
  `0xC00000` / `0x3000000`). FM-PAC and GameMaster2 take their ROMs from the
  **FW PACK** (`ROM_FMPAC` / `ROM_GM2` -> `STATE_FIND_ROM`, `ddr3_addr 0x2000000`),
  not from a user file, so no second file is needed.
* **`lookup_SRAM[4]`, 3 in use.** A ROM cart's SRAM takes index 0 (slot A only,
  deliberately — see the comment at `memory_upload.sv:252-259`); a non-`ROM_ROM`
  config takes index 1 (slot A) or 2 (slot B). The subslot device is not
  `ROM_ROM`, so it takes 1 or 2 — the same index "SLOT A = FM-PAC" already uses
  today. No new allocation, no aliasing.

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
* `rtl/msx_config.sv` — `CONF_STR_SUBSLOT_A/B`, status bits `[50:49]` / `[53:52]`
  (both were free; the map in `MSX1.sv:255-262` is updated), decode, and the
  `CART_TYP_ROM` guard. Added to `act_config` so changing it triggers `reload`
  (`lastConfig` widened 19 -> 23 bits).
* `rtl/peripheral/slots/memory_upload.sv` — `cart_confDecoder` gains a
  `subslot_dev` input and two table rows.
* `MSX1.sv` — the two menu entries. Slot A's shares the `H3` mask with
  "ROM,Load", slot B's shares `H4`, so each appears exactly when its slot is set
  to ROM. No new `status_menumask` bit was needed (only bit 7 was free).
* `sim/tb_subslot_dev.sv` + `sim/run_subslot_dev.sh` — 20 checks on
  `cart_confDecoder`: subslot 0 untouched, default stays non-expanded, the device
  lands in subslot 1 only (not 2/3), **MFRSD's own subslots are not overridden**,
  and no other cart type expands. `NEGCTL=1` forces `subslot_dev` to 0: exactly
  the 6 feature checks fail, the 14 regression checks still pass.

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
6. Set the menu back to `None` and confirm the slot is non-expanded again.

Untested combination worth checking early: a game whose own mapper is
KonamiSCC (auto-detected) together with a sub-slot device — the mappers differ,
so it should be fine, but it is the closest thing to a collision case.
