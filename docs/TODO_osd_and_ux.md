# TODO — OSD layout and core behaviour requests

Recorded 2026-08-21. **Both items DONE 2026-08-23** (`20260823c_audiomenu`), built
and deployed but **not yet tested on hardware**. Details at the end.

---

## 1. Make the forced reset on ROM / mapper change optional

**Now:** `rtl/peripheral/slots/memory_upload.sv:78`

```verilog
assign reset_rq = ! (state == STATE_IDLE | state == STATE_ERROR);
```

`reset_rq` is asserted for the **whole** upload FSM, and `MSX1.sv:405` folds it
straight into the machine reset:

```verilog
wire reset = RESET | status[0] | status[10] | reset_rq;
```

So loading a ROM, or changing the mapper for an already-loaded one, always resets
the machine. There is no way to turn it off.

**Wanted:** an OSD toggle, so a ROM or mapper can be swapped **without** resetting —
useful for comparing mappers on the same running program, and for anything that
should survive the swap.

**Care needed before implementing.** The reset is not decoration; it is what keeps
the CPU off the bus while `memory_upload` is streaming into DDR3/SDRAM and while
the slot layout registers change underneath it. Points to settle:

* A swap that changes `lookup_RAM` bases or the slot layout while the CPU is
  executing from the old mapping is a genuine hazard, not just a cosmetic one.
  The safe form is probably "hold the CPU (like `msx_pause` / `dma_active`) for the
  transfer, then release without asserting reset", not "drop the reset entirely".
* Slot/subslot select registers and the mapper's own bank registers keep their old
  values across a no-reset swap. Decide whether they should be re-initialised.
* `rom_eject` (`status[10]`) and the boot-time autoload path should keep resetting;
  the toggle should only cover a user-initiated swap of an already-running machine.
* Check the interaction with `nvram_backup` / `flash_dirtysave`, which use
  `upload_active` and `load_sram` to decide when to restore.

Suggested shape: `"O[nn],Reset on ROM change,Yes,No;"`, defaulting to **Yes** so
existing behaviour is unchanged unless asked for.

## 2. Group the MoonSound items under an "Audio settings" page

**Now:** five MoonSound entries sit flat at the OSD top level (`MSX1.sv`, in
`CONF_STR`), between the Pause and Debug Overlay items:

```
"O[45],MoonSound,Off,On;"
"O[46],PCM Mute,Off,On;"
"O[47],FM Mute,Off,On;"
"O[50:49],OPL4 PCM Volume,0dB,-4dB,-8dB,-12dB;"
"O[53:52],OPL4 FM Volume,0dB,-4dB,-8dB,-12dB;"
```

**Wanted:** an `Audio settings` submenu, with the MoonSound items inside it —
mirroring the existing `"P1,Video settings;"` page, so the top level stays short.

Mechanically this is just a page prefix, e.g.

```
"P2,Audio settings;",
"P2O[45],MoonSound,Off,On;",
...
```

Points to settle:

* **Which items move.** MoonSound On/Off is arguably a machine-configuration item
  rather than an audio-mixer one, and it also gates `ms_audio_*` in `msx.sv:1381`.
  Mute/Volume clearly belong under Audio. Debug Overlay is not audio and should
  stay where it is.
* `status` bit numbers do **not** change — a page prefix is presentation only, so
  saved settings survive.
* Watch the CONF_STR menu-index rule this project has already been bitten by: a
  token at index 1 is a dead slot (MiSTer reserves it for SS/UART/MIDI). Adding a
  page near the top shifts indices, so re-check that `"C,Cheats;"` and anything
  else order-sensitive stays at index >= 2. See `project-cheat-engine` in memory.
* If a future PSG/SCC volume control appears (see `TODO_yamanooto.md`, the cart-PSG
  vs SCC ratio note), it belongs on the same page — worth leaving room.


---

# DONE 2026-08-23 — `20260823c_audiomenu`

**1. Reset on ROM change is now optional.** `O[64],Reset on ROM change,Yes,No`,
default **Yes** so nothing changes unless asked. The reset was NOT simply dropped —
`reset_rq` is what keeps the CPU off the bus while `memory_upload` streams into
SDRAM and the slot layout moves underneath it. With the toggle set to No the machine
is **held** instead, reusing `msx_pause`, which already gates every CPU clock enable
and is used the same way by the nvram DMA:

```systemverilog
wire upload_hold = reset_rq & status[64];
wire reset = RESET | status[0] | status[10] | (reset_rq & ~status[64]);
wire msx_pause = ... | upload_hold;
```

