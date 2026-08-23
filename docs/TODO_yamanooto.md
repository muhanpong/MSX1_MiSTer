# TODO — Yamanooto mapper: what is still missing

Recorded 2026-08-21, after a four-lens audit against openMSX master, the 15oct2024
hardware reference, the official User Manual, the vendor's own firmware release
notes, and SMX Team's MSX-side Z80 sources (`~/Documents/github/msx_dma_sw/modules/yamanooto/`).

**Already fixed and shipped** (do not re-investigate): `reg_hit`→`reg_rd` at
`yamanooto.sv:183` (RC744 item pickup, hardware-verified in `20260821a_yamafix`),
per-cart stable SCC mode, ENAR readback masking, cart-PSG readback at port 12H.
See `project-yamanooto-scc` in memory for the full history.

---

## 1. Flash write path — DONE and HARDWARE-VERIFIED (2026-08-22)

Implemented as `cart_yamanooto`'s own JEDEC state machine, mirroring the proven
`ascii16x.sv` path.  Shipped as `20260822b_yamawrite`.

**Hardware verification (2026-08-22, board .86):**
- Final Fantasy (KR) save written, core reloaded, save read back correctly.
- Yamanooto ROM loads in slot B.
- MFRSD still boots — this is what clears the `flash.sv` erase-decode change
  below, whose only real risk was the boot-failure class that forced a revert once
  before.  An actual MFRSD *erase* is still untested (it only fires after a full
  AA/55/80/AA/55/30), but that failure mode is "wrong sector erased", not "no boot".

The save succeeding is itself the proof that the `MSX1.sv` menumask fix landed:
without it the `SRAM Save` button is hidden and there is no way to press it.

Test suites (all with working negative controls):
`run_yamanooto_flash` 23 · `run_flash_seam` 0 attacks · `run_erase_hijack` 0
hijacked · `run_flash_erase` 7.

What landed:
- `yamanooto.sv` gained `flash_addr` / `flash_rq` / `prog_we` and a JEDEC FSM
  (AA/55/A0 -> program, AA/55/80/AA/55/30 -> erase), gated on `WREN & ~ROMDIS`
  exactly like `Yamanooto.cc:235-240`.
- `msx_slots.sv`: Yamanooto terms in all four `flash` muxes; `prog_we` added to
  `sdram_ce` / `ram_rnw` (this is what gets the data byte past the region's
  read-only flag); `flash16x_*` extended so `flash_dirtysave` persists it.
- `flash.sv`: `is_ascii16x` split into `amd_family` and `boot_sector`.

**Five defects found by a three-lens review (advocate / neutral / critic) after the
first implementation, all reproduced independently before fixing, all shipped:**

| # | Defect | Why it mattered |
|---|---|---|
| F1 | `flash_rq` had no WREN term | An ordinary K5 bank write `LD (0x50AA),A` with A=0x98 walked the SHARED `flash.sv` FSM into CFI — the whole 8MB ROM window then read 0x00. `flash.sv` has no reset port (`reset` there is an internal wire meaning "an F0 arrived"), so a wedged cart does NOT recover on MSX reset. |
| F3 | erase fill could be hijacked | `write_cnt > 0` guards the program branch, but the erase loop borrows that same counter, so ONE CPU write during the 64KB fill retargeted `sdram_addr` and substituted its byte for 0xFF — measured 65528/65536 bytes wrong, running past the sector and bypassing the `erase_limit` clamp. Gating `flash_rq` on WREN does NOT cover it: a driver holds WREN set across the erase by construction. Fixed with `& ~erase`. |
| F4 | `flash_rq` had no `cpu_mreq` | `IN A,(0x12)` puts {A,port} on `cpu_addr`, so A=0x50 gives 0x5012 — inside `page_ok`, `cpu_rd` set, `cpu_mreq` clear. The flash dout then ANDs into the shared `cpu_din` tree. |
| F5 | `SRAM Save`/`Load` hidden | `MSX1.sv` menumask excepted only `MAPPER_ASCII16X`, so the whole feature was unreachable from the UI. |
| F2 | erase sector scale | Pre-existing MFRSD defect, see the correction below. |

