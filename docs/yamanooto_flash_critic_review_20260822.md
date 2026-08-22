# Yamanooto flash-write path — adversarial review

| | |
|---|---|
| **Reviewer** | `critic` (adversarial role in a three-perspective review; the other two argued to ship / neutral) |
| **Session id** | `0e07ce08-0d62-408c-a5ff-91ad83c4b04b` |
| **Model** | Claude Opus 5 (`claude-opus-5`) |
| **Date** | 2026-08-22 |
| **Subject** | UNCOMMITTED working tree on branch `moonsound_ascii16x` |
| **Primary scope** | `rtl/peripheral/slots/yamanooto.sv`, `msx_slots.sv`, `flash.sv`, `sim/tb_yamanooto_flash.sv` |
| **Secondary scope** | `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv`, `MSX1.sv`, `rtl/msx.sv`, `sim/tb_opl4_gain.sv` |
| **Reproductions** | `docs/yamanooto_flash_critic_review_20260822/` (6 Verilator testbenches) |
| **Repo mutations by the reviewer** | none — the review itself was read-only; all scratch work was in `/tmp/critic/` |

> ### ⚠ Read this first — the tree moved during the review
>
> This review was run against the working tree as it stood at the start of the session.
> **While the report was being written, F1, F2 and F5 were fixed in the working tree by
> another agent acting on the findings.** I re-ran every testbench against the post-fix
> tree before publishing; the per-finding **Status** rows below reflect the tree as of
> 2026-08-22, not the tree I originally attacked.
>
> **Still live and unfixed: F3 (critical) and F4 (medium).** Everything else in the
> critical/medium band is closed and verified closed.

**Original verdict: do not ship as-is** — three confirmed critical defects, all in
`flash.sv` and the newly un-gated `ce` that reaches it, which is the exact
shared-command-FSM hazard the change's own `docs/TODO_yamanooto.md` flags as "still
latent" and deliberately chose not to touch. Two of those three are now fixed. **The third
(F3) is not, and it is still fully reachable.**

Every claim marked CONFIRMED was reproduced by running a testbench that compiles the
repository's real RTL. Claims marked PLAUSIBLE were reasoned from source but not
reproduced, and are labelled as such.

---

## F1 — Yamanooto sector erase destroyed the WRONG 64 KB sector

**Critical · CONFIRMED · `rtl/peripheral/slots/flash.sv:83` (original) · Status: ✅ FIXED, verified**

### The defect

```systemverilog
erase_boot      <= boot_sector & ~(addr > 23'hFFFF);
erase_block_num <= (addr > 23'hFFFF ? {1'b0,addr[22:16]} : {5'd0,addr[15:13]} );
...
wire [26:0] erase_base = erase_boot ? (27'(erase_block_num) << 13)
                                    : (27'(erase_block_num) << 16);
```

The `addr <= 0xFFFF → addr[15:13]` special case exists **only** to index the M29W640's
eight 8 KB bottom-boot sectors. It was not gated on `boot_sector`. With `boot_sector = 0`
— exactly how `msx_slots.sv` drives it for the Yamanooto's uniform-sector S29GL064 —
`erase_boot` is 0, so `erase_base = erase_block_num << 16`, while `erase_block_num` came
from `addr[15:13]`. **The low 64 KB was decoded on an 8 KB grid and then shifted as if it
were a 64 KB grid.**

### Original reproduction

`tb_erase_sector.sv` — real `flash.sv`, `boot_sector=0`, `amd_family=1`,
`erase_limit=0x800000`, `sdram_offset=0`; full `AA/55/80/AA/55/30` sequence; the ch1 SDRAM
handshake modelled and every written byte logged.

```
  confirm@0x000000  filled 0x0000000 (65536 bytes)  want base 0x0000000  OK
  confirm@0x002000  filled 0x0010000 (65536 bytes)  want base 0x0000000  *** WRONG SECTOR ***
  confirm@0x004000  filled 0x0020000 (65536 bytes)  want base 0x0000000  *** WRONG SECTOR ***
  confirm@0x00e000  filled 0x0070000 (65536 bytes)  want base 0x0000000  *** WRONG SECTOR ***
  confirm@0x010000  filled 0x0010000 (65536 bytes)  want base 0x0010000  OK
  confirm@0x1f0000  filled 0x01f0000 (65536 bytes)  want base 0x01f0000  OK
errors=3  -> CONFIRMED BUG
```

