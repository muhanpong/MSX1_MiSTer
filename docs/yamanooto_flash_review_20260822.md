# Yamanooto flash write path — neutral review

| | |
|---|---|
| **Reviewer (agent name)** | `neutral` — the neutral seat of a three-perspective review (FOR / AGAINST / NEUTRAL) |
| **Model** | Claude Opus 5 (`claude-opus-5`) |
| **Session** | `session_017iGt6BRvjjQbw93gcpTM8y` |
| **Agent scratch UUID** | `0e07ce08-0d62-408c-a5ff-91ad83c4b04b` |
| **Date** | 2026-08-22 |
| **Branch** | `moonsound_ascii16x` (uncommitted working tree) |
| **Mandate** | Independent verification against primary sources; no prior position. Repo read-only — no edits, no commits, no `git checkout`/`stash`. Scratch in `/tmp/yfchk`. |

> The `neutral` agent had no real `a…-…` agent id exposed to it. The two identifiers above are
> the ones it actually held (harness session id and its scratchpad UUID); no id was invented.

**Scope.** Primary: `rtl/peripheral/slots/{yamanooto,msx_slots,flash}.sv`, `sim/tb_yamanooto_flash.sv`.
Secondary: OPL4 gain recalibration in `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv`,
`MSX1.sv`, `rtl/msx.sv`, `sim/tb_opl4_gain.sv`, `sim/check_opl4_gain_consts.py`.

**Reference sources.** openMSX master `@2712dbd1c8b45f862035b92314910e2f3c5ec6ae`
(`src/memory/Yamanooto.cc`, `src/memory/AmdFlash.cc`), Verilator 5.050.

**Verdict.** Two defects, both introduced by this diff, both confirmed by *simulating the real
RTL* rather than by inspection. Everything else asked about checks out.

---

## Summary table

| # | Finding | Severity | Confidence |
|---|---|---|---|
| F1 | `flash_rq` has no WREN term → flash command FSM reachable with WREN clear | **blocker** | high |
| F2 | Uniform-sector erase below 64KB targets the wrong sector | should-fix | high (arithmetic) |
| F3 | Unlock addressing `#4AAA`/`#4555` — bit-equivalent to openMSX | non-issue | high |
| F4 | `#12` = `WREN\|SPIEN`, REGEN clear — claim correct | non-issue | high |
| F5 | Program-data SDRAM address path is the Yamanooto's own banked address | non-issue | high |
| F6 | Erase offset latched one cycle late — 1-cycle margin | minor (pre-existing) | high |
| F7 | `own_flash_rq` is bit-identical for ASCII16X and MFRSD | non-issue | high |
| F8 | `flash16x_active` extension also enables `.sav` LOAD | scope flag | high |
| F9 | Testbench honesty: real RTL, exit code propagates, negative control works | good, with a coverage gap | high |
| F10 | Four openMSX divergences, all pre-existing | minor | high |
| F11 | OPL4 gain arithmetic verified; two nits | minor | high |

---

## F1 — BLOCKER. `yamanooto.sv:256`: `flash_rq` carries no WREN term

```systemverilog
assign flash_rq  = cs & page_ok & ~romdis & ~scc_req & ~reg_rd;   // yamanooto.sv:256
```

This drives `flash.ce` (`msx_slots.sv:233`) while `flash.we` is the unqualified
`cpu_mreq & cpu_wr` (`msx_slots.sv:231`). So **every** Yamanooto write in `0x4000-0xBFFF`
reaches `flash.sv`'s shared command FSM with WREN clear — which openMSX
(`Yamanooto.cc:235-240`, flash writes live inside `if (enableReg & WREN)`) and real hardware
both block.

### The fact that settles the FOR/AGAINST split

The cart's own JEDEC FSM **is** correctly gated: `cart_wr` (`yamanooto.sv:210`) requires
`flash_wr_en`. That is a *different FSM* from the one that reaches silicon. "`cart_wr` requires
WREN, so the gate is correct" is true of `yamanooto.sv`'s FSM and false of the shared
`flash.sv` FSM. Only one of the two is gated.

### Evidence (VERIFIED — real RTL, wired exactly as `msx_slots.sv` wires it)

Harness `/tmp/yfchk/tb_cfi.sv`, instantiating `cart_yamanooto` + `flash`:

```
WREN=0  cfi_state=0 (baseline)
   read 4100 -> flash dout=ff data_valid=0
-- single Konami-SCC style bank write: LD (0x50AA),A  with A=0x98 --
after that ONE write: WREN=0 cfi_state=1
   read 4100 -> flash dout=00 data_valid=1     <-- entire 8MB ROM window now reads 0x00
   read 4020 -> flash dout=51 ('Q')
   read 4022 -> flash dout=52 ('R')
   read 4024 -> flash dout=59 ('Y')
```

Harness `/tmp/yfchk/tb_wren.sv`, WREN never set at any point:

```
A) after AA/55/90 with WREN=0 : flash.state=1 data_valid=1 dout=01
      -> autoselect wedge: all ROM reads return the manufacturer id
B) after AA/55/80/AA/55/30 with WREN=0 : erase=1 sdram_addr=0400000 sdram_din=ff
      -> a real 64KB 0xFF fill of SDRAM, with WREN never set
```

### Why the trigger is not contrived

`flash.sv:95` enters CFI on `amd_family & din == 8'h98 & addr[11:1] == 11'h055` — i.e. **any**
write of byte `0x98` to one of 16 CPU addresses
`{0x40AA, 0x40AB, 0x50AA, 0x50AB, …, 0xB0AA, 0xB0AB}`.

* `0x50AA` is a *legitimate* K5 bank-register address: `0x50AA & 0x1800 == 0x1000` (openMSX
  `Yamanooto.cc:263`) and `cpu_addr[12:11] == 2'b10` (`yamanooto.sv:138`) — both decoders agree.
* `0x98` = segment 152, an ordinary segment number inside an 8MB multi-ROM.
* `amd_family` is 1 for Yamanooto **only because of this diff** (`msx_slots.sv:215,239`).
  Before it, Yamanooto never drove `flash.ce` at all, so the exposure did not exist.

### Aggravating factor

`flash.sv` has **no reset port** (module header, `flash.sv:1-23`). `state` and `cfi_state` are
cleared only by a `0xF0` write (`flash.sv:96,112`). A wedged cart does **not** recover on an
MSX reset — only on a stray `0xF0` or a core reload.

### Fix

One line, verified sufficient against all three demonstrations above:

```systemverilog
assign flash_rq = cs & page_ok & ~romdis & ~scc_req & ~reg_rd & (cpu_rd | flash_wr_en);
```

Programming still works (`cpu_rd=0, flash_wr_en=1`); status / ID / CFI polling still works
(`cpu_rd=1`); ordinary ROM reads are unaffected (`state=0` → `dout=0xFF`, `data_valid=0`).
`cpu_rd` is already a port of the module (`yamanooto.sv:40`).

---

## F2 — SHOULD-FIX. `flash.sv:83`: uniform-sector erase below 64KB hits the wrong sector

```systemverilog
erase_block_num <= (addr > 23'hFFFF ? {1'b0,addr[22:16]} : {5'd0,addr[15:13]});  // :83
wire [26:0] erase_base = erase_boot ? (27'(erase_block_num) << 13)
                                    : (27'(erase_block_num) << 16);             // :63
```

The low-64KB branch (`addr[15:13]`, values 0..7) is meaningful **only** for the bottom-boot 8KB
map. It is taken regardless of `boot_sector`, and with `boot_sector = 0` the result is then
scaled `<< 16`. Every erase confirmed in `0x02000-0x0FFFF` therefore fills
`0x10000 … 0x70000`.

### Evidence (VERIFIED — `/tmp/yfchk/tb_flashsec.sv` against real `flash.sv`)

```
CASE1 addr=0x008000 -> sdram_addr=0440000 (offset=0400000) => sector base 0040000
CASE2 addr=0x148000 -> sector base 0140000 (expect 140000)     <-- >=64KB path is correct
```

`0x8000` must erase sector `0x00000`; it erases `0x40000`. A confirm at `0x2000` computes
`erase_block_num = 1` → `erase_base = 0x10000`. Only `addr < 0x2000` is correct.

The diff's own rationale (`flash.sv:16-20`) — *"giving it the 8KB boot-sector map would erase
the wrong span in the low 64KB"* — identified the right hazard, but the `amd_family` /
`boot_sector` split does not close it: with `boot_sector = 0` the low-64KB branch is still
**taken**, merely mis-scaled.

### Fix, and the fair objection to it

```systemverilog
erase_block_num <= (boot_sector & ~(addr > 23'hFFFF)) ? {5'd0,addr[15:13]}
                                                      : {1'b0,addr[22:16]};
```