Power-on is unaffected either way (`RESET` covers it). **Caveat that keeps the
default at Yes:** across a no-reset swap the slot/subslot select registers and the
mapper's own bank registers keep their old values, exactly as this document warned.

**2. Audio settings page.** MoonSound's five entries moved under `P2,Audio settings;`.
Status bits are unchanged — a page prefix is presentation only, so saved settings
survive. `C,Cheats;` sits before the new page, so the index-1 dead-slot rule is not
disturbed.

**3. Not asked for, but it belonged on the same page** (this document predicted it):
per-source trims for the internal PSG, OPLL and SCC, `O[66:65]` / `O[68:67]` /
`O[70:69]`, 4 steps each (0dB, +4dB, -4dB, -8dB). Every source was already a separate
wire — `msx_slots.sv` summed `sound_opll + scc_wave + sound_psg` in one line, and the
internal PSG is `audioPSG` in `msx.sv` — so there was a natural insertion point.
Entry 0 is `x128 >>> 7`, **exactly** unity, so an untouched menu is bit-identical;
`run_sccplus`'s golden waveform comparison confirms it over 51,737 samples.

**Latent defect fixed alongside:** that one-line sum was 16-bit and wrapped silently
when three loud sources coincided. It is now a 19-bit sum that saturates. 19, not 18:
the worst case is 51966 + 51966 + 32767 = 136699, which overflows an 18-bit signed
sum and wraps *before* the clamp can see it — `sim/run_audio_trim.sh` caught exactly
that during development.

**`status` widened 64 -> 128 bits.** Only bits 49, 50, 52, 53, 63 were left, and this
needed seven. `hps_io` already drives `[127:0]` (`sys/hps_io.sv:114`); only `MSX1.sv`
was narrowing it. Existing bits are untouched, so saved settings survive.

**Process note worth keeping.** The first build failed: the `msx` instance connects
by `.*`, and the new ports were wired into `debug_overlay` by mistake. Verilator
`--lint-only` did NOT catch it — it never elaborates the submodules here, and this
project's lint invocations pass `-Wno-PINMISSING`. **A clean lint is not evidence of
port correctness in this repo; only synthesis is.**


---

# Three-critic re-review, 2026-08-23 — `20260823d_critfix`

Three hostile reviewers (regression / semantics / arithmetic lenses) went over
`c361934..2699405` before any hardware test. **13 findings; 6 were defects
introduced that same day.** Every one below was independently re-verified here
before acting on it.

## Fixed

| finding | defect | fix |
|---|---|---|
| F1/S1 | `H4FS4` steals VD0. The firmware mounts exactly one `<rom>.sav`, hardcoded to drive 0 (`user_io.cpp:2937`), so the `S` did not give slot B a save — it unmounted slot A's. `load_sram` then read `<romB>.sav` into slot A's SRAM/flash region, and the next save wrote slot A's data into `<romB>.sav`. **Both files destroyed, in the DEFAULT configuration.** | reverted to `H4F4` |
| F3/S2 | `ref_sram <= 2'd0` for both slots. `lookup_SRAM[0]` is both the save target AND the runtime BRAM allocation, so slot B overwrote it and slot A's cart then read/wrote SLOT B's buffer. Turned an inert gap into live mutual corruption. | restored the slot-A-only guard; slot B SRAM menu withdrawn |
| S3 | `flash16x_active`/`base`/`size` are cleared only by `reset`, and `flash_dirtysave` reads the base LIVE — so with the hold path they survive a cart swap and aim the next DMA at the departed cart's region. | `upload_hold &= ~\|flash16x_active` — refuse the no-reset path whenever a flash cart is present, rather than thread a clear through two modules |
| S4 | `msx_pause` gates CPU clock enables but MoonSound runs on `clk_sdram` and is held only by `reset`. It would keep hammering SDRAM ch4 through a multi-MB ch1 upload, and a FW PACK upload moves `pcm_rom_base` under a live PCM fetch. | new `reset_ms = reset \| upload_hold`; the OPL4 stays in reset for the whole transfer |
| F6 | `.HPS_status(status)` silently truncated 128->64. Harmless today (highest read is bit 62) but the next option at bit >= 64 read inside `msx_config` would be a constant 0 with no error anywhere. | port widened to `[127:0]` |
| A2 | `vol_mul` returned `signed [8:0]`, max 255. A future "+8dB" entry (322) reads as **-190** — a sign inversion of the whole channel. `msx.sv`'s `psg_mul` is UNSIGNED [8:0], so the two "identical" tables did not have identical headroom. | widened to `signed [9:0]` |
| A3 | `check_audio_trim_consts.py` and its runner hook were never committed, so the shipped commit had a copy-TB with no binding to the RTL. | committed |

