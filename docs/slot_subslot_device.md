# Expanded cart slots — the OSD "SLOT A/B sub-slot" device

Implemented 2026-08-25/26. Simulated with a working negative control, full sim
suite green.

**Hardware status is split — read this before trusting it:**

| | |
|---|---|
| verified 2026-08-26 | The feature is **inert when off**: `MSX1_20260826b_opllpace` (tree `3567edf`) boots and runs existing games unchanged, and the OSD renders `SLOT A sub-slots`. That is a regression check for the classic path, nothing more. |
| **NOT verified** | **Nothing has ever run with a slot actually expanded.** No sub-slot device has been placed on hardware — not FM-PAC, not SCC+, not a ROM in sub-slot 2. The whole point of the feature is untested. |
| partly exercised | `MSX1_20260826c_subslotmenu.rbf` (2026-08-26 20:01, tree `9108e17`/RTL `a646083`). SCC+ in **Sub-slot 0 of both slots**: detected and sounding. That validates the new decode table and the menu — but with only subslot 0 filled the old code never set `cart_slot_expander_en`, so the slot was **not actually expanded**. |
| **awaiting test** | `MSX1_20260826d_ch2loop.rbf` (2026-08-26 21:56, md5 `d10424f5…`, built by the turbo session from tree `21d24df` + its P3 work; timing clean, worst +0.578, `clk_sdram` setup +1.013). First build carrying `a10a874` (**"On" now expands the primary even with only Sub-slot 0** — so the same OSD settings behave differently from 26c), `565ac47` (**D5**, chip mode split from the window — SCC/SCC+ may *sound* different, deliberately) and `21d24df`. **A device in a NON-ZERO subslot has still never run.** |


Each cart slot can be switched, independently, into an **expanded slot** whose
four subslots each carry a device the user picks. The classic one-device line for
that slot disappears and a sub-menu page takes its place.

```
OSD (slot A shown; slot B is identical minus GameMaster2)

  SLOT A                ROM | SCC | SCC+ | FM-PAC | MFRSD | GameMaster2 | FDC | Empty
  SLOT A sub-slots      Off | On                         <- per-slot switch, default Off
  ROM                   Load ...                          (classic: while SLOT A = ROM)
  Mapper type           auto ...
  SRAM size             auto ...

  -- "SLOT A sub-slots: On": the four classic lines above are replaced by a page --

  SLOT A sub-slots  ▸                                     <- menu page (P3)
      Sub-slot 0        None | ROM | SCC | SCC+ | FM-PAC | GameMaster2
      Sub-slot 1        None | ROM | SCC | SCC+ | FM-PAC | GameMaster2
      Sub-slot 2        None | ROM | SCC | SCC+ | FM-PAC | GameMaster2
      Sub-slot 3        None | ROM | SCC | SCC+ | FM-PAC | GameMaster2
      ─────
      ROM               Load ...        (while a sub-slot is ROM or SCC)
      Mapper type       auto ...        (while a sub-slot is ROM -- SCC forces KonamiSCC)
      SRAM size         auto ...        (same)
```

The ROM's own three entries exist twice on the same status bits — at slot level for
the classic menu (hidden while expanded, `H7`/`H8`) and inside the page (only
reachable while expanded). Masks: `H3`/`H4` = "a ROM file is in use" (ROM or SCC),
`HB`/`HC` = "a ROM sub-slot is chosen" (Mapper / SRAM mean nothing for SCC). The
firmware parses `F`/`S` entries after a page prefix (`menu.cpp:2024`, `:2405`), so
`P3FS3` is legal; the load addresses are the same literals as the slot-level copy
and must keep matching `memory_upload.sv`'s staging (`0xC00000` / `0x3000000`).

Default `Off` reproduces the previous behaviour exactly: a non-expanded primary
slot, one device, chosen by the classic line. Slot B's list has no GameMaster2
(see *Mapper-module state* below). Status bits: `[71]`/`[72]` the switches,
`[84:73]` / `[96:85]` the eight 3-bit device fields.

Rules applied by `msx_config` before anything reaches the RTL — first occurrence
wins, later conflicting entries fall back to `None`:

* **ROM and SCC both load the slot's single ROM file** → at most one of them per
  slot. (SCC = "the loaded ROM with the KonamiSCC mapper forced".)
