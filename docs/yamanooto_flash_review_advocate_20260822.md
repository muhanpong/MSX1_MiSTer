# Yamanooto flash-write path — ADVOCATE review

| | |
|---|---|
| **Reviewer role** | Advocate (one of three perspectives: advocate / opponent / neutral) |
| **Agent name** | `advocate` |
| **Agent / session id** | `0e07ce08-0d62-408c-a5ff-91ad83c4b04b` (session `session_017iGt6BRvjjQbw93gcpTM8y`) |
| **Date** | 2026-08-22 |
| **Subject** | Uncommitted working tree, branch `moonsound_ascii16x` |
| **Primary scope** | `rtl/peripheral/slots/yamanooto.sv`, `msx_slots.sv`, `flash.sv`, `sim/tb_yamanooto_flash.sv`, `sim/run_yamanooto_flash.sh` |
| **Secondary scope** | OPL4 gain recalibration: `ymf278b_top.sv`, `MSX1.sv`, `rtl/msx.sv`, `sim/tb_opl4_gain.sv` |

Brief: build the strongest **honest** case that the change is correct and ready to
ship, and state plainly where that case cannot be built. The repository was not
modified during the review itself; mutation-test artifacts went to `/tmp/adv_mut/`
only. This document was added afterwards at the user's explicit request.

**Verdict: the core mechanism is correct and well evidenced. Ship after two
one-line fixes, neither of which touches the shared flash command FSM.**

Claims below are marked VERIFIED (code read / tool run) or INFERRED.

---

## 1. Case for shipping

### 1.1 The JEDEC unlock offsets are exactly right, not approximately — VERIFIED

`yamanooto.sv:211-212` tests `cpu_addr[11:1] == 11'h555` / `11'h2AA`.

openMSX `AmdFlash.cc:1019-1030` (`partialMatch`) uses `addrSeq = {0,1,0,0,1}` and
`cmdAddr = {0x555, 0x2aa}`, and for an `x8x16` device computes
`(cmd[i].addr >> 1) & 0x7FF`. `S29GL064N90TFI04` is declared
`DeviceInterface::x8x16` in `AmdFlash.hh`. Since `Yamanooto.cc:120-126`
`getFlashAddr()` returns `(bank << 13) | (addr & 0x1FFF)`, the low 13 bits are the
raw CPU address, so `(flash_addr >> 1) & 0x7FF` is **identically** `cpu_addr[11:1]`.

The CPU-address test in the RTL is arithmetically equivalent to openMSX's
flash-address test — this is an equality, not an approximation.

Command bytes match too: program `{0xaa,0x55,0xa0}` (`AmdFlash.cc:867`), erase
`{0xaa,0x55,0x80,0xaa,0x55}` + `0x30` (`AmdFlash.cc:671-676`), against
`yamanooto.sv:232-245`. Abort semantics are equivalent: openMSX `cmd.clear()` on
mismatch (`AmdFlash.cc:520`) vs. the RTL's fall to `J_IDLE` with `AA@555`
restart-in-place — after a `clear()` a following `AA@555` likewise starts a fresh
match.

### 1.2 Gating matches `writeMem()` line for line — VERIFIED (full read)

`Yamanooto.cc:190-282` read in full, including the tail. Structure:

```cpp
if (enableReg & WREN) {
    if (!(configReg & ROMDIS)) flash.write(getFlashAddr(address), value, time);
} else {
    // K4 bank / isSCCAccess -> scc.writeMem / Konami-SCC bank / SCC mode register
}
```

Every SCC, bank and mode path lives in the `else`. **With WREN set, even a write
into the SCC window goes to `flash.write()`.**

RTL equivalents:
- `cart_wr = cs & cpu_mreq & cpu_wr & page_ok & flash_wr_en & ~romdis` — `yamanooto.sv:210`
- registers `0x7FFC-0x7FFF` handled first, ENAR unconditional, CFGR/OFFR behind REGEN — `yamanooto.sv:159-165`
- `bank_hit` carries `& ~flash_wr_en` — `yamanooto.sv:140`
- `modereg_hit` carries `& ~flash_wr_en` — `yamanooto.sv:143`

Reading the tail is what makes this a strong claim rather than a guess: there is
no bank or SCC path in openMSX that survives WREN, so the RTL's blanket
suppression is **exact**, not merely conservative. The RTL mode-register decode
`cpu_addr[15:1] == 15'h5FFF` equals openMSX's `(address & 0xFFFE) == 0xBFFE`
(`Yamanooto.cc:274`).