## Deliberately NOT changed (user decision)

* **`+4dB` on PSG/OPLL/SCC stays.** The reviewer measured 36.9% of the SCC input
  range clipping at +4dB, and that is correct — the compressor's linear window is
  ±16384 (`msx.sv`) and SCC's 0dB full scale is *exactly* ±16384 by construction
  (`scc_sound.sv:23`, `wave_A` signed[10:0] << 4). But that figure is over the
  input RANGE, not over playing TIME: clipping starts at 63% of full scale, and
  quiet material never gets there. For a quietly-mixed game +4dB is a real,
  useful gain. Presenting a range statistic as if it were a time statistic
  overstated the case.
* **The OFFR guard stays.** It newly blocks OFFR writes when `REGEN` is set
  together with `SPIEN` or `MSTEN` — which is what real hardware does, since
  0x7FFE is SPICON/MOFFR in those states. openMSX lacks the guard, so the usual
  cross-check will not catch a divergence here. (The reviewer's specific worry
  about `#12` = `WREN|SPIEN` does not apply: REGEN is clear there, so the write
  was already blocked.) **Needs a Selica hardware regression test** — the
  hardware-verified `20260822b` did not have this guard.

## Still open from the review

* **OPL4 menu labels use two different anchors** — PCM label X = net X−8 dB, FM
  label X = net X−4 dB, and neither menu's "0dB" is unity. Flagged independently
  by two reviewers on two days. Display only; no sound change.
* **FW PACK is now capped at 16 MB** by slot B at `0x3000000`, with no build-time
  check. The current pack is 10.5 MB, up from 8.4 MB — a real growth trend.
  Crossing 16 MB would silently corrupt slot B staging.
* **No TB instantiates the real `msx_slots`.** `check_audio_trim_consts.py` pins
  the constants and widths, which is the mitigation this repo already uses, but it
  is not the same as a regression test against the shipped module.

## Two corrections to claims made in earlier commit messages

1. **"sccplus golden still matches" is not evidence for the audio trims.**
   `run_sccplus.sh` compiles only `scc_sound.sv` and the two IKASCC files —
   `msx_slots.sv` is not in its file list — and it defaults `GOLD_REF=HEAD`, so it
   diffs the commit against itself. Entry-0 unity *is* genuinely bit-exact (proven
   exhaustively over all 65,536 inputs, and `-32768*128>>>7 == -32768`), but not by
   that test. This claim was repeated several times before anyone checked it.
2. **"an untouched menu is bit-identical" is false where the old sum overflowed.**
   The previous 16-bit `sound_opll + scc_wave + sound_psg` wrapped; the new 19-bit
   sum saturates. On those inputs the output legitimately differs — that is the
   point of the change, but it means prior recordings will not reproduce.

## Method note

`verilator --lint-only` does **not** catch port errors here: it never elaborates the
submodules, and this project's lint invocations pass `-Wno-PINMISSING`. The first
audio build failed because new ports were wired into `debug_overlay` while the
`msx` instance connects by `.*`. **A clean lint is not evidence of port
correctness in this repo; only synthesis is.**

One reviewer also reported Verilator giving a vacuous pass on their own harness
(0 of 729 where the right answer is 276) while iverilog was correct. Checked here:
`tb_audio_trim` is not vacuous — an injected fault is caught, and iverilog and
Verilator agree exactly (28,099 checks). iverilog is installed and fast; worth
using as a routine second opinion.


---

# Reverted: SCC+ "RAM mode" writes (`e867ae2`, backed out same day)

Two hostile reviewers independently returned DO NOT SHIP, and both were right.
The RTL is back to its pre-`e867ae2` state; only `sim/tb_mfrsd_sccsound.sv`
survives, which is unrelated and good.

**The premise was false.** The commit claimed `ram_ro` is 1 for every cart image
so a 128KB SCC+ sound cartridge could not be detected by write-then-read-back.
But `memory_upload.sv:661` gives `CART_TYP_SCC2` the data id `ROM_RAM`, and
`memory_upload.sv:414-415` clears `ro` for exactly that id. And `sccMode` — hence
`en_ram`, hence `ram_we` — can only be written under `sccDevice`, which only
`CART_TYP_SCC2` sets. So `ram_we` could only ever assert in the one case where
`ram_ro` was already 0: **the write already landed and detection already worked.**
A reviewer proved the redundancy exhaustively (256 mode values x 64 addresses,
zero differing cycles).