New regression suites cover the `flash.sv` + `msx_slots.sv` seam, which nothing
tested before — and which is exactly where F1, F2 and F3 all hid.

**Three corrections to what this TODO originally said:**

1. **Item 3 was wrong — `flash.sv`'s dead 0xA0 branch does not need fixing.**
   ASCII16X never used it: the mapper detects the sequence itself and the data
   byte rides the ordinary SDRAM write path.  Yamanooto now does the same.  The
   shared command FSM was left untouched, which matters — widening it once before
   caused a boot failure that had to be reverted.
2. **Item 4 was a real defect, but NOT for the reason first recorded here.**
   The original text claimed Yamanooto's S29GL064 is "uniform 64KB". **That is
   false** — openMSX's chip table gives all three parts the SAME bottom-boot map,
   8 x 8KB then 127 x 64KB:

   | cart | chip | source |
   |---|---|---|
   | ASCII16X | S29GL064S70TFI040 | `RomAscii16X.cc:25` (AMD) |
   | Yamanooto | S29GL064N90TFI04 | `Yamanooto.cc:38` (AMD) |
   | MFRSD-SD | M29W640GB | `MegaFlashRomSCCPlusSD.cc:274` (STM) |

   They differ only in manufacturer id — which is the `amd_family` half. So
   `boot_sector` is **not** a per-cart discriminator and is driven `1'b1`. The real
   defect was that `erase_boot` (the `<<13` scaling) was gated on the ASCII16X path
   alone, leaving MFRSD with the correct 8KB index scaled as if it were 64KB: a
   confirm at flash 0x2000 erased 0x10000-0x1FFFF and left the target intact.
   A first fix built on the "uniform" premise was reverted once the chip table was
   actually read. `sim/run_flash_erase.sh` pins the geometry, its negative control
   re-injecting the historical ASCII16X-only gating.
3. **`#12` to `#7FFF` is not "REGEN+WREN".** 0x12 = WREN(bit4) | SPIEN(bit1);
   REGEN(bit0) is clear.  WREN alone opens the flash, which is why the Selica
   games work without ever setting REGEN.  (Their unlock pair `#4AAA`/`#4555` is
   the same 0x555/0x2AA word offset ASCII16X already used.)

**Still open on this path:**
- `flash_dirtysave` is wired to `flash16x_active[0]` only (`MSX1.sv:1009`), so
  **flash** persistence covers cart A only. A Yamanooto in slot B programs
  correctly but will not survive a power cycle. (Classic SRAM in slot B is a
  different path and now works — see below.)
- ~~Whether the HPS auto-mounts `<rom>.sav` for a Yamanooto ROM~~ — **VERIFIED
  2026-08-22**: Final Fantasy (KR) saved, survived a core reload. The mount is
  per-ROM, not per-mapper, as expected.
- Still latent: one `flash` instance with one command FSM (`flash.sv:22-23`)
  shared by every cart, so an MFRSD and a Yamanooto in the two slots would
  interleave into the same unlock sequence.

Hardware targets in `/media/fat/games/MSX1/00_Selica_KOR/`: `Final Fantasy (KR)`
**tested OK**; `Golvellius 2 (KR)` and `Jikuu no Hanayome (KR)` not yet tried.

## 2. Konami DAC in K4 mode — absent

Vendor release notes, yimmi8beta2, verbatim: *"added konami's Dac in K4 mode. Use
mapper-lock and K4 for Konami's synthesizer"*. We have no Konami DAC anywhere in
`rtl/`. **openMSX's Yamanooto class has none either**, so this gap is invisible to
an openMSX diff — it models the two Konami DAC cartridges separately
(`RomMajutsushi.cc:24-27`, `RomSynthesizer.cc:44`).

Effect: flash *Hai no Majutsushi* into a Yamanooto image, select K4, and its
digitised speech is completely silent; the Konami Synthesizer produces nothing.