### 1.3 The data byte reaches SDRAM past the read-only flag — VERIFIED by path trace

`prog_we` (`yamanooto.sv:252`) → `mapper_yamanooto_prog_we` →

- `msx_slots.sv:162` — `sdram_ce`
- `msx_slots.sv:164` — `ram_rnw`
- `msx_slots.sv:73-75` — `flash16x_prog_we` / `flash16x_prog_addr`

In both `sdram_ce` and `ram_rnw` the term sits **outside** the
`~mem_unmaped & ~ram_ro` conjunction. That is the mechanism that defeats the
region's read-only flag.

The address is `ram_addr = base_ram + mapper_addr` (`msx_slots.sv:124-125`,
selector at `:145`). The module-level `mem_unmaped` (`msx_slots.sv:168-180`) is
provably 0 during the program write:

- the cart's own `mem_unmaped` (`yamanooto.sv:186-187`) has its
  `(cpu_wr & cpu_mreq & ~flash_wr_en)` term killed by WREN;
- `flash_rq` there is `flash.sv:57` `data_valid = ce & ~we & (...)`, zero because
  `we` is high;
- every other mapper's `*_unmaped` is zero because their `cs` is `mapper == ...`
  (`msx_slots.sv:383` vs `:406`), and the mappers are mutually exclusive.

### 1.4 Program and erase are bounded, by two independent mechanisms — VERIFIED

1. The bank register is 10 bits masked `& 10'h3FF` (`yamanooto.sv:168`) and
   concatenated as `{2'd0, bank, cpu_addr[12:0]}` (`yamanooto.sv:192`), so
   `mem_addr < 8MB` unconditionally — matching openMSX's `bankRegs[page8kB] & 0x3ff`.
2. `memory_upload.sv:238-240` pads **every** `MAPPER_YAMANOOTO` cart to a full
   `25'h800000` region, so `lookup_RAM[].size` is always 512 (16KB units) and
   `erase_limit = 27'(size) << 14 = 8MB` (`msx_slots.sv:245`).

Mechanism (2) is what makes it safe that `yamanooto.sv:186` has **no** size test at
all, unlike `ascii16x.sv:105`. Even a 512KB user ROM loaded as Yamanooto gets an
8MB region, so a program write to a high bank cannot leave it.

The erase clamp itself (`flash.sv:161-176`) is untouched: it skips a sector
starting past the region and truncates a straddling one. Worst case is block 127
→ `0x7F0000 + 0xFFFF = 0x7FFFFF`, inside the region.

### 1.5 `own_flash_rq` is a faithful refactor — VERIFIED against all three replaced expressions

| Pre-diff | Post-diff | Effect |
|---|---|---|
| `.is_ascii16x(ascii16x & ~mfrsd0 & ~mfrsd3)` | `.boot_sector(ascii16x & ~mfrsd0 & ~mfrsd3)` — `msx_slots.sv:242` | **character-for-character identical**; ASCII16X erase map bit-identical |
| same flag | `.amd_family(own_flash_rq)` — `msx_slots.sv:239` | Yamanooto newly reports AMD id `0x01` + CFI; MFRSD still `0x20`, no CFI (`flash.sv:52,95`) |
| `.erase_limit(ascii16x & ~mfrsd0 & ~mfrsd3 ? size<<14 : 27'h800000)` | `.erase_limit(own_flash_rq ? size<<14 : 27'h800000)` — `msx_slots.sv:245` | ASCII16X and MFRSD unchanged; Yamanooto gains the clamp instead of the 8MB fallthrough |
| `.sdram_offset(ascii16x ? base_ram : mfrsd_base_ram[0])` | `.sdram_offset((ascii16x \| yamanooto) ? base_ram : mfrsd_base_ram[0])` — `msx_slots.sv:237` | still lacks the `~mfrsd0 & ~mfrsd3` guard — **inherited unchanged**, not introduced; unreachable because `mapper` and `device` come from the same `slot_layout[layout_id]` |

The Yamanooto term is **last** in the `.addr` priority mux (`msx_slots.sv:221-225`),
below both MFRSD paths, so no MFRSD cycle can be re-steered.

### 1.6 The shared `flash.sv` command FSM was deliberately left alone — VERIFIED