* **FM-PAC and GameMaster2 share `lookup_SRAM` index 1/2 of the slot**
  (`memory_upload.sv:266`) and FM-PAC has one instance per slot → at most one.
* **GameMaster2 is slot A only**; codes 6/7 are unused → `None`.
* **SCC+ may appear in several subslots** — `konami_scc` keeps its state per
  (slot, subslot) now. They share the slot's one SCC *sound* chip, though; see
  the limitation below.

### Limitation: two SCC-family devices in one cart slot

Allowed by the menu, degraded by construction — **one `IKASCC` per cart slot**
(`scc_sound.sv` instantiates A and B, one per slot, not per subslot). Two SCC
devices in the same slot therefore share the chip's wave RAM and its FREQ/VOL
registers: only one subslot is addressable per page at a time, but the chip
*state* is whatever the last writer left, so they overwrite each other rather
than coexisting.

`sccDevice` is per cart slot too (`msx_slots.sv:480`
`|(cart_device[cart_num] & DEV_SCC2)`, and `cart_device[]` is OR-accumulated
across subslots at `memory_upload.sv:537`). So an SCC+ anywhere in the slot makes
the whole slot's chip an SCC-I, and a plain SCC sharing that slot is driven as
SCC-I: software probing it sees SCC-I, and with the mode register set to Plus its
ch5 plays its own (stale) RAM instead of mirroring ch4 — audibly not a real SCC.

It still *plays*: the plain-SCC window survives because `scc_req`'s second term
(`~sccMode[5] & bank[2][5:0] == 0x3F` at `0x9800`) does not look at `sccDevice`;
only the third term does. So this is a fidelity gap in an already-degraded
configuration, not a failure.

**Not blocked on purpose** (2026-08-26): the real constraint is one chip per slot,
which no menu rule can fix, and forbidding the combination would only remove a
configuration a user might still want. **To do later:** either give `sccDevice`
per-subslot scope (half a fix while the chip stays shared), or refuse SCC next to
SCC+ in `msx_config`'s conflict rules (cheap, honest). Option B in
*Costed against the real fit* — a second `IKASCC` per slot, +520 ALM — is what
would actually make the combination work.
* While a slot is `Off`, all four of its fields are forced to `None`, not just
  hidden — a status word carried over from an older build cannot select anything.

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

## "슬롯 1" 과 "슬롯 1-0" 은 다른 주소다

MSX에서 확장 슬롯의 서브슬롯 0은 비확장 primary 와 **같은 곳이 아니다**. 확장이면
BIOS 가 `EXPTBL` bit7 을 세우고, `0xFFFF` 가 서브슬롯 레지스터가 되며,
`RDSLT`/`WRSLT`/`CALSLT` 에 넘기는 슬롯 바이트도 달라진다. 서브슬롯을 훑는
소프트웨어(예: SCMD 의 `APRLOPLL` 순회)가 장치를 찾는 자리도 달라진다.

첫 구현은 `memory_upload.sv` 가 **`subslot != 0` 인 설정 줄이 나올 때만** 확장을
켰다. 그래서 "sub-slots: On + Sub-slot 0 만 사용" 이면 확장 플래그가 서지 않고
장치가 **1-0 이 아니라 1** 에 놓였다 — 사용자가 확장을 켠 의사를 무시한 것이다.
2026-08-26 실기 세션에서 사용자가 지적해 고쳤다: 이제 `cart_conf[].expanded` 를
같이 본다. 서브슬롯이 전부 None 이어도 확장 슬롯은 확장으로 남는다.

MFRSD 는 `expanded` 를 쓰지 않고 예전처럼 `subslot != 0` 로 켜지므로 영향 없다.

**실기 확인법** (BASIC):
```
FOR I=0 TO 3:PRINT I,HEX$(PEEK(&HFCC1+I)):NEXT
```
`EXPTBL` 이고 bit7(`&H80`)이 서 있으면 그 primary 는 확장 슬롯이다.
카트 슬롯을 `sub-slots: On` 으로 두면 해당 항목이 `8x` 로 보여야 한다.

## OSD trap: "the page items all showed up at the root"

Not a CONF_STR bug. The firmware has a **flat menu mode** that expands every page
inline at the root, toggled by the **`` ` `` (backtick / KEY_GRAVE) key** while the
OSD is open — `menu.cpp:1426` sets `recent`, `:2618` does `flat = !flat`, and
`:1976` `if (!page && n && !flat) inpage = 0;` is what stops hiding page items once
it is on. Press `` ` `` again to restore the pages.