This also changes MFRSD (`boot_sector = 0`), whose low-64KB erase currently lands on
`0..7 << 16` and would become `0x00000`. Both behaviours are untested. If MFRSD regression
risk is unacceptable, gate the new form on `amd_family & ~boot_sector` instead.

Confidence: high on the arithmetic; **medium on real-world reachability** — it depends on where
in the 8MB chip the Celica saves live, which could not be determined (see *Open questions*).

---

## F3 — VERIFIED CORRECT. Unlock addressing `#4AAA` / `#4555`

`yamanooto.sv:211-212` tests `cpu_addr[11:1] == 11'h555` / `11'h2AA`.

* `0x4AAA & 0xFFF = 0xAAA`, `>>1 = 0x555` ✓
* `0x4555 & 0xFFF = 0x555`, `>>1 = 0x2AA` ✓

**Bank-independence proof.** openMSX masks the *full flash* address, not the CPU address:
`AmdFlash.cc:1027-1028` computes `addr = cmd[i].addr >> 1` for an x8x16 part, then compares
`(addr & 0x7FF)` against `{0x555, 0x2aa}`. Here the flash byte address is
`(bank << 13) | cpu_addr[12:0]` (`yamanooto.sv:192`), so the native address is
`(bank << 12) | cpu_addr[12:1]`, and `& 0x7FF` cancels the bank term **exactly**, leaving
`cpu_addr[11:1]`.

The RTL is therefore bit-equivalent to openMSX for *every* bank value — not an approximation
that happens to work for bank 0. CFI entry uses the same convention on both sides
(`AmdFlash.cc:625-626` vs `flash.sv:95`), which is precisely what makes F1 reachable.

---

## F4 — VERIFIED CORRECT. `#12` semantics

`0x12 = 0b0001_0010` = `WREN` (bit 4, `yamanooto.sv:62`) | `SPIEN` (bit 1, `:63`).
`REGEN` (bit 0, `:61`) is **clear**. openMSX agrees on the bit values (`Yamanooto.cc:21-22`)
and `writeMem()` requires only `enableReg & WREN` to reach `flash.write()` (`:235-240`) — REGEN
is not involved.

The diff's comment (`yamanooto.sv:203-209`) and TODO correction #3 are **right**; the older
"REGEN+WREN" wording was wrong.

Consequence worth recording: with REGEN clear the game cannot write CFGR/OFFR, so ROMDIS, K4
and MDIS all stay 0, and bank writes are suppressed while WREN is set (`bank_hit`,
`yamanooto.sv:140`). A game must therefore clear WREN via ENAR — always writable — to switch
bank, then set it again. That matches openMSX exactly.

**NOT verified:** that the Celica ROMs actually write `#12` to `#7FFF`. No ROM, disassembly or
trace exists in the repo (`grep -rn "Celica\|4AAA" docs/` returns only `TODO_yamanooto.md`
itself). Treat as inferred.

---

## F5 — VERIFIED CORRECT. Program-data SDRAM address path

During a `prog_we` cycle:

* `mapper_yamanooto_unmaped = 0` (`yamanooto.sv:186-187`): `~page_ok`=0, `romdis`=0,
  `reg_rd`=0 on a write, and the `cpu_wr & cpu_mreq & ~flash_wr_en` term is 0 because WREN is set.
* `flash_rq` / `data_valid` = 0 because `flash.sv:57` gates on `~we`.
* Every other `*_unmaped` is `cs`-gated (all 10 `assign mem_unmaped` sites in
  `rtl/peripheral/slots/` checked) and `cs` is one-hot on `mapper`.

Therefore `mem_unmaped = 0` → `mapper_addr = mapper_yamanooto_addr` (`msx_slots.sv:141`), **not**
`27'hDEAD`, and `ram_addr = base_ram + mem_addr` (`:125`) — the Yamanooto's own banked address
inside its own SDRAM region. `sdram_ce` / `ram_rnw` are forced past the region's read-only flag
by `mapper_yamanooto_prog_we` (`:162,164`).

**Bounds.** `mem_addr` is `{2'd0, 10-bit bank, cpu_addr[12:0]}` ≤ 8MB−1, and
`memory_upload.sv:238` pads every `MAPPER_YAMANOOTO` image to a full `25'h800000`, so
`size << 14` = 8MB and a program write can never leave the region.