The only `flash.sv` edits are the two flag renames plus comments. The dead `0xA0`
branch is real: `flash.sv:178` guards on `(quadrupleProgram | write_cnt > 0)`,
while `bytePrgram`'s `write_cnt <= 1` (`flash.sv:189`) can only execute from inside
the very block it is trying to enter. Given this project's history of a broad
`flash.sv` change reverted for boot failure, routing around it rather than through
it is the correct call.

### 1.7 The testbench proves what it claims, and failures reach the exit code — VERIFIED by mutation

`tb_yamanooto_flash.sv:34-42` instantiates the real `cart_yamanooto`;
`run_yamanooto_flash.sh:11-13` compiles the real
`rtl/peripheral/slots/yamanooto.sv`.

I did not trust the exit code — I mutated it. Copied the RTL to `/tmp/adv_mut`,
forced `assign prog_we = 1'b0;`, rebuilt:

```
FAIL: Y2 program armed with WREN set
tb_yamanooto_flash: 17 checks, 1 errors
%Fatal: tb_yamanooto_flash.sv:176: Assertion failed ...
MUTANT rc=1
```

The script's `rc=${PIPESTATUS[0]}` correctly takes the simulator's status, not
`grep`'s.

### 1.8 Tests run — VERIFIED

| Suite | Result |
|---|---|
| `sim/run_yamanooto_flash.sh` | `tb_yamanooto_flash: 17 checks, 0 errors` / `rc=0` |
| `NEGCTL=1 sim/run_yamanooto_flash.sh` | Y1 + Y4 fail as designed; `negative control OK: 2/17 checks failed as required` |
| `sim/run_yamanooto.sh` | 47 passed, 0 failed |
| `sim/run_sccplus.sh` | 45/45 **plus `GOLDEN: IDENTICAL (51737 samples)`** vs HEAD's RTL |
| `sim/run_sccdetect.sh` | 53 passed, 0 failed |
| `sim/run_mfrsd_sccmode.sh` | 9 checks, 0 errors |
| `sim/run_opl4_gain.sh` | 21202 checks, 0 errors (+ constants check) |
| `NEGCTL=1 sim/run_opl4_gain.sh` | 10 checks fail as designed |
| `verilator --lint-only -Wall` on `rtl/peripheral/slots/*.sv` | zero warnings on `yamanooto.sv`, `flash.sv`, `msx_slots.sv` beyond a cosmetic `DECLFILENAME` |

### 1.9 OPL4 gain recalibration — VERIFIED

`run_opl4_gain.sh:13-18` runs `sim/check_opl4_gain_consts.py` **before** the TB.
That ordering matters: the TB models the datapath rather than instantiating
`ymf278b_top`, so it cannot see a table-only edit — the Python check closes exactly
that gap.

Both menus are internally consistent relative scales. Splitting PCM gain into an
engine pre-shift plus a post multiply is the right fix for a path that saturates
internally (`ymf278b_top.sv:221`) — a post-saturation trim can only make clipping
quieter, never undo it. `status` is `[63:0]` (`MSX1.sv:210`); bits 54-59 are free,
the only other high bit in use is `O[51]` (`MSX1.sv:280`).

---

## 2. Where the case is weak or unprovable

### W1 — `boot_sector = 0` for Yamanooto is wrong. This is the one I cannot defend. VERIFIED

`msx_slots.sv:240-241` justifies the value with:

> "Yamanooto's S29GL064 is uniform 64KB, so it must NOT take the boot-sector map."

That is false. Three independent sources:

1. openMSX `AmdFlash.hh`, `S29GL064N90TFI04` — the exact part `Yamanooto.cc:38`
   instantiates: `geometry{ x8x16, {{.count=8,.size=0x2000},{.count=127,.size=0x10000}}, 1 }`,
   with `.bootBlockFlag = 0x02` (bottom boot). `AmdFlash.cc` `getSectorIndex()`
   walks `regions` from address 0, so those eight 8KB sectors sit at
   `0x000000-0x00FFFF`.
2. `M29W640GB` in the same table — the ASCII16X's chip — has the **identical**
   geometry `{8×0x2000, 127×0x10000}`. The two chips differ only in manufacturer
   id (`AMD` vs `STM`), which is exactly the `amd_family` half. The sector-map half
   of the split has no basis in the reference.
3. **This repository's own spec**, `docs/yamanooto_spec.md:138`:
   "openMSX는 `S29GL064N90TFI04` 8MB(**8KB×8 + 64KB×127**), 전 섹터 쓰기 가능."

The consequence is worse than coarse granularity, because the block-number
arithmetic is coupled to the flag (`flash.sv:63,83`):