Seven of the eight 8 KB pages of the first sector erased the wrong 64 KB.

**Concrete failure:** a game banks its 8 KB save page (segment 3) into `0x4000` and issues
the erase confirm there. Flash address `0x6000`, still inside sector 0. The core erased
`0x30000–0x3FFFF` — 64 KB of unrelated game data in an 8 MB multi-ROM — and left the
intended sector untouched, so the follow-up byte-program could not clear bits and the save
silently failed its verify-poll.

### Why this one mattered most

It is precisely the failure the change claimed to have prevented. `flash.sv:16-18`:

> *Split, because Yamanooto is also an AMD-family part but a UNIFORM-sector one
> (S29GL064): giving it the 8KB boot-sector map would erase the wrong span in the low 64KB.*

and `docs/TODO_yamanooto.md` calls it *"not a naming nit, it was a real defect"*. The flag
**was** split correctly. The address decoder the flag was papering over was left
unmodified, so the wrong-span erase still happened — just via the other branch.

### Fix as applied

```systemverilog
erase_block_num <= (boot_sector & ~(addr > 23'hFFFF)) ? {5'd0, addr[15:13]}
                                                     : {1'b0, addr[22:16]};
```

Re-running `tb_erase_sector.sv` against the current tree gives `errors=0 -> no bug found`
on all seven cases. The accompanying comment correctly notes this was also a **latent
MFRSD defect**, not something the Yamanooto work introduced.

---

## F2 — the shared JEDEC command FSM was enabled with WREN CLEAR

**Critical · CONFIRMED · `msx_slots.sv:230-231`, `yamanooto.sv:256` (original) · Status: ✅ FIXED, verified**

### The defect

```systemverilog
assign flash_rq = cs & page_ok & ~romdis & ~scc_req & ~reg_rd;   // <- no flash_wr_en
```

`flash.sv`'s command FSM fires on `we & ~old_we & ce`, where `we = cpu_mreq & cpu_wr`.
`flash_rq` carried no `flash_wr_en` term, so **every** CPU write into `0x4000–0xBFFF` on a
Yamanooto cart was fed to the shared JEDEC FSM, whether or not WREN was set.

openMSX `src/memory/Yamanooto.cc`, `writeMem` is unambiguous:

```cpp
if (enableReg & WREN) {
    if (!(configReg & ROMDIS)) flash.write(getFlashAddr(address), value, time);
} else {
    /* bank registers / SCC / mode register — the flash is never touched */
}
```

The mapper's own FSM *did* gate on WREN, which is what `sim/tb_yamanooto_flash.sv` tests.
`flash.sv`'s FSM did not — and the shipped TB never instantiates `flash.sv`, so it could
not see this.

### Original reproduction

`tb_integ.sv` — real `cart_yamanooto` + real `flash.sv`, wired exactly as `msx_slots.sv`
does it, `base_ram=0x0C00000`, `size=512`. WREN is 0 throughout.

```
[A] bank write: LD (0x50AA),0x98   -- WREN is CLEAR
    flash.cfi_state = 1
    read 0x4000 = 0x00   *** ROM WINDOW NO LONGER RETURNS ROM ***
    read 0x4020 = 0x51  (CFI 'Q')

[B] AA/55/90 autoselect  -- WREN is CLEAR
    flash.state = 1
    read 0x4000 = 0x01   *** ROM WINDOW REPLACED BY DEVICE ID ***

[C] LD (0x4AAA),0x56 then 5 ordinary writes -- WREN is CLEAR
    SDRAM writes issued by flash.sv = 4
      -> SDRAM[0x0d30100] <= 0xde ... 0x0d30103 <= 0xef
    *** ROM IMAGE CORRUPTED WITHOUT WREN ***
```