Telling them apart: in flat mode the core's **own** pages (`P1` Video settings,
`P2` Audio settings) are flattened too. If those are still pages and only `P3`/`P4`
are loose, that *would* be ours. Observed 2026-08-26 during the first hardware
session with this menu — **the user confirmed Video/Audio settings were flattened
as well**, so it was flat mode and the CONF_STR was never at fault.

What flat mode *did* expose, and what was fixed: only the page **titles** carried
`H9`/`HA`. Flat mode bypasses the page rule that hides items at root
(`menu.cpp:1976`), so the `Sub-slot 0..3` entries appeared at depth 0 even for a
slot that is not expanded, and the page's ROM / Mapper / SRAM copies showed up
next to their slot-level twins. Every `P3`/`P4` entry now carries its page mask in
addition to its own condition (masks OR together in the firmware's parse loop).

Worth knowing because a flattened menu also mixes `OPL4 PCM Volume`,
`OPL4 FM Volume` and `SCC Volume` into one screen, which is an easy way to think
an audio trim is broken when the wrong item was moved.

For the record, mask-before-page (`H9P3,…`) is fine — `P1` already ships that shape
(`h2P1O[14:13]`, `H2P1O[12]`).

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

### Yamanooto specifically

Worth its own note, because two things about it invite wrong inferences.

**`SUBOFF` is not "subslot off".** It is *SUB-OFFset* — CFGR bit5:4, the low two
bits of the segment offset that give 8KB granularity:
`offset = OFFR*4 + SUBOFF` (`yamanooto.sv:72,90`; `docs/yamanooto_spec.md:53`,
which already warns that a merged 2-bit cell in the vendor PDF makes this table
easy to misread). It has nothing to do with slot expansion.

**Its state is properly per cart slot** — `enableReg[2]`, `offsetReg[2]`,
`configReg[2]`, `sccModeReg[2]`, `bankReg[2][4]`, `rawBank[2][4]`, 14 `cart_num`
references (`yamanooto.sv:75-85`). Same family as `konami_scc`/`ascii8`/`ascii16x`,
so option A applies to it unchanged: **125 ALUT / 154 reg** today, `154 -> 616`
registers if indexed per subslot.

**Yamanooto in subslot 0 already coexists with a sub-slot device — today.** It is a
*mapper* for the slot's loaded ROM, not a cart type, so `SLOT A = ROM` +
`Mapper type = Yamanooto` + `SLOT A sub-slot = FM-PAC` works on the current build:
`MAPPER_YAMANOOTO` and `MAPPER_FMPAC` are different modules with separate state,
the ROM file count is still one, and the sound chips do not contend (Yamanooto
drives the cart slot's IKASCC via its own `sccReq`, FM-PAC drives that slot's
IKAOPLL). Its registers live at `0x7FFC-0x7FFF` — page 1, so they never meet the
expanded slot's `0xFFFF`, which is page 3. `tb_subslot_dev` covers this case.

**Yamanooto as the sub-slot *device* is a different matter** — three blockers, in
descending order of difficulty:

1. **It needs the slot's ROM file.** Unlike FM-PAC and GameMaster2, its 8MB flash
   image comes from a user file, and `memory_upload.sv:287` even pads it out to
   `0x800000`. There is no FW PACK copy to point at, so this runs straight into
   the one-ROM-file-per-slot limit — the hardest of the four in §3.
2. **Mapper-collision class.** `MAPPER_YAMANOOTO` is selectable from the mapper
   menu (`msx_config.sv:39,42`), so subslot 0's ROM may already be Yamanooto.
   Needs option A.
3. **Device contention.** It carries `DEV_SCC2 | DEV_PSG | DEV_FLASH`
   (`memory_upload.sv:691`) and there is one IKASCC and one cart PSG per cart
   slot, so it would fight anything else in the slot wanting those — option B.

But note what is *not* on that list: **there is no architectural objection.**
Yamanooto is a flat primary-slot cartridge with no subslot expander of its own
(`memory_upload.sv:686-687`), so unlike MFRSD it is perfectly legal inside someone
else's subslot. Every blocker above is ours.

### Why only these five

Everything else is blocked by a limit of ours, not by MSX (see §3): a second
**ROM** needs a second ROM file per slot; **FDC** needs `fdc_enabled` to look at
subslots; **MFRSD** is architecturally impossible (§1); **Yamanooto** is a mapper
for the ROM, so it rides the `ROM` entry rather than being a device of its own.

## What landed

* `rtl/package.sv` — `subslot_dev_t` (None/ROM/SCC/SCC+/FM-PAC/GM2);
  `config_cart_t` gains `expanded` and `subslot_dev[4]`.
* `rtl/msx_config.sv` — `CONF_STR_EXPAND_A/B` (`O[71]`/`O[72]`), the two sub-menu
  pages `P3`/`P4` with four 3-bit fields each, the conflict rules above, and four
  hide signals: classic line hidden while expanded (`H7`/`H8`), page hidden while
  not (`H9`/`HA`), Mapper/SRAM hidden unless a ROM sub-slot is chosen (`HB`/`HC`)
  — mask bits 9..12; the firmware reads `'A'..'V'` as 10..31
  (`user_io.cpp user_io_status_bits`). The page carries its own ROM Load /
  Mapper / SRAM entries on the same status bits as the slot-level ones. `fdc_enabled` ignores the hidden classic
  type while slot A is expanded. `act_config` widened to 45 bits so any change
  triggers `reload`.
* `rtl/peripheral/slots/memory_upload.sv` — `cart_confDecoder` takes `expanded`
  and `sub_dev`; six rows at the top of the table, `expanded` takes precedence over
  the classic `typ` rows (a stale hidden type cannot leak). Three FSM fixes that
  the four-subslot walk needed:
  1. a `ROM` row with no file loaded used to abort the whole record — it now skips
     just that subslot and keeps walking (the earlier "known limitation" is gone);
  2. the auto-mapper re-latch after the fill was gated on `typ == ROM` — now on
     `cart_rom_id == ROM_ROM`, so a ROM in subslot 2 gets detected too;
  3. `mapper_detect` is reset per subslot (`STATE_CHECK_CONFIG`), not per record —
     an SCC+ RAM fill in an earlier subslot must not pollute the ROM's counters.
* `rtl/peripheral/slots/konami_scc.sv` — bank/mode/enable state indexed by
  `{cart_num, subslot}` (8 sets); `scc_mode` per cart slot = any subslot in SCC+
  mode. `subslot` auto-connects via `.*` from `msx_slots.sv:143`.
* `MSX1.sv` — menu placement (slot-level ROM entries gain `H7`/`H8`),
  `status_menumask` widened to `[12:0]`, bit map.
* `sim/tb_subslot_dev.sv` — decoder (classic rows untouched; every device in every
  subslot; stale `typ` ignored; Yamanooto via ROM) + `msx_config` (per-slot On/Off,
  all hides, every conflict rule, GM2 clamp on B, FDC non-leak). `NEGCTL=1` forces
  the decoder's `expanded` low: exactly the 36 expanded checks fail.
* `sim/tb_scc_subslot.sv` — two subslots of one slot write bank 1 and each reads
  back its own; other slot/subslots untouched; SCC+ mode aggregates per slot.
  `NEGCTL=1` ties `subslot` to 0: the two clobber checks fail.
* `sim/run_subslot_dev.sh` runs both. Regression: sccdetect, sccplus, yamanooto,
  mfrsd_sccmode/sccsound, keypad, a16x_cfi, flash_seam, yamanooto_flash all green.

Hardware: off-path verified only — see the table at the top.

## Hardware test — none of this has been done yet

1. FW PACK loaded (FM-PAC / GameMaster2 ROMs come from it).
2. `SLOT A sub-slots: On`, page: sub-slot 0 = ROM (load a game), sub-slot 1 = FM-PAC.
   The game must still run — its slot is now expanded and `0xFFFF` is a subslot
   register there. Software that sweeps subslots for OPLL should find the FM-PAC.
3. Move the ROM to sub-slot 2, leave 0/1 empty: still boots (exercises the
   "skip empty subslot, keep walking" fix and the per-subslot mapper detect).
4. ROM (KonamiSCC game) in sub-slot 0 + SCC+ in sub-slot 1: both bank sets must
   stay independent — the game must not lose its banks when SCMD-style software
   pokes the SCC+ cart. This is the `konami_scc` split on real silicon.
5. Repeat 2 on slot B; then both slots expanded at once.
6. `Off` on each slot: classic line returns, slot is non-expanded again.