> Note for the future: without that padding there would be **no** program-side bounds clamp —
> the `erase_limit` clamp covers erase only. Worth a comment in the source; not a bug today.

`23'(mem_addr)` truncation is lossless (top two bits are literal `2'd0`).
`flash16x_prog_addr` (`msx_slots.sv:73-75`) is cart-relative and matches `flash_dirtysave`'s
`in_bounds` expectation (`flash_changelog.sv:72`-style check).

---

## F6 — MINOR (pre-existing structure, newly load-bearing). Erase offset latched one cycle late

`erase_block` is a **registered** pulse (`flash.sv:83`); the block that samples the
*combinational* `sdram_offset` and `erase_limit` runs on the next clock edge
(`flash.sv:161-176`). Measured margin (`/tmp/yfchk/tb_narrow.sv`, bus deliberately switched to a
foreign cart immediately after the strobe):

```
strobe=1 clk : erase=1 sdram_addr=7000000 (correct=0400000)   <-- stale/foreign offset
strobe=2 clk : erase=1 sdram_addr=0400000
strobe=3 clk : erase=1 sdram_addr=0400000
```

Safe in practice — the CPU write strobe is ≥2 `clk21m` cycles even at the 10.7 MHz turbo
setting — but the margin is exactly one cycle.

**Substantive answer to the erase-bounds question:** yes, `sdram_offset` and `erase_limit` are
the Yamanooto's own values at that instant (`ce` requires `cs`, so `base_ram` is the addressed
cart's), and no, the multi-cycle 0xFF fill **cannot** drift if the CPU accesses a different cart
mid-erase — `sdram_addr` is fully registered and self-increments (`flash.sv:152`).

---

## F7 — VERIFIED NON-ISSUE. `own_flash_rq` is bit-identical for ASCII16X and MFRSD

Old flag: `is_ascii16x = A & ~M0 & ~M3`, used for three unrelated things —
(a) manufacturer id, (b) CFI enable, (c) boot-sector erase map.

| new signal | expression | vs. old |
|---|---|---|
| `boot_sector` (`msx_slots.sv:242`) | `A & ~M0 & ~M3` | character-for-character identical |
| `amd_family` (`:239`) | `own_flash_rq = (A\|Y) & ~M0 & ~M3` | differs only when `Y=1` |
| `erase_limit` (`:245`) | `own_flash_rq ? size<<14 : 0x800000` | differs only when `Y=1` |
| `sdram_offset` (`:237`) | `(A\|Y) ? base_ram : mfrsd_base_ram[0]` | differs only when `Y=1` |

`A` requires `mapper == MAPPER_ASCII16X` (`msx_slots.sv:383`); `Y` requires
`mapper == MAPPER_YAMANOOTO` (`:406`). `mapper` holds one value per cycle, so `A & Y` is
unreachable. MFRSD is likewise excluded: `M0` requires `device == DEVICE_MFRSD0`, which
`memory_upload.sv:649` only ever emits together with `MAPPER_NONE`; `M3` requires
`mapper == MAPPER_MFRSD3`.

**For every reachable combination, ASCII16X and MFRSD behaviour is unchanged.** The only new
coupling is the pre-existing shared-FSM / shared-`erase`-state issue, unchanged in kind.

Regression run: `sim/run_yamanooto.sh` → `RESULT: 47 passed, 0 failed`.

---

## F8 — SCOPE FLAG. `flash16x_active` extension also enables `.sav` LOAD

`msx_slots.sv:547` extends `flash16x_active` to `MAPPER_YAMANOOTO`. That signal is **live**, not
dead: `flash_dirtysave` (`MSX1.sv:1005-1033`) gates SAVE (`status[38]`) **and LOAD**
(`status[39] | load_sram`) on it. So this diff also lets an OSD LOAD DMA a `.sav` over the
Yamanooto's 8MB SDRAM region.

Probably intended — `docs/TODO_yamanooto.md` says so — but it is a second user-visible behaviour
beyond "flash writes work". Only slot A is wired (`flash16x_active[0]`), which the TODO
correctly discloses.

---

## F9 — Testbench honesty

| | `sim/tb_yamanooto_flash.sv` | `sim/tb_opl4_gain.sv` |
|---|---|---|
| Instantiates real RTL? | **Yes** — `cart_yamanooto` (`:34`) | **No** — re-implements the gain tables and both pipeline stages (`:29`, `:87`); header discloses this |
| Failure reaches exit code? | **Yes** — `$fatal(1,…)` (`:179`) | **Yes** — `$fatal(1,…)` (`:267`), with an explicit comment about the `$finish(1)` trap |
| Negative control genuinely fails? | **Yes** | **Yes** |

