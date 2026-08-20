# TODO — Yamanooto mapper: what is still missing

Recorded 2026-08-21, after a four-lens audit against openMSX master, the 15oct2024
hardware reference, the official User Manual, the vendor's own firmware release
notes, and SMX Team's MSX-side Z80 sources (`~/Documents/github/msx_dma_sw/modules/yamanooto/`).

**Already fixed and shipped** (do not re-investigate): `reg_hit`→`reg_rd` at
`yamanooto.sv:183` (RC744 item pickup, hardware-verified in `20260821a_yamafix`),
per-cart stable SCC mode, ENAR readback masking, cart-PSG readback at port 12H.
See `project-yamanooto-scc` in memory for the full history.

---

## 1. Flash write path is entirely unwired — HIGHEST IMPACT

`flash_wr_en` (`yamanooto.sv:80`) is produced, connected at `msx_slots.sv:399`, and
**consumed nowhere**. The `flash` instance at `msx_slots.sv:211-236` has no
Yamanooto term in `.ce`, `.addr`, `.sdram_offset`, `.is_ascii16x` or `.erase_limit`.
`memory_upload.sv:640` grants `DEV_FLASH`, but that bit is only tested inside the
MFRSD term, so the grant is inert. The cartridge is read-only in our core.

**Who this hurts, concretely:** `Final Fantasy (KR)`, `Golvellius 2 (KR)` and
`Jikuu no Hanayome (KR)` — the Celica Korean translations in
`/media/fat/games/MSX1/00_Celica_KOR/` — all save by writing `#12` to `#7FFF`
(REGEN+WREN) and then issuing JEDEC commands through the `#4AAA`/`#4555` unlock
pair. They are Yamanooto ROMs, so **their saves do not work at all today.**

What it needs:
1. a `flash_rq` / `flash_addr` output on `cart_yamanooto` (neither exists yet);
2. Yamanooto terms in the four `flash` muxes. Note the defaults are actively
   wrong, not merely absent: `.sdram_offset` falls through to the **MFRSD base**
   (an erase would land in another cart's region) and `.erase_limit` falls through
   to the MFRSD default, disabling the clamp added by `bf56cf4`;
3. **`flash.sv`'s byte-program (0xA0) path is structurally dead.** `flash.sv:174`
   guards on `(quadrupleProgram | write_cnt > 0)`, but `write_cnt <= 1` for
   `bytePrgram` can only execute from inside the block it is trying to enter. Only
   0x56 (quadruple) and 0x50 (double) can program. **0xA0 is the only program
   command a JEDEC/AMD flasher uses**, so wiring (2) without this still yields a
   cartridge that cannot be programmed. Confirmed absent from this branch and both
   worktrees (`git log --all -S allow_byteprog` is empty);
4. `.is_ascii16x` really means "AMD-family chip" — it selects manufacturer ID, CFI
   availability *and* boot-sector erase granularity. Rename or split it;
5. persistence: hook `flash_dirtysave` up. That engine already works — GoFigure's
   `.sav` is live at `/media/fat/saves/MSX1/MSXdev25_GoFigure_v1.2.sav` — so this
   is reuse, not new design.

Also latent, worth knowing before two flash carts can coexist: there is **one**
`flash` instance with **one** command FSM (`flash.sv:22-23`) shared by every cart,
so an MFRSD and a Yamanooto would interleave into the same unlock sequence.

Reference for correct behaviour: `openMSX/src/memory/Yamanooto.cc:235-240` plus
`AmdFlash.cc`. openMSX persists an 8 MB SRAM file; the real cartridge is flash.

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

## 3. 0x7FFE is three registers; we implement one

Per the vendor's own sources (`yamacore/SRC/YAMASPI.Z8A:9-30`), ENAR bit1 = SPIEN,
bit2 = MSTEN, and 0x7FFE is `OFFR` / `MOFFR` (when MSTEN) / `SPICON` (when SPIEN).
We treat every write as OFFR, so a MOFFR or SPICON write silently destroys it.
**openMSX has the identical defect** (`Yamanooto.cc:223-225`).

Consequence: the genuine Yamanooto firmware cannot launch a game. Its boot ROM
(`boot/SRC/YAMABOOT.Z8A:175`) writes `ENAR=%101` (MSTEN), then MOFFR, then clears
MSTEN and writes `OFFR=0` — on our core the second write overwrites the first.
`YAMAFL.COM` is affected the same way.

Minimum honest fix (does not add MOFFR, just stops the corruption): qualify the
OFFR write at `yamanooto.sv:141` with `~enar[2] & ~enar[1]`.

Not urgent for what we run: neither `PACK_K.ROM` nor the Neo-Ultimate Collection
ever sets those bits — every `LD (7FFF),A` site in both writes 0x80 or 0x81.

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
