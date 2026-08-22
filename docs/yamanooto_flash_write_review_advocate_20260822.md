# Yamanooto flash-write path — ADVOCATE review

| | |
|---|---|
| **Agent name** | `advocate2` |
| **Agent / session id** | `0e07ce08-0d62-408c-a5ff-91ad83c4b04b` |
| **Role** | Advocate (one of three perspectives: advocate / critic / neutral) |
| **Date** | 2026-08-22 |
| **Branch** | `moonsound_ascii16x` (change UNCOMMITTED at review time) |
| **Model** | claude-opus-5 |

Brief: build the strongest **honest** case that the change is correct and ready to
ship, and state plainly where that case cannot be made. Every claim below is tagged
VERIFIED (read or ran it) or INFERRED.

---

## Scope of the change reviewed

Adds a flash-WRITE path to the Yamanooto cartridge mapper, previously read-only.

- `rtl/peripheral/slots/yamanooto.sv` — new JEDEC state machine, `flash_addr` /
  `flash_rq` / `prog_we` outputs
- `rtl/peripheral/slots/msx_slots.sv` — mux wiring, `prog_we` into the SDRAM write
  path, persistence hookup
- `rtl/peripheral/slots/flash.sv` — `is_ascii16x` split into `amd_family` +
  `boot_sector`, plus an erase sector-index fix
- `sim/tb_yamanooto_flash.sv`, `sim/run_yamanooto_flash.sh` (untracked, new)
- `sim/tb_flash_erase.sv`, `sim/run_flash_erase.sh` (untracked, appeared mid-review)

Real-world goal: three Korean fan translations (Final Fantasy, Golvellius 2, Jikuu no
Hanayome) save by setting WREN in register `#7FFF`, then issuing JEDEC flash commands
through `#4AAA` / `#4555`. They currently cannot save at all.

### Caveats on the working tree

The tree **moved during the review**. My first read of `flash.sv` had the old
one-line `erase_block_num` expression; a later read had a split fix at
`flash.sv:90-95`, and `sim/tb_flash_erase.sv` + `run_flash_erase.sh` appeared
(timestamped 19:24). All claims are against the tree as of my final reads, and both
testbenches were re-run against that state.

`git diff` also carries unrelated MoonSound volume work (`MSX1.sv`, `rtl/msx.sv`,
`ymf278b_top.sv`, `sim/tb_opl4_gain.sv`). The change under review is only the three
`rtl/peripheral/slots/*.sv` files plus the two new testbenches.

---

## 0. Directly-asked questions

### Testbench results — VERIFIED, both run

```
$ sim/run_yamanooto_flash.sh
tb_yamanooto_flash: 17 checks, 0 errors
rc=0

$ NEGCTL=1 sim/run_yamanooto_flash.sh
FAIL: Y1 WREN clear must block programming
FAIL: Y4 ROMDIS must block programming

NEGATIVE CONTROL: WREN/ROMDIS gates inverted — Y1/Y4 MUST fail.
negative control OK: 2/17 checks failed as required
rc=0

$ sim/run_flash_erase.sh
tb_flash_erase: 7 checks, 0 errors
rc=0
```

### openMSX `Yamanooto.cc` `writeMem()` — SCC-window writes while WREN is set

VERIFIED (`Yamanooto.cc:233-240`): all SCC handling lives in the `else` branch of
`if (enableReg & WREN)`. With WREN set, `writeMem` does

```cpp
if (!(configReg & ROMDIS)) { flash.write(getFlashAddr(address), value, time); }
```

and returns. `isSCCAccess()` is never consulted, the SCC never sees the write, and no
bank register or SCC mode register is updated. The write goes to flash, full stop.

The RTL diverges here in two opposite directions:

- **Bank / mode-register writes: correctly suppressed.** `bank_hit` and
  `modereg_hit` both carry `~flash_wr_en` (`yamanooto.sv:143,147`), matching openMSX.
  TB check Y8 covers this.