### Measured

```
$ sim/run_yamanooto_flash.sh
tb_yamanooto_flash: 17 checks, 0 errors
rc=0

$ NEGCTL=1 sim/run_yamanooto_flash.sh
FAIL: Y1 WREN clear must block programming
FAIL: Y4 ROMDIS must block programming
negative control OK: 2/17 checks failed as required
rc=0            # correct — the TB's own $fatal guard fires only if the inversion PASSED

$ sim/run_opl4_gain.sh
check_opl4_gain_consts: OK
tb_opl4_gain: 21202 checks, 0 errors
rc=0

$ NEGCTL=1 sim/run_opl4_gain.sh
negative control OK: 10/21202 checks failed as required
rc=0
```

Exit-code propagation verified empirically by injecting a real failure into a `/tmp` copy of the
Yamanooto TB:

```
FAIL: Y3 INJECTED FAILURE
tb_yamanooto_flash: 17 checks, 1 errors
%Fatal: tb_yamanooto_flash: 1 of 17 checks FAILED
EXIT=1
```

### The `$finish(1)` defect

The known repo-wide issue — Verilator leaves the exit code at 0 for `$finish` even with an
argument — does **not** affect the two new suites. It **does** silently mask failures in:

`sim/tb_mfrsd_sccmode.sv:136,143` · `sim/tb_ms_trim.sv:109,116` · `sim/tb_turbo_guard.sv:378` ·
`sim/tb_turbo_clock.sv:175` · `sim/tb_turbo_slowdev.sv:359` · `sim/tb_fdc_edge.sv:287`

(`sim/tb_yamanooto.sv:292`, `sim/tb_sccdetect.sv`, `sim/tb_sccplus.sv` end on a bare `$finish`.)

### The coverage gap that matters

`tb_yamanooto_flash.sv` instantiates **only** `cart_yamanooto`. Nothing in `sim/` exercises
`flash.sv` with the new flags, the `msx_slots.sv` mux wiring, or the SDRAM program/erase address
path — which is exactly where F1 and F2 live. Both were caught by two ~40-line integration
benches (`/tmp/yfchk/tb_cfi.sv`, `/tmp/yfchk/tb_flashsec.sv`). Promoting those into `sim/` would
close the gap cheaply.

---

## F10 — openMSX divergences found while verifying, all pre-existing

1. **ENAR write self-injection.** openMSX updates `enableReg` first and then falls through with
   no `return` (`Yamanooto.cc:197-240`), so the write that *sets* WREN is itself injected into
   the command stream. Our RTL uses the pre-write value in `cart_wr` (`yamanooto.sv:210`), so the
   setting write is not injected and the clearing write is. `0x7FFF[11:1] = 0x7FF` matches no
   unlock offset either way → no functional difference. Already recorded at
   `docs/yamanooto_spec.md:122`, listed as an open question at `:146`.
2. **SCC-window writes while WREN is set.** openMSX routes them to the **flash** (they sit in the
   `if (WREN)` branch, `Yamanooto.cc:235-259`); our `scc_req` (`yamanooto.sv:127`) ignores
   `flash_wr_en`, so they hit the SCC and are excluded from `flash_rq`. Requires
   `rawBank[2][5:0] == 0x3F` concurrent with programming — not a realistic sequence.
3. **Address mirroring.** openMSX mirrors `<0x4000` / `>=0xC000` into the window
   (`Yamanooto.cc:127-135`); `page_ok` does not. Pre-existing, unchanged by this diff.
4. **`CFGR` read is missing `FPGA_WAIT`.** openMSX returns `configReg | 0x80` for a not-busy poll
   (`Yamanooto.cc:152`); `yamanooto.sv:99` returns bare `cfgr`. Pre-existing (`cart_dout` is
   untouched here) — but note the comment at `yamanooto.sv:105-107` places that busy-poll at
   `0x7FFE`, whereas openMSX puts it at `0x7FFD`. Worth a separate look.

**Also VERIFIED, in support of the diff's rationale:** `flash.sv`'s `0xA0` byte-program branch
really is structurally dead. `flash.sv:178` guards on `(quadrupleProgram | write_cnt > 0)`, and
the `write_cnt <= 1` for `bytePrgram` (`:189`) can only execute from *inside* that guard.
TODO correction #1 is correct.