**Blocked on a fact we do not have:** the decode window. openMSX's two variants
disagree (`0x5000-0x5FFF` vs `(address & 0xC010) == 0x4000`) and the note covers
both use cases. Needs the yimmi9 documentation or a hardware test.

## 3. 0x7FFE is three registers — corruption stopped (2026-08-23)

Per the vendor's sources (`yamacore/SRC/YAMASPI.Z8A:9-30`), 0x7FFE is `OFFR`, or
`MOFFR` when MSTEN (ENAR bit2), or `SPICON` when SPIEN (ENAR bit1). We implement
only OFFR, and the write was unqualified, so a MOFFR or SPICON write silently
destroyed it. **openMSX has the identical defect** (`Yamanooto.cc:223-225`).

Fixed by qualifying the write with `~|(enar & (MSTEN | SPIEN))` — this does NOT
add MOFFR/SPICON, it only stops the corruption. `sim/run_offr.sh` pins it,
including the real `YAMABOOT.Z8A:175` sequence (ENAR=%101 -> MOFFR -> clear MSTEN
-> OFFR=0); the negative control fails 2 as required.

**HARDWARE-VERIFIED 2026-08-23** on `20260823d_critfix`, with the purpose-built
`tools/yamanooto_savetest.rom`: border came up light green = all five tests pass,
including T5, which is the guard itself (`REGEN|SPIEN` set, write 0x7FFE, offset
must NOT change). This closes the one item that was shipping on reasoning alone --
no software we own reaches this path, which is exactly why the cart exists.
openMSX has no such guard, so the same cart is expected to fail T5 there.

Still not implemented: MOFFR and SPICON themselves. Neither `PACK_K.ROM` nor the
Neo-Ultimate Collection ever sets those bits, so nothing we run needs them.

## 4. RAM-mode deviation — soften the comment, change no code

`yamanooto.sv:101-102` closes the SCC window when the mode register selects RAM
mode; openMSX has no such test. Our header comment at `:25-28` presents this as
settled. It is not: openMSX issue **#1964 is still open**, the maintainers asked
for real-hardware verification and a test program, and **neither was ever
produced**; the designer never answered in-thread. bifi's page — the other cited
source — is unreachable (TLS failure / 404) and the sentence quoted from it is
internally inconsistent about which bit it means.

The sources agree on writes and conflict only on reads. Keeping our behaviour is
defensible (it models the Yamanooto FPGA at firmware >= yimmi9rc2, per artrag),
and our `konami_scc.sv:65` correctly models the *Konami* Sound Cartridge
differently — two different chips, so the divergence between our two mappers is
right, not an inconsistency.

**Cheapest possible closure, and it is a download rather than an experiment:** the
firmware set on this machine stops at yimmi8beta3, whose `release_notes.txt` lists
every behavioural change back to xp1 and contains **no RAM-mode entry** — exactly
consistent with the test being added later. Obtaining the **yimmi9rc2 release
notes** would settle #1964 from the vendor's own changelog.

## 5. PARKED — Slot B saving: built and deployed, NOT hardware-tested

Shipped in `20260823b_slotBsave2`. **No hardware test has been run** — the user
parked slot B work entirely on 2026-08-23, together with item 6. Treat slot B
saving as unproven: the reasoning below is sound and the firmware constraint is
read straight from `Main_MiSTer`, but nothing has been observed on the board.

Tests to run when this is picked up:
- Ohke no Tani in slot B with `SRAM SIZE` set manually (not AUTO) -> `SRAM SAVE`
  -> a new `.sav` should appear in `/media/fat/saves/MSX1/`.
- Final Fantasy (KR) in slot B -> continue should appear, and saving should work.
Both failed on `20260823a`, which is what led to the fixes below.

Slot B could not save anything. Two separate things were wrong, and the second one
invalidates an assumption this document previously recorded.

**The firmware constraint (decisive).** `Main_MiSTer/user_io.cpp:2937`:

```c
if (opensave) { FileGenerateSavePath(name, buf); user_io_file_mount(buf, 0, 1); }
```