```verilog
erase_boot      <= boot_sector & ~(addr > 23'hFFFF);
erase_block_num <= (addr > 23'hFFFF ? {1'b0,addr[22:16]} : {5'd0,addr[15:13]});
erase_base       = erase_boot ? (erase_block_num << 13) : (erase_block_num << 16);
```

With `boot_sector = 0` the block number still comes from `addr[15:13]` but is
shifted by **16**. Worked example — an erase confirm at flash address `0x2000`:

| | `boot_sector = 1` (correct) | `boot_sector = 0` (as shipped) |
|---|---|---|
| `erase_block_num` | 1 | 1 |
| `erase_boot` | 1 | 0 |
| `erase_base` | `1 << 13` = `0x2000` | `1 << 16` = `0x10000` |
| `erase_span` | `0x1FFF` | `0xFFFF` |
| bytes filled | `0x2000-0x3FFF` | **`0x10000-0x1FFFF`** |

The requested sector is never erased, **and** an unrelated 64KB is destroyed. Note
this is wrong under *both* readings — a genuinely uniform-64KB chip would need
`0x00000-0x0FFFF` here, which the code also does not produce. The low-64KB path is
hardcoded for the boot-sector map and is only coherent when `erase_boot = 1`.

**Fix:** `.boot_sector(own_flash_rq)` — one line, does not touch the shared FSM.
`boot_sector = 1` is both accurate *and* strictly safer (8KB fill at the correct
base). The value chosen is the one that is wrong in the damaging direction.

INFERRED mitigation, stated as inference: this only fires for erases in the low
64KB of the 8MB image, which on a Yamanooto multi-ROM is typically loader/menu
space a game would not erase. I do not have the Celica ROMs and did not trace their
save routines, so I cannot bound it empirically.

### W2 — persistence is claimed but not reachable from the OSD. VERIFIED

`MSX1.sv:276-277`:

```
"H6R[38],SRAM Save;",
"H6R[39],SRAM Load;",
```

`H6` hides these when `status_menumask[6]` is set. `MSX1.sv:325`:

```verilog
status_menumask[6] = (ΣSRAM sizes == 0) & (cart_conf[0].selected_mapper != MAPPER_ASCII16X);
```

`msx_config.sv:63` forces `selected_sram_size = 0` for `mapper_A_select == 4'd10`
(Yamanooto), and the mapper is `MAPPER_YAMANOOTO`, not `MAPPER_ASCII16X` — so the
mask is 1 and **both entries are hidden**. ASCII16X is explicitly exempted there;
Yamanooto was not added.

The `flash_dirtysave` datapath (`MSX1.sv:1005-1035`) is wired and live, but the
user has no button to press. The revised `docs/TODO_yamanooto.md` states
"`flash16x_*` extended so `flash_dirtysave` persists it" and lists only the slot-B
gap as open — this slot-A menu gap is a second, undisclosed blocker.

What the change **does** deliver today is in-session flash writes — enough for a
game's program-verify poll to succeed and the save to hold until reset or reload.

**Fix:** add `MAPPER_YAMANOOTO` to the `MSX1.sv:325` exemption, or restate the TODO.

### W3 — `flash.sv`'s command FSM is fed regardless of WREN. VERIFIED

`flash_rq` (`yamanooto.sv:256`) has no `flash_wr_en` term, so `ce`
(`msx_slots.sv:230-231`) is asserted for every cycle in `0x4000-0xBFFF` and
`we = cpu_mreq & cpu_wr` (`:229`).

Per the full read of `writeMem()`, openMSX **never** reaches `flash.write()` with
WREN clear. So a ROM that, with WREN clear, writes
`AA@x555, 55@x2AA, 80@x555, AA@x555, 55@x2AA, 30` with no intervening cart write
could trigger an erase the real cartridge would not perform.

Low probability — K5 bank writes land at `0x5000-0x57FF` etc. where `addr[11:1]`
is 0, and the SCC window is excluded by `~scc_req` — and `ascii16x.sv:107` has the
even looser `flash_rq = cs`. But this is a new surface on a mapper that also runs
ordinary Konami/SCC multi-ROMs, which ASCII16X does not.

Related asymmetry: `cart_wr` (`yamanooto.sv:210`) does **not** exclude `scc_req`,
while `flash_rq` (`:256`) does. So with WREN set an SCC-window write advances the
mapper's FSM (matching openMSX) but is invisible to `flash.sv`'s FSM. The two FSMs
can desync. Pathological in practice, but it is a real mismatch.