---

## F11 — OPL4 gain recalibration

### Verified against primary sources

* `pcm_pre()` maps onto the engine's **right** shift: `sh = 2'd3 - pcm_vol` then
  `accum_l >>> sh` (`rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv:459-460`)
  — attenuation, as the comment claims. `ymf278_pcm_engine2.sv` is the synthesized engine
  (`rtl/sound/sound.qip:49`); the misleading *"+6..+24 dB"* comment lives in the **unbuilt**
  `ymf278_pcm_engine.sv:1292`.
* Every table entry reproduces its stated dB within 0.03 dB (recomputed independently; the
  shipped `check_opl4_gain_consts.py` agrees).
* Overflow comment is correct. `opl3_l_eff` is `signed [16:0]` (`ymf278b_top.sv:412`), so
  worst-case `|sum|` after `>>>7` is `103936 + 41472 = 145408` → 18 magnitude bits + sign;
  `sum_l` is `signed [21:0]` (`:387`) and `fm_l_mul` is `signed [29:0]` (`:386`) against a max
  product of `65536 × 203 = 13,303,808`. No overflow.
* `status` is `[63:0]` (`MSX1.sv:210`), so `[59:57]` fits. No other writer of 54-59 and no
  remaining reader of 49-53. Moving the bits means a stale `.cfg` lands on the new defaults
  rather than a mis-scaled old value — the right call, worth stating explicitly in the commit.

### Two nits

1. **The two menus use different anchors.** PCM label X = net X−8 dB; FM label X = net X−4 dB.
   So PCM "0dB" and FM "0dB" are not the same absolute level, and the PCM default is the entry
   labelled **"-4dB"** while the FM default is labelled **"0dB"**. Both defaults are menu entry 0
   (correct for MiSTer), but the OSD gives the user no way to tell.
2. **The consts check is not tied to the engine.** `sim/check_opl4_gain_consts.py:53` hardcodes
   `sh = 3 - pre[s]` rather than reading it from `ymf278_pcm_engine2.sv:459`. Since
   `tb_opl4_gain.sv` copies the datapath instead of instantiating `ymf278b_top`, that script is
   the *only* tie between the test and the shipped RTL — and a change to that engine line would
   leave both scripts green with the calibration silently invalid.

---

## Open questions — not determinable without hardware or missing artefacts

1. **Whether the Celica ROMs write `#12` to `#7FFF`, and where in the 8MB chip they erase.**
   No ROM, trace or disassembly in the repo. This decides F2's real severity: if the save
   sectors sit at or above 64KB, F2 is latent; below 64KB it corrupts on the first save.
2. **The real-world firing rate of F1.** Reachability is proven and a concrete plausible trigger
   given, but the rate across an 8MB multi-ROM cannot be bounded without running one.
3. **Whether HPS auto-mounts `<rom>.sav` for a Yamanooto ROM** — the TODO's own open item; mount
   policy is host-side.
4. **Fit / timing.** Nothing was synthesized. Given this repo's history of `SDRAM_DQ` IOB packing
   breaking on combinational growth, `own_flash_rq` and the widened `.addr` mux deserve a fit
   check before any hardware conclusion is drawn.
5. **Real-cartridge behaviour of a JEDEC sequence issued with WREN clear** — compared against
   openMSX and the S29GL064 write-enable model, not against silicon.

---

## Reproduction

Scratch benches used for the two defect proofs (not committed; `/tmp` is session-local):

| file | proves |
|---|---|
| `/tmp/yfchk/tb_cfi.sv` | F1 — one bank write wedges CFI mode |
| `/tmp/yfchk/tb_wren.sv` | F1 — autoselect wedge and spurious erase with WREN clear |
| `/tmp/yfchk/tb_flashsec.sv` | F2 — erase sector arithmetic |
| `/tmp/yfchk/tb_narrow.sv` | F6 — erase offset latch timing margin |

Each builds with:

```
verilator --binary --timing -Wno-fatal --top-module <tb> -o <out> -Mdir <dir> \
   rtl/package.sv rtl/peripheral/slots/yamanooto.sv rtl/peripheral/slots/flash.sv <tb>.sv
```

Recommended follow-up: promote `tb_cfi.sv` and `tb_flashsec.sv` into `sim/` as
`tb_yamanooto_flash_integration.sv` so the `flash.sv` + `msx_slots.sv` seam is covered by CI.