The `0` is the drive index. **The companion `<rom>.sav` is always mounted on VD0**,
and only one is ever mounted — it belongs to whichever `FS` file was loaded last.
`opensave` comes from the `S` in an `FS<n>` CONF_STR tag (`menu.cpp:2412`); `C` is
`store_name`, a different flag. So there is no second VD to hand slot B, and the
earlier idea of mapping slot B to VD2 could never have worked.

**What was actually broken.** `memory_upload.sv`:

```systemverilog
if (cart_rom_id == ROM_ROM) begin
   if (curr_conf == CONFIG_SLOT_A) begin        // <- slot B fell straight through
      sram_size <= ...;  ref_sram <= 2'd0;      //    with NOTHING assigned
   end
end else begin
   ref_sram <= curr_conf == CONFIG_SLOT_A ? 2'd1 : 2'd2;   // non-ROM devices only
end
```

A plain ROM cart in slot B never had `sram_size` or `ref_sram` assigned at all, so
`nvram_backup:163` (`lookup_SRAM[num].size > 0 & image_mounted[num]`) could not fire
no matter what the menu said. **Correction to what this file said before:** the
`2'd1`/`2'd2` line is for FMPAC-class devices, not ROM carts — it was NOT already
giving slot B a working SRAM index.

Fixed by dropping the slot-A-only guard so both slots take `ref_sram = 2'd0`,
matching the firmware's fixed VD0. Slot A is unchanged.

**Flash carts too.** `flash16x_active/base/size` were hardwired to index `[0]` at
both consumers, so a Yamanooto or ASCII16X in slot B programmed correctly but had no
save or load path — the reported symptom was Final Fantasy (KR) in slot B showing no
continue and producing no file. Now selected by `flash16x_sel = active[1] &
~active[0]`: slot B is served when it is the only flash cart. With a flash cart in
BOTH slots slot A keeps the engine as before, because the single mounted `.sav`
cannot be attributed to one of them.

`status_menumask[6]` also only excepted `cart_conf[0]`, so the Save/Load buttons hid
themselves when the flash cart was in slot B; it now checks both slots.

**Menu.** `CONF_STR_SRAM_SIZE_B` on `O[62:60]`, hidden by `status_menumask[7]` via
`sram_B_select_hide`, mirroring slot A. `sram_B_select` joins `act_config` so a size
change triggers a reload. `H4F4` became `H4FS4` so the HPS is asked for the save at
all.

**Consequence worth knowing:** only the cart loaded LAST can be saved, because its
`.sav` is the one occupying VD0. That is a firmware property, not something the core
can work around.

## 6. PARKED — Yamanooto in slot B boots less than half the time

Reported 2026-08-23 by the user, who chose to park it rather than chase it now.
**Do not treat slot B Yamanooto as working.** Slot A is the supported configuration
and is hardware-verified.

Symptom: a Yamanooto-mapper ROM loaded into slot B starts correctly under ~50% of
attempts. Slot A with the same class of image is reliable.

What is already known that a future session should NOT re-derive:

- Persistence for slot B was wired this same day (`flash16x_sel`, section 5). That
  is a *save/load* path and is unrelated to a cart failing to start, so it is
  unlikely to be the cause — but it also has not been cleared, because the boot
  failures and the persistence change landed in the same build.
- Slot B DDR3 staging moved `0x1100000` -> `0x3000000` on the same day (see below).
  That fixed slot A's 8MB cart trampling slot B, so it should have made slot B MORE
  reliable, not less. **Whether the <50% figure was measured before or after that
  move is not recorded** — establishing that is the first thing to do, because the
  two hypotheses point in opposite directions.
- `docs/TODO_boot_flakiness.md` describes intermittent boot failures whose top
  hypothesis was exactly that DDR3 overlap. That document needs re-testing against
  the relocation regardless, and this symptom may be the same underlying fault
  rather than a new one.
- Both slots reserve a full 8MB for a Yamanooto/ASCII16X image
  (`memory_upload.sv` `x16_pad`), so the runtime SDRAM budget — not just the DDR3
  staging map — is worth checking for slot B. The DDR3 relocation did not touch
  SDRAM placement.