### W4 — unprovable without hardware

- Whether the Celica save routines (`Final Fantasy (KR)`, `Golvellius 2 (KR)`,
  `Jikuu no Hanayome (KR)`) actually complete.
- Whether HPS auto-mounts `<rom>.sav` for a Yamanooto ROM. The TODO flags this
  itself, and `selected_sram_size = 0` (`msx_config.sv:63`) is a concrete reason
  for doubt.
- Quartus timing closure and fit impact of the added FSM and the widened
  `pcm_vol` / `fm_vol` ports.
- Whether the OPL4 recalibration is subjectively right.

### W5 — minor, all VERIFIED

- **No address mirroring.** `Yamanooto.cc:128-136` mirrors `0x0000↔0x8000` and
  `0x4000↔0xC000` before both read and write; the RTL gates on `page_ok`
  (`yamanooto.sv:91,210`). Writes at `0xC000-0xFFFF` that openMSX routes to flash
  are dropped. Pre-existing — the read path shares the limit.
- **Chip-erase `0x10` is a no-op** — `flash.sv:84` has `erase_chip` commented out.
  The comment at `yamanooto.sv:245` ("30/10 confirm: flash.sv fills") overstates
  this; `ascii16x.sv:26` makes the same overclaim, so it is inherited.
- **`flash_dirtysave` is wired to `flash16x_active[0]` only** (`MSX1.sv:1009`), so a
  Yamanooto in slot B programs but never persists. The TODO does disclose this one.

---

## 3. Strongest counter-argument

> "Writing the byte straight into SDRAM and bypassing `flash.sv`'s program path is
> a hack that will diverge from real flash semantics."

**I can rebut this with evidence.** It is forced, not chosen:

- `flash.sv:178` guards the write block on `(quadrupleProgram | write_cnt > 0)`,
  while `bytePrgram`'s `write_cnt <= 1` (`flash.sv:189`) can only execute from
  inside the very block it must enter — the `0xA0` branch is structurally
  unreachable.
- `0xA0` is the only program command a JEDEC flasher issues (`AmdFlash.cc:867`).
- Widening that FSM was attempted on this project before and reverted for boot
  failure.
- The mechanism used instead is the same one ASCII16X uses, which is
  hardware-verified.
- The erase path — the part of `flash.sv` that *is* alive, with its bounds clamp —
  was deliberately left in place rather than duplicated.

Semantics are preserved where they exist, and worked around only where the shared
FSM is dead.

**The counter-argument I cannot rebut is W1.** An adversary arguing "the split was
justified by a claim that is factually false, and the value chosen makes a
low-address erase destroy an unrelated 64KB sector" has openMSX's chip table, the
byte-identical `M29W640GB` geometry, and this repository's own
`docs/yamanooto_spec.md:138` on their side. I have nothing to offer against it.

---

## 4. Recommended actions before ship

1. `msx_slots.sv:242` — change `.boot_sector(...)` to `.boot_sector(own_flash_rq)`.
2. `msx_slots.sv:240-241`, `flash.sv:16-18`, `docs/TODO_yamanooto.md` item 2 —
   correct the "uniform 64KB" claim.
3. `MSX1.sv:325` — add `MAPPER_YAMANOOTO` to the menu-mask exemption, or restate
   the TODO to say persistence is not yet reachable.

Optional / lower priority: consider whether `flash_rq` should carry
`flash_wr_en` (W3), weighing it against autoselect-readback behaviour after WREN
is cleared.

---

## 5. Sources consulted

**Repository**
`rtl/peripheral/slots/yamanooto.sv`, `flash.sv`, `msx_slots.sv`, `ascii16x.sv`,
`memory_upload.sv`; `MSX1.sv`; `rtl/msx_config.sv`; `rtl/msx.sv`;
`rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv`;
`rtl/flash_dirtysave.sv`, `rtl/nvram_backup.sv`;
`docs/yamanooto_spec.md`, `docs/TODO_yamanooto.md`;
`sim/tb_yamanooto_flash.sv`, `sim/run_yamanooto_flash.sh`.

**openMSX** (`~/Documents/github/openMSX`, master @ `2712dbd1c`)
`src/memory/Yamanooto.cc` (`writeMem()` read in full, `:190-282`),
`src/memory/Yamanooto.hh`, `src/memory/AmdFlash.cc`, `src/memory/AmdFlash.hh`.