- **SCC *sound* writes: NOT suppressed.** `scc_req` (`yamanooto.sv:127`) has no
  `flash_wr_en` term, so a WREN write into 0x9800-0x9FFF (SCC mode) or
  0xB800-0xBFFD (SCC+ mode) still routes to the SCC and, via `mem_unmaped`
  (`yamanooto.sv:186`), blocks `prog_arm`. openMSX would have programmed that byte
  to flash. INFERRED consequence: a save whose target byte lands in an active SCC
  window is silently dropped. A lost byte, not corruption, and unlikely in a real
  save routine — but a genuine divergence.

### `flash.sv` erase — uniform-sector chip, confirm at flash address 0x2000

VERIFIED: **`erase_base = 0`** (sector 0), i.e. `sdram_addr = sdram_offset + 0`.

Confirmed three independent ways:

1. Reading `flash.sv:90-95` —
   `erase_block_num <= (boot_sector & ~(addr > 23'hFFFF)) ? {5'd0, addr[15:13]} : {1'b0, addr[22:16]}`
   → with `boot_sector = 0` this is `addr[22:16]` = 0 — combined with `erase_base` at
   `flash.sv:63`.
2. An independent scratch Verilator TB (`/tmp/adv_fl`) driving AA/55/80/AA/55/30 with
   `sdram_offset = 0x100000`, which printed `erase target=002000 -> sdram_addr=0100000`.
3. The project's own `sim/tb_flash_erase.sv`, which asserts the same.

Full scratch-sim table:

| `boot_sector` | confirm addr | `erase_base` |
|---|---|---|
| 0 | 0x000000 | 0x000000 |
| 0 | 0x002000 | 0x000000 |
| 0 | 0x008000 | 0x000000 |
| 0 | 0x010000 | 0x010000 |
| 0 | 0x7F0000 | 0x7F0000 |
| 1 | 0x002000 | 0x002000 |
| 1 | 0x00E000 | 0x00E000 |

`boot_sector = 1` reproduces the pre-split ASCII16X 8KB-granularity semantics exactly.

**This is current behaviour only.** The one-liner in the tree when the review started
produced `erase_base = addr[15:13] << 16` for the same confirm — flash 0x2000 would
have wiped sector 1 (0x10000-0x1FFFF) and left the target un-erased. That fix landed
mid-review, and it changes MFRSD too. See §2 (b).

---

## 1. Case for shipping

**Tests run, pass, and are falsifiable.** The negative control inverts the two gates
that matter and the TB notices — this is not a green light that stays green
regardless. The TB instantiates the real `cart_yamanooto` (see the build command in
`sim/run_yamanooto_flash.sh`), not a re-model.

**openMSX gating is matched where it matters.** VERIFIED from `Yamanooto.cc:190-240`:
`writeMem` handles 0x7FFC-0x7FFF first (ENAR unconditional, CFGR/OFFR behind REGEN),
then the WREN/ROMDIS-gated `flash.write()` — programming needs WREN set, ROMDIS
clear, and **not** REGEN. The RTL's

```systemverilog
wire cart_wr = cs & cpu_mreq & cpu_wr & page_ok & flash_wr_en & ~romdis;  // yamanooto.sv:210
```

is the same conjunction. This is the load-bearing correctness point for the three
Korean translations, which write `#12` to `#7FFF` (WREN|SPIEN, REGEN stays clear) —
under an implementation that required REGEN they would silently never save.

`readMem` (`Yamanooto.cc:170-180`) intercepts the register window only when
`(enableReg & REGEN)`, otherwise falls through to `flash.read()`. The RTL's
`flash_rq = cs & page_ok & ~romdis & ~scc_req & ~reg_rd` (`yamanooto.sv:256`) uses
`reg_rd` (which already includes `regen`), not the address-only `reg_hit` — the same
distinction, and TB check Y7 asserts both polarities.