Suggested first step when this is picked up: pin down whether the failure rate
differs between `20260822b_yamawrite` (pre-relocation) and `20260823b_slotBsave2`
(post-relocation) with the identical ROM in slot B. That single A/B splits the
hypothesis space in half before any RTL is read.

## 7. Test cart — `tools/yamanooto_savetest.s`

Built because the OFFR guard was otherwise untestable: Selica's saves go straight
through JEDEC and never touch 0x7FFE with REGEN+SPIEN set. Border colour is the
result; green = all pass. Covers erase, byte program, the WREN gate, OFFR, and the
OFFR guard.

`sim/run_yamanooto_savetest.sh` runs the cart's exact bus sequence against the real
`cart_yamanooto` + `flash` so the expected outcome is known before hardware. Its
prediction (green) matched the board, which is the first evidence that this bench
can be trusted.

**Two limits of that bench, learned the hard way.** It injects the bus sequence and
never executes the Z80, so it cannot see cart-side bugs. Running the cart under
openMSX found two the bench could not:
- the resident routine was linked at 0x4000 and merely copied to RAM, so its
  `call`/`jp` targets still pointed into the cart, which it had itself re-banked
  to 0xFF -- the CPU ran off into the BIOS;
- it read once after a byte program instead of data-polling; a program is not
  instantaneous on a real part.

**openMSX still reports T2 there and that is unexplained.** Its own flash
debuggable shows the byte programmed and the CPU able to read it back, which
contradicts a T2 failure, and a progress marker read back as 0 though the routine
demonstrably ran -- so the introspection is untrustworthy and no conclusion was
drawn from it. Hardware says green.

## Also fixed alongside (2026-08-23)

**DDR3 staging overlap.** Slot A staged at `0xC00000` with slot B at `0x1100000` —
a 5MB gap, so an 8MB slot-A cart ended at `0x1400000` and trampled 3MB of slot B.
Slot B moved to `0x3000000` (above the 9MB FW PACK at `0x2000000`), giving slot A
10MB up to CAS at `0x1600000`. `MSX1.sv`'s CONF_STR load address and
`memory_upload.sv`'s constant were changed **together** — the FW PACK relocation
went wrong once by moving only one. This was the 1st-ranked hypothesis in
`docs/TODO_boot_flakiness.md`; that document now needs re-testing against this fix.

## Verified clean — do not re-audit

Offset arithmetic and the 10-bit wrap; K5 and K4 window masks (compared
exhaustively over all 65536 addresses, zero mismatches); MDIS; ROMDIS; reset values
(the "CFGR bits are not reset" sentence is **struck through** in the 15oct2024 PDF
— confirmed by rendering the page, and the vendor's yimmi8beta3 note says
*"changed mind and made all CFGR bits and OFFR reset when msx resets"*); SCC
visibility using the raw bank value (vendor: yimmi7 *"fixed scc selection while
using the offset register"*); size masking; the cart PSG's 32-step envelope.

SCC stereo is **not** a defect: the manual puts the channel panning on an optional
jack on selected models, not on the slot's mono SOUNDIN, so summing to mono is
correct for the path we emulate.

## Not Yamanooto, but found alongside and still open

* **Address mirroring.** openMSX folds 0x0000-0x3FFF and 0xC000-0xFFFF into the
  cart window; we return unmapped. Core-wide — `konami.sv` and `konami_scc.sv` do
  the same. Our `page8kB` arithmetic is already mirror-correct, so it is one term
  (`~page_ok` at `yamanooto.sv:183`) plus `bank_k4`'s compare. No pack we run needs it.
* **`memory_upload.sv:238` pads every Yamanooto/ASCII16X cart to a full 8 MB
  regardless of image size**, so slot A at DDR3 `0xC00000` unconditionally overruns
  slot B at `0x1100000` by 3 MB. See `docs/TODO_boot_flakiness.md` — this
  invalidates that document's discriminating test 2.
* **ECHO / HOME-key boot** moved out to `docs/TODO_someday.md`: on current
  firmware ECHO is read/clear and set only by a HOME boot, so software cannot
  reach it and implementing half of it buys nothing.