**Case [A] was the severe one.** `0x50AA` sits inside the Konami-5 bank window
`0x5000–0x57FF`, and its low 12 bits are `0x0AA` = word offset `0x055`, the CFI entry
offset. `0x98` is a legal bank number. So a *legitimate bank switch to segment 0x98* put
the chip into CFI query mode, after which the entire cartridge window returned `0x00` (or
the QRY signature) instead of ROM — permanently, until something wrote `0xF0`. The Z80 is
executing from that window: a hang, not a glitch.

**Case [C]:** `flash.sv`'s `quadrupleProgram` (`0x56`) and `doubleProgram` (`0x50`) are
live even though the `bytePrgram` (`0xA0`) branch is structurally dead, and they write
SDRAM through `flash.sv`'s own port — bypassing `ram_ro`, `mem_unmaped`, **and**
`erase_limit`.

**Regression status:** at HEAD, `cart_yamanooto` had no connection to `flash` at all
(`git show HEAD:rtl/peripheral/slots/msx_slots.sv` has no Yamanooto term in `.ce`). All
three consequences were introduced by this diff.

### Fix as applied

```systemverilog
assign flash_rq = cs & page_ok & ~romdis & ~scc_req & ~reg_rd
                & (cpu_rd | flash_wr_en);
```

Writes now need WREN; reads stay ungated, which is right — openMSX's `readMem` has no WREN
test, and autoselect/CFI results must remain readable. Re-running `tb_integ.sv` against the
current tree: cases [A], [B] and [C] all pass (`cfi_state=0`, `state=0`, 0 SDRAM writes).
The applied comment also correctly observes that K4 banking covers `0x6000–0xBFFF` in full,
making `0x?AAA` reachable there — a larger surface than ASCII16X's two bank addresses.

---

## F3 — an in-flight erase can be hijacked, past the region bound

**Critical · CONFIRMED · `rtl/peripheral/slots/flash.sv:172-202` · Status: ❌ STILL LIVE**

### The defect

```systemverilog
if (erase_block) begin
    // BOUNDS CLAMP lives here — and runs for exactly ONE cycle
    if (erase_base < erase_limit) begin ... erase <= 1; end
end else
if ((quadrupleProgram | write_cnt > 0) & we & ~old_we & ce) begin
    sdram_addr <= sdram_offset + 27'(addr);   // <- retargets the running fill
    sdram_din  <= din;                        // <- and replaces 0xFF with CPU data
    ...
```

`write_cnt` is non-zero for the whole 65 536-byte fill and `erase_block` is high for
exactly one cycle, so the `else if` branch is live for the **entire** erase. A single CPU
write that reaches `ce` retargets `sdram_addr` and substitutes the CPU's byte for `0xFF`;
the erase loop then keeps incrementing from the new address. The `erase_limit` clamp is
applied only at `erase_block` time and is bypassed completely.

### Reproduction — the overrun mechanism

`tb_hijack2.sv` — `flash.sv` driven directly, erase of sector `0x200000`,
`sdram_offset=0x0C00000`, `erase_limit=0x800000`; one write of `0x42` at flash address
`0x7FFF00` injected mid-fill. **Still reproduces against the current tree:**

```
mid-erase: 201 bytes filled so far, cursor at 0x0e000c8
erase finished: 65536 writes, span 0x0e00000..0x140fe36
  bytes written as 0xFF          : 201
  bytes written as SOMETHING ELSE: 65335
RESULT: *** FILL RAN PAST THE END OF THE 8MB CART REGION ***
```

65 335 bytes of `0x42`, ending at `0x140FE36` — **0xFE37 bytes beyond** the slot-A region
end at `0x1400000`, into whatever SDRAM region follows.

### Reproduction — still reachable through the F2 fix

The obvious objection is that F2's `& (cpu_rd | flash_wr_en)` now keeps stray writes out of
`ce`. It does not help here: **a flash driver necessarily holds WREN set across the erase**
— it set WREN to issue the command and clears it afterwards.

`tb_hijack_e2e.sv` — real `cart_yamanooto` + real `flash.sv` against the **current, fixed**
tree. `ENAR <- 0x12` (the Celica `WREN|SPIEN` value), bank page 0 to segment 248, sector
erase, then one ordinary write to `0x5F00` during the fill:

```
WREN = 1  (a driver holds this set across the whole erase)
mid-erase: 201 bytes filled, cursor 0x0df00c9
erase done: 65536 writes, highest addr 0x0e01e36 (region ends 0x1400000)
  0xFF bytes            : 202
  non-0xFF (CPU data)   : 65334
  bytes OUTSIDE the cart region: 0
RESULT: *** F3 STILL REACHABLE THROUGH THE FIXED WREN GATE ***
```

65 334 bytes of `0x42` written over the wrong part of the image instead of the erase. This
particular injection address stays in-region; `tb_hijack2.sv` shows the same mechanism
overrunning the region when the hijack address sits near the top.

The structure is pre-existing (it predates the Yamanooto work and affects MFRSD equally),
but the Yamanooto wiring adds a second cart that can drive it.

**Fix direction:** the `else if` write path must be suppressed while `erase` is asserted —
`write_cnt > 0` is not a safe proxy for "a program is in progress" because the erase shares
that counter. A separate `prog_pending` counter, or an explicit `& ~erase` guard, closes
it. Both need care: this is the shared FSM whose last broad edit caused the reverted boot
failure (`docs/TODO_boot_flakiness.md`), so the change should be minimal and TB-backed.

---

## F4 — the flash drives `cpu_din` during I/O cycles

**Medium · CONFIRMED · `yamanooto.sv:264`, `msx_slots.sv:149-161` · Status: ❌ STILL LIVE**

`flash_rq` has no `cpu_mreq` term — and the F2 fix's `(cpu_rd | flash_wr_en)` does not add
one, since `cpu_rd` is asserted during an I/O read. `cpu_din` in `msx_slots.sv` is a single
always-on AND tree that includes `flash_dout` unconditionally.