**Erase is bounded to the cart's own region, and the bound is latched, not muxed.**
VERIFIED: `sdram_offset` and `erase_limit` are sampled only on the `erase_block`
pulse (`flash.sv:173-188`), where `sdram_addr <= sdram_offset + erase_base` and
`write_cnt` are registered. The multi-cycle 0xFF fill afterwards runs entirely off
those registers and never re-reads the mux, so it cannot be steered off-region by a
later bus cycle. `erase_limit = own_flash_rq ? 27'(size) << 14 : 27'h800000`
(`msx_slots.sv:245`) — `size` in 16KB units, so 8MB for a full image — and the clamp
at `flash.sv:181-183` skips a sector starting past the region and truncates one
straddling the end.

**`own_flash_rq` is a faithful refactor — ASCII16X and MFRSD behaviour is unchanged
in `msx_slots.sv`.** VERIFIED by expression-level comparison against the three lines
it replaced:

| | old | new |
|---|---|---|
| id / CFI | `is_ascii16x = ascii16x_rq & ~mfrsd0 & ~mfrsd3` | `amd_family = own_flash_rq` |
| erase bound | `(same expr) ? size<<14 : 8MB` | `own_flash_rq ? size<<14 : 8MB` |
| sector map | (folded into `is_ascii16x`) | `boot_sector = ascii16x_rq & ~mfrsd0 & ~mfrsd3` — old form verbatim |
| offset | `ascii16x_rq ? base_ram : mfrsd_base_ram[0]` | `(ascii16x_rq \| yamanooto_rq) ? base_ram : mfrsd_base_ram[0]` |

with `own_flash_rq = (ascii16x_rq | yamanooto_rq) & ~mfrsd0 & ~mfrsd3`
(`msx_slots.sv:215`). Since `yamanooto_rq` requires `cs = (mapper == MAPPER_YAMANOOTO)`
(`msx_slots.sv:406`) and `ascii16x_rq` requires `cs = (mapper == MAPPER_ASCII16X)`
(`msx_slots.sv:383`), the two are mutually exclusive by construction — so for an
ASCII16X cart every one of the four `flash` ports evaluates to precisely its old
value, and for MFRSD carts (both rq = 0) likewise. The added `yamanooto_rq` term in
the `addr` mux sits **after** both MFRSD terms, so MFRSD priority is untouched.

**The shared `flash.sv` command FSM was not touched.** VERIFIED: the entire
`flash.sv` diff is (a) the port rename `is_ascii16x` → `amd_family` plus new
`boot_sector`, (b) three substitutions of that rename, (c) the sector-index fix.
`int_valid1..5`, `valid`, `index`, `state`, `ident`, the offset check, and the
write-path if/else-if structure are byte-identical. This is exactly the discipline
the earlier reverted boot failure demands.

**The program data byte reaches SDRAM by the proven route.** VERIFIED:
`prog_arm <= ~mem_unmaped` is evaluated on the *data* write (`yamanooto.sv:238-240`),
and `prog_we = prog_arm & cart_wr` (`yamanooto.sv:252`). During that write
`mem_unmaped` (`yamanooto.sv:186`) is 0 — `page_ok` holds, `romdis` is clear, and its
`cpu_wr & ~flash_wr_en` term is killed by WREN — so `mapper_addr` selects
`mapper_yamanooto_addr` and `ram_addr = base_ram + mem_addr`
(`msx_slots.sv:124-125,145`) targets the right byte. `prog_we` then forces `sdram_ce`
and clears `ram_rnw` past the region's read-only flag (`msx_slots.sv:162,164`).
Structurally identical to `ascii16x.sv:105-139`, which is hardware-proven on this
board.

**Persistence granularity fits Yamanooto better than ASCII16X.** VERIFIED:
`flash_dirtysave` marks `dirty[prog_addr[22:16]]` — one bit per 64KB, 128 bits
covering the full 8MB (`rtl/flash_dirtysave.sv:80,133`) — and SAVE re-reads real
SDRAM contents for dirty blocks. Yamanooto's erase sector is uniform 64KB, so an
erase+program cycle marks exactly the block that was erased, and the 0xFF state is
captured along with the programmed bytes. (For ASCII16X's 8KB boot sectors that
alignment is coarser.) The prog-address mux
`mapper_yamanooto_prog_we ? mapper_yamanooto_flash_addr : mapper_ascii16x_addr[22:0]`
(`msx_slots.sv:74-75`) is safe for the same mutual-exclusion reason.