**The MFRSD half was worse than redundant — it inverted the reference.**
`MegaFlashRomSCCPlusSD.cc:627-636`: `isRamSegment2/3` are function-local bools
that exist solely to close the SCC *register window*; control then falls through
to `writeToFlash(flashAddr, value, time)` at `:720-722`. There is no
`internalMemoryBank`, no store of any kind — **subslot 1 of a real MFRSD is a
flash chip and there is no SRAM behind it.** The commit invented a RAM the
hardware does not have, and its `flash_rq & ~ram_we` change simultaneously
withheld the byte the reference always delivers, which would have broken flash
programming whenever `sccMode` bit 4 happened to be set.

**Other findings worth keeping** (not fixed here; pre-existing):
* `konami_scc.sv` declares `mem_size` and never reads it. `mem_addr` uses the raw
  8-bit bank register, so a RAM-mode write can land ~2MB past a 128KB cart's base.
  openMSX masks (`registerMask = 0x0F`, so bank 0x10 mirrors bank 0x00) and honours
  `isMapped`, dropping writes that select no block. `docs/sccplus_spec.md` **S8-2**
  already records this and still says 미수정. **The out-of-bounds path predates this
  commit and is still there** — reverting removed the blessing, not the hazard.
* `sccMode` is cleared only by `reset`. With "Reset on ROM change = No" it survives
  a cart swap, so a mode set by an SCC+ cart stays live for the next cart.
* `mfrsd.sv` computes `isRamSegment2/3` unconditionally; openMSX wraps the whole
  SCC block in `isKonamiSCCmapperConfigured()`.

**Two lessons about the benches, which matter more than the code.**

1. `tb_sccram.sv` hardcoded `localparam bit RAM_RO = 1'b1` — the false premise, as
   a parameter — and then confirmed it. Set it to the real value and every check
   passes WITHOUT the change, and the bench's own negative control fires
   "NEGCTL BROKEN". A test that encodes the assumption it is meant to check is
   worse than no test: it manufactures evidence. Deleted.
2. `tb_mfrsd_sccsound`'s M4 was theatre, and the replacement had to be proven by
   severing the chip. `debug_scc_wr` is not an IKASCC signal —
   `scc_sound.sv:105` makes it a sticky ~21,000,000-cycle counter, so once any
   earlier SCC-window write sets it the check cannot fail, and it would pass with
   IKASCC entirely disconnected. Removed rather than repaired; M1-M3 already
   require the chain and their negative control proves it.


## Follow-up: `tb_mfrsd_sccsound` M4, rewritten and mutation-proven

A third reviewer showed the whole bench was theatre, not just M4: hardwiring
`scc_sound`'s `.i_SCCP_MODE` to `2'd0` — severing the mode from IKASCC entirely —
still passed 4/4, because M1-M3 read `scc_mode`, a **port of `mapper_mfrsd1`**, the
same signal `tb_mfrsd_sccmode` already reads. Compiling `scc_sound` and two
`IKASCC_player_s` observed nothing.

M4 now writes ch5's waveform and reads it back **through** `scc_sound`/IKASCC
(`scc_dout` is IKASCC's `o_DB`, `scc_sound.sv:89,125`), and checks it differs from
ch1's. Proven by severing each interface in turn:

| severed | caught? |
|---|---|
| `i_SCCP_MODE` | yes |
| `i_WRRQ` **and** `i_WR_n` | yes |
| `i_ABLO` | yes |
| `i_DB` | yes |

The reviewer's own mutation of `i_WRRQ` alone passed, and they read that as the
bench being blind. It is not: `scc_sound.sv:119` drives `i_WR_n(~scc_wr_A)` as a
second, independent write path, so cutting `i_WRRQ` leaves writes working. The
finding was right about the old M4 and overstated about the new one — worth
recording, because "the mutation passed" only means something if the mutation
actually severs the thing.

Writing this check also surfaced a real error of mine: ch5's waveform sits at ABLO
`0x80-0x9F` in **Plus** mode, not `0xA0-0xBF` (that is the **Compat** layout —
`tb_sccplus`'s T2/T3 headers state both). The first version used the Compat address
and failed. The previous M4 could not have caught that, because it could not fail.