`tb_probe.sv`, probe P4 — autoselect active, `cpu_mreq=0`, `cpu_rd=1`, `cpu_addr=0x5012`
(an `IN A,(0x12)` on the Yamanooto's own PSG port with `A=0x50`). **Still reproduces
against the current tree:**

```
P4 IORQ cycle (mreq=0) addr=0x5012: y_flash_rq=1 data_valid=1 flash_dout=0x7e
   *** flash drives cpu_din during an I/O cycle ***
```

`IN` results get ANDed with `0x7E`. It is a regression — `flash_dout` was `0xFF` for all
Yamanooto cycles at HEAD. Severity is bounded because it needs `state` or `cfi_state` to be
set, and F2's fix removed the accidental route into those; what remains is corruption of
I/O reads during a driver's legitimate autoselect/CFI window.

**Fix direction:** add `& cpu_mreq` to `flash_rq`. (The same hazard exists for ASCII16X,
where `flash_rq = cs` has neither `cpu_mreq` nor `page_ok` — pre-existing, out of scope
here.)

---

## F5 — the persistence path had no user-reachable trigger

**Medium · CONFIRMED · `MSX1.sv:325` (original) · Status: ✅ FIXED**

`msx_slots.sv:547-550` set `flash16x_active` for `MAPPER_YAMANOOTO`, and `MSX1.sv`
fed `flash_dirtysave` from `status[38]` / `status[39]`. Those bits come from:

```
"H6R[38],SRAM Save;"   "H6R[39],SRAM Load;"
assign status_menumask[6] = (lookup_SRAM[...] == 0)
                          & (cart_conf[0].selected_mapper != MAPPER_ASCII16X);
```

`msx_config.sv:63` gives `selected_sram_size = 0` for `mapper_A_select == 4'd10`
(Yamanooto), so all four `lookup_SRAM[].size` are zero and `selected_mapper` is
`MAPPER_YAMANOOTO`, not `MAPPER_ASCII16X` — therefore `menumask[6] = 1` and **both menu
items stayed hidden**. There was no way to fire SAVE. `docs/TODO_yamanooto.md` claimed
*"`flash16x_*` extended so `flash_dirtysave` persists it"* and listed only slot-B coverage
as open; slot A did not work either.

**Fix as applied:** `MSX1.sv:330-332` now adds
`& (cart_conf[0].selected_mapper != MAPPER_YAMANOOTO)`.

---

## F6 — cross-slot dirty-bitmap pollution

**Low · PLAUSIBLE (unreproduced) · `msx_slots.sv:73-75`, `MSX1.sv:1009-1011` · Status: open**

`flash16x_prog_we = mapper_ascii16x_prog_we | mapper_yamanooto_prog_we` is unqualified by
`cart_num`, while `flash_dirtysave` is bound to `flash16x_active[0]` / `flash16x_base[0]` /
`flash16x_size[0]`. With an ASCII16X in slot A and a Yamanooto in slot B, slot B's program
addresses would set `dirty[]` bits in slot A's bitmap (`flash_dirtysave.sv:132`). SAVE
dumps real SDRAM contents, so the `.sav` gains extra *correct* blocks rather than wrong
ones — bloat, not corruption. Would need a full two-slot `msx_slots` harness to confirm.

---

## F7 — no size bound in the mapper; the safety margin is entirely external

**Low · PLAUSIBLE, currently harmless · `yamanooto.sv:186`, `:239` · Status: open**

```systemverilog
J_PROG: begin
           prog_arm <= ~mem_unmaped;      // only program in-bounds     <- FALSE
```

`mem_unmaped` contains **no size test**:

```systemverilog
assign mem_unmaped = cs & (~page_ok | romdis | scc_req | reg_rd
                           | (cpu_wr & cpu_mreq & ~flash_wr_en));
```

During a program write `page_ok=1`, `romdis=0`, `flash_wr_en=1`, `cpu_rd=0`, so it reduces
to `scc_req` alone. The `mem_size` input is declared and still never used anywhere in the
module. Contrast `ascii16x.sv:105`, the module this was modelled on:
`mem_unmaped = cs & (ram_addr >= rom_size)` — a real bound.

I could not turn this into an out-of-region write, and that should be stated plainly:
`memory_upload.sv:238-241` pads any Yamanooto image to a full 8 MB (`x16_pad`), and
`msx_config.sv:87` asserts `reload` on any mapper change, so the region is re-padded when
the user switches the dropdown. `size = 512`, and the 10-bit bank register caps `mem_addr`
at `0x7FFFFF` = exactly the region size. **The comment's claim is false but the outcome is
currently safe.** It is a single-point dependency on an allocator in a different file, with
no defence in depth and no assertion covering it.

---

## F8 — OPL4 menu labels mean different things on the two knobs

**Low · `MSX1.sv:307-308` · Status: open (design choice, undocumented in the menu)**

| menu entry | FM label → net | PCM label → net |
|---|---|---|
| 0 (default) | `0dB` → −3.98 dB | `-4dB` → −12.00 dB |
| 1 | `-4dB` → −8.00 dB | `-8dB` → −16.00 dB |
| 2 | `-8dB` → −12.04 dB | `0dB` → −8.00 dB |
| 3 | `+4dB` → 0.00 dB | `+4dB` → −4.00 dB |
| 4 | `+8dB` → +4.02 dB | `+8dB` → 0.00 dB |

FM labels are the delta from the default entry (offset **+4 dB** from net); PCM labels are
offset **+8 dB** from net. The same label on both controls is not the same relative change.
`0dB` also no longer means the hardware-accurate unity it meant in the previous build — a
user who previously chose `0dB` and re-selects it now gets −3.98 dB on FM and −8.00 dB on
PCM. Deliberate per the calibration comment, but invisible from the menu.

---

## Attacks that FAILED — evidence of robustness

These matter as much as the findings.

1. **`own_flash_rq` behaviour change for ASCII16X or MFRSD.** Enumerated all 16
   combinations. Old `is_ascii16x = A & ~M0 & ~M3` vs new `own = (A|Y) & ~M0 & ~M3` differ
   only when `Y=1`. `A` and `Y` are `mapper == MAPPER_ASCII16X` / `== MAPPER_YAMANOOTO` on
   a single decoded `mapper` value, so mutually exclusive; `M3` likewise. `boot_sector`
   retains the exact old expression. **No behavioural change for ASCII16X or MFRSD** —
   clean refactor.
2. **MFRSD ↔ Yamanooto unlock interleaving through the shared FSM.** NOT reachable.
   `mapper` is a single decoded value, so `MAPPER_YAMANOOTO` and `MAPPER_MFRSD1/MFRSD3`
   are mutually exclusive per bus cycle and cannot interleave writes into one unlock
   sequence. (`.ce`'s MFRSD terms are additionally gated by `cart_device & DEV_FLASH`.)
3. **`sdram_offset` / `erase_limit` mux changing DURING the fill.** `flash.sv` latches
   `sdram_addr <= sdram_offset + erase_base` once and `write_cnt` in the same cycle; every
   later address is an internal increment. Changing the mux mid-fill cannot move the erase.
   (F3 hijacks it by a different route.)
4. **`prog_arm` sticking on.** Probe P2 — after a program write, the next unrelated write
   shows `prog_we` for 0 cycles. `wr_fall` clears it reliably.
5. **Long / wait-stated M-cycle.** Probe P1 — a 12-clk write holds `prog_we` for 11 cycles,
   so `sdram_ce` is level-held; but it is the same address with the same data, and this is
   byte-for-byte what the shipped ASCII16X path already does.
6. **Desyncing the mapper FSM.** Probe P5 (200-cycle gap inside the unlock) and P6 (a cart
   read interleaved between unlock cycles) both still program correctly — the FSM is
   edge-driven on `wr_rise` and reads do not disturb it.
7. **Programming the byte that lives AT the unlock offset `0x?AAA`.** Probe P7 — works, and
   `flash.index` returns to 0 afterwards.
8. **Bank switch between unlock and data byte.** Probe P3 — with WREN set, `bank_hit` is
   suppressed and the `0x5000` write is correctly treated as flash data at
   `flash_addr=0x1000`. Matches openMSX's `if (WREN) {...} else {bank...}` exactly.
9. **Program-data write landing on a config register.** Probe P8 — a data write to `0x7FFD`
   sets ROMDIS and produces `prog_we` for 0 cycles: self-blocking, matching openMSX's
   registers-handled-first ordering.
10. **Out-of-region `prog_we`.** Could not construct one — see F7.
11. **The shipped `sim/tb_yamanooto_flash.sv` being a can't-fail testbench.** It is not:
    `$fatal` returns a real non-zero exit and `${PIPESTATUS[0]}` is read correctly.
    Verified 17 checks / 0 errors originally, 21 / 0 after the fixes, with `NEGCTL=1`
    failing 2 as required in both. **Its weakness is coverage, not plumbing** — it never
    instantiates `flash.sv`, which is where F1, F2 and F3 all live. That gap is why F3 is
    still open.
12. **OPL4 width / overflow with the new larger constants.** `fm_l_mul` is `signed [29:0]`;
    worst case `65536 × 203 = 13,303,808` needs 25 bits. After `>>>7`: FM ±103 936,
    PCM ±41 472, sum ±145 408 → 19 bits signed into a 22-bit `sum`. No overflow.
    `pcm_pre()` returns `[1:0]` into the engine's `[1:0] pcm_vol` port, and
    `sh = 2'd3 - pcm_vol` at `ymf278_pcm_engine2.sv:459` matches the TB's model; the engine
    saturates after the shift as the TB assumes. `sim/tb_opl4_gain.sv` passes 21202/21202
    and its NEGCTL fails 10 as required.
13. **OPL4 status-bit relocation collisions.** `status[54:59]` are used nowhere else in
    `MSX1.sv`; `status[51]` (Cheats) and `status[48]` (Debug Overlay) are untouched; the
    vacated `[49:50]` and `[52:53]` are read by nothing, so stale values in an existing
    user `.cfg` are inert. `rtl/msx.sv:117-118` and `:1407-1408` widen and pass through
    correctly.
14. **`sim/check_opl4_gain_consts.py` sensitivity.** Copied the RTL to a scratch tree,
    changed `fm_gain(4)` from 203 to 220, re-ran: `<-- FM MISMATCH`, exit 1. It genuinely
    parses the shipped RTL rather than a copy, and additionally enforces that menu entry 0
    is the calibrated default and that out-of-range selectors fall back to it. This is a
    real answer to the "TB is a copy of the RTL" failure mode this repo has been bitten by
    before. **One gap:** it does not cross-check the `CONF_STR` menu labels, so reordering
    the OSD entries in `MSX1.sv` would go undetected.

---

## Reproducing

The six testbenches are in `docs/yamanooto_flash_critic_review_20260822/`. Each compiles
the repository's real RTL read-only — none of them is a copy of the DUT.

```bash
cd <repo root>
D=docs/yamanooto_flash_critic_review_20260822
R=rtl/peripheral/slots

# F1 — wrong erase sector.  Expect errors=0 on the fixed tree.
verilator --binary --timing -Wno-fatal --top-module tb_erase_sector \
   -o t -Mdir /tmp/b1 $R/flash.sv $D/tb_erase_sector.sv && /tmp/b1/t

# F2 / F4 — WREN gating and I/O-cycle bus contention.
# Expect [A][B][C] clean on the fixed tree; P4 still flags F4.
verilator --binary --timing -Wno-fatal --top-module tb_integ \
   -o t -Mdir /tmp/b2 rtl/package.sv $R/yamanooto.sv $R/flash.sv $D/tb_integ.sv && /tmp/b2/t

# F3 — erase hijack, flash.sv driven directly.  STILL FAILS.
# tb_hijack.sv is the same test injecting in-region; tb_hijack2.sv overruns the region.
verilator --binary --timing -Wno-fatal --top-module tb_hijack2 \
   -o t -Mdir /tmp/b4 $R/flash.sv $D/tb_hijack2.sv && /tmp/b4/t

# F3 — end-to-end through the FIXED WREN gate, real cart_yamanooto.  STILL FAILS.
verilator --binary --timing -Wno-fatal --top-module tb_hijack_e2e \
   -o t -Mdir /tmp/b6 rtl/package.sv $R/yamanooto.sv $R/flash.sv $D/tb_hijack_e2e.sv && /tmp/b6/t

# P1..P8 — the probe suite behind the "attacks that failed" list, plus F4.
verilator --binary --timing -Wno-fatal --top-module tb_probe \
   -o t -Mdir /tmp/b5 rtl/package.sv $R/yamanooto.sv $R/flash.sv $D/tb_probe.sv && /tmp/b5/t
```

Toolchain: Verilator 5.050 (2026-07-01).

---

## Summary

| # | Defect | Severity | Evidence | Site | Status (2026-08-22) |
|---|---|---|---|---|---|
| F1 | Erase hits wrong 64 KB sector (uniform-sector part) | Critical | CONFIRMED | `flash.sv:83` | ✅ fixed, verified |
| F2 | Shared JEDEC FSM live with WREN clear | Critical | CONFIRMED | `msx_slots.sv:230`, `yamanooto.sv:256` | ✅ fixed, verified |
| F3 | In-flight erase hijack, past `erase_limit` | Critical | CONFIRMED | `flash.sv:172-202` | ❌ **still live** |
| F4 | Flash drives `cpu_din` on I/O cycles | Medium | CONFIRMED | `yamanooto.sv:264` | ❌ **still live** |
| F5 | Save/Load menu hidden → persistence unreachable | Medium | CONFIRMED | `MSX1.sv:325` | ✅ fixed |
| F6 | Cross-slot dirty-bitmap pollution | Low | PLAUSIBLE | `msx_slots.sv:73-75` | open |
| F7 | No size bound in the mapper; safety is external | Low | PLAUSIBLE | `yamanooto.sv:186`, `:239` | open |
| F8 | OPL4 menu labels inconsistent between knobs | Low | — | `MSX1.sv:307-308` | open |

**Remaining blocker for ship: F3.** It is the one confirmed critical defect still present,
it is reachable in the ordinary programming flow (WREN is set across an erase by
construction), and its consequence is 64 KB of arbitrary CPU data written over the wrong
part of the image — or past the cart region entirely. It is also the finding no existing
testbench covers, because none of them instantiate `flash.sv`.