**Erase-window read behaviour matches the real part.** VERIFIED: during erase
`dout = 8'h00` with `data_valid` asserted (`flash.sv:43-44,57`), so the cart reads
back 0x00 — DQ7=0, the AMD "erase busy" answer a polling loop expects, flipping to
real data when the fill ends. INFERRED: on a real S29GL064 the array is likewise
unreadable during erase, so any save routine that works on the real cartridge must
already run from RAM — the same constraint, not a new one.

---

## 2. Weak, unproven, or hardware-only

### (a) BLOCKING and desk-verifiable — the OSD entries stay hidden for Yamanooto

VERIFIED: `MSX1.sv:325` sets

```systemverilog
status_menumask[6] = (lookup_SRAM[0].size + ... + lookup_SRAM[3].size == 0)
                   & (cart_conf[0].selected_mapper != MAPPER_ASCII16X);
```

and `MSX1.sv:274-276` hides `SRAM Save` / `SRAM Load` under `H6`.
`rtl/msx_config.sv:63` forces `cart_conf[0].selected_sram_size = 0` when
`mapper_A_select == 4'd10` (Yamanooto), and `msx_config.sv:64` makes slot B always 0.
So with a Yamanooto cart the sum is 0, the mapper is not ASCII16X, bit 6 sets, and
both menu items are hidden — the user has no way to press Save.

The RTL plumbing underneath is correct and complete (`flash16x_active` now latches
for `MAPPER_YAMANOOTO`, `msx_slots.sv:547-550`), but the change is not end-to-end for
its stated goal until `MSX1.sv:325` also excepts `MAPPER_YAMANOOTO`. I cannot argue
this away: it is a one-line omission and it defeats the user-visible feature.

### (b) MFRSD DOES change behaviour, inside the file we promised not to disturb

VERIFIED: MFRSD passes `boot_sector = 0`, so the sector-index fix at
`flash.sv:90-95` alters MFRSD erases whose flash address falls in the low 64KB.
Previously such an erase wiped sector `addr[15:13]` (e.g. flash 0x2000 wiped
0x10000-0x1FFFF and left the target intact); now it wipes sector 0.

The in-tree comment calls this a latent MFRSD defect and asserts it was verified in
simulation on the pre-split file. My own scratch sim reproduces the **new** behaviour,
but I did **not** re-run against the pre-change file, so "the old behaviour was wrong"
is INFERRED from the arithmetic, not measured.

Either way this is a live change to the hardware-proven MFRSD/Nextor path — precisely
the class of edit that produced the earlier reverted boot failure. It needs an MFRSD
boot + Nextor flash-write test on real hardware. Desk analysis cannot clear it.

### (c) `flash.sv`'s command FSM is not WREN-gated for Yamanooto

VERIFIED: `ce = ... | mapper_yamanooto_flash_rq` and `we = cpu_mreq & cpu_wr`
(`msx_slots.sv:227,229-231`), and `flash_rq` (`yamanooto.sv:256`) has no
`flash_wr_en` term. So with WREN clear, a write into the ROM window still feeds
`flash.sv`'s FSM — meaning autoselect (0x90, which sets `state` and makes every cart
read return ID bytes until 0xF0) and sector erase (AA/55/80/AA/55/30) are reachable
without WREN, which openMSX refuses (`Yamanooto.cc:234`). The mapper's own FSM is
correctly gated, so *programming* is safe; erase and autoselect are not.

INFERRED, low probability: reaching either needs an exact 3- or 6-write sequence at
`cpu_addr[11:1] == 0x555 / 0x2AA` with exact bytes. ASCII16X has the identical
exposure (`ascii16x.sv:107`, `flash_rq = cs`) and is field-proven, which is the only
evidence that it does not bite — but an 8MB multi-ROM has a larger surface than a
single-game ASCII16X cart. The tightening (`& (cpu_rd | flash_wr_en)`) is free.

### (d) SCC-window writes with WREN set diverge from openMSX

See §0. Lost byte, not corruption. Mitigation is one added term on `scc_req`.

### (e) Two Yamanooto carts share one `flash` instance

VERIFIED by inspection: `flash` is a single instance (`msx_slots.sv:216`) with one
command FSM, one `state`, one erase engine, so A/B carts of the same type would
interleave. Same pre-existing limitation as ASCII16X; not introduced here, not tested.

### (f) Everything about real hardware

Unproven from the desk: whether SDRAM contention from a 64KB 0xFF fill is tolerable
at the current fit (project history records a fit-dependent SDRAM_DQ congestion
problem); whether the three Korean translations' save routines run from RAM during
erase; whether timing closes with the added logic; whether a writable `.sav`
companion file actually mounts for a Yamanooto ROM load (the ASCII16X notes flag
mount-of-a-writable-companion as the next blocker, and nothing in this diff addresses
it). No fitter run, no board run.

### (g) `sdram_offset` / `addr` mux asymmetry

VERIFIED: `sdram_offset` (`msx_slots.sv:237`) lacks the `~mfrsd0 & ~mfrsd3` guard
that the `addr` mux priority implies, so if `mfrsd0_flash_rq` could ever co-assert
with `ascii16x/yamanooto_flash_rq`, the offset and the address would come from
different carts. Pre-existing shape, merely widened; I could not prove
`device == DEVICE_MFRSD0` is mutually exclusive with `mapper == MAPPER_YAMANOOTO`, so
this is flagged rather than cleared.

### (h) Testbench scope

All 17 checks are on `cart_yamanooto` in isolation — gates, arming, addressing,
`flash_rq` windows. There is no integration TB that drives `msx_slots` end-to-end and
observes an actual SDRAM byte change, and none that exercises Yamanooto *through*
`flash.sv`'s erase (the erase TB drives `flash.sv` directly). The join between the two
FSMs is verified by reading, not by simulation.

---

## 3. Strongest counter-argument, and the answer

The critic's best shot is **(b)**:

> You said you would not touch the shared `flash.sv` command FSM because a previous
> broad edit there caused a boot failure — and then you changed erase sector decoding
> for MFRSD, the one path Nextor boots from.

**I cannot rebut this.** I can only narrow it: the edit is one expression inside the
`din == 8'h30` branch, reached only after a full valid six-write erase sequence, so it
cannot fire during boot or ordinary reads — the failure mode is "MFRSD flash writes
erase a different sector than before", not "the core does not boot". That is a much
smaller blast radius than the reverted edit, which loosened the command whitelist
itself. But smaller is not zero: this hunk requires an MFRSD-on-hardware test, or
should be split into its own commit so it can be reverted independently of the
Yamanooto feature.

The second-best shot is **(a)**, and it is simply correct: the feature does not reach
the user. The answer is that it is a one-line fix at `MSX1.sv:325`, not a design flaw
— every layer beneath it is right — but the change is not "the three translations can
now save" until that line lands and someone confirms the `.sav` mounts writable.

A critic may also press **(c)** / **(d)** as genuine divergences from the openMSX
reference. They are; conceded rather than defended. Each mitigation is one added term.

---

## Disposition

The Yamanooto mapper logic itself (`yamanooto.sv:210-256`) is correct, well-gated,
matches the openMSX reference on every gate that governs programming, is built on the
hardware-proven ASCII16X pattern, and is covered by a test with a working negative
control. The `msx_slots.sv` refactor provably preserves ASCII16X and MFRSD. **Ship
that part.**

Two things stand between this and ready:

1. The `flash.sv` sector-decode hunk — needs MFRSD hardware evidence, or its own
   commit so it can be reverted independently.
2. The missing `MSX1.sv:325` menumask term — needs one line.
