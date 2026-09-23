# The turbo R disk ROM problem and its fix (2026-09-22 … 23)

*How two turbo R titles stopped loading, why the cause was the pack and not the
core, and how the fix ended up being a disk ROM stitched together from the
machine's own DOS 2 kernel and a Sony WD2793 driver.  Written so that someone who
was not there can follow every step and repeat every measurement.*

Sessions: `msx1-mister-8f` (this document, RTL, cross-checks) and
`msx1-mister-sonydos2-1c` (openMSX measurements, the ROM synthesis).  Branch
`nextz80`, worktree `.claude/worktrees/readcache`.

---

## 0. TL;DR

* **Symptom.** On the FS-A1ST / FS-A1GT packs, *Illusion City* hangs during its
  loader (ninth sector transfer pops `0000` off the stack) and *SD Snatcher* drops
  to BASIC instead of booting.  Both are deterministic, both happen on every core
  build (22a, 22c), and neither is a core defect.
* **Cause.** The packs carried an **ASCII MSX-DOS 2.20 kernel in slot 3-3**
  (a stand-in for the machine's built-in DOS 2, which lives in a TC8566AF disk
  ROM block the core cannot run).  With 2.20 active, Illusion City takes a
  different loader path whose stack sits inside a sector buffer, and SD
  Snatcher's boot sector is never called.  The real machine's DOS 2.30/2.31 does
  neither; DOS 1 does neither.
* **Fix.** A **synthesized 64 kB disk ROM**: the turbo R's own DOS 2.30 (ST) /
  2.31 (GT) kernel with its TC8566AF driver replaced by the HB-F1XD WD2793 driver
  (34 byte-level patches, every one asserting the original bytes).  Slot 3-2
  carries it as the new pack block type `TURBOR_FDC`; slot 3-3 is empty.  In
  openMSX both games now run the stock machine's exact path.
* **Core change.** One mapper enum (`MAPPER_TRFDC`), one input on
  `mapper_msxdos2` (`win_7ff0_only`), two lines in `msx_slots.sv`.  No new FDC.
* **Done alongside.** The `MSXDOS2` (ASCII 2.20) block is removed from all 30
  packs that carried it — Panasonic 18 and Sony 12 — since the Sony HB-F1XDmk2
  shows the same two symptoms (sony session, 37c7975).
* **Not done yet.** Hardware verification; the turbo R pack XMLs with the
  `TURBOR_FDC` block (sony session, awaiting the user's go).

---

## 1. The two symptoms

### 1.1 Illusion City (FS-A1ST pack, "loading stops")

Evidence: `tools/evtrace/captures/` (22a, `evt_p5`) and the 22c capture of this
session (`evt_ic22c`, scratch).  Both show the same thing:

* The loader's sector-transfer loop at `765D` (`LD A,(BC) / ADD A,A / RET P /
  JP C,765D` — it is the **HB-F1XD disk ROM's** DSKIO loop, not game code)
  runs nine times.  Transfers 1–8 return to `7669`.  **Transfer 9 pops `0000`**
  (SP = `EAE8`).
* From `0000` the machine walks a loop `0000→0095→017E→01CB→…→0227→0000` whose
  SP drifts by +2 per pass; at SP = `EC00` it pops `C9C9`, fetches FF-filled
  memory and storms `RST 38`.
* No CPU hand-over near it, T80 at 3.58 MHz, bus guard bypassed: not the
  boot-death family (that one was fixed by `a7cde96` / build 22c).

The per-transfer table, reconstructed from the `EX (SP),HL` writes at `7645`
(the capture records every write to the EAxx page):

| transfer | destination HL | port FEh (page-2 segment) |
|---|---|---|
| 1 | A61B | 0F |
| 2–7 | 8100, 8300 … 8B00 | 03 |
| 8 | A829 | 0F |
| **9** | **AA00** | **00** |

Port FFh (page 3) is never written in the whole capture, so it holds the BIOS
default, segment 0.  Hence `AA00-ABFF` in page 2 **is physically `EA00-EBFF`,
the stack page**: the sector lands on the return address.  Byte E8–E9 of that
sector (disk offset `0x1600` = LBA 11 = track 0 / side 1 / sector 3) is `00 00`
in every dump variant of Disk 1 — a genuine disk read, not a corrupted one.

### 1.2 SD Snatcher (Panasonic MSX2+ packs with DOS 2, "boots to BASIC")

Reference measurement in openMSX with machines generated from the pack XMLs
(§2.3): on every pack that has an `MSXDOS2` block **and ≥128 kB RAM** the boot
sector at `C01E` is **never called** and the machine lands in Disk BASIC.  The
64 kB packs (no DOS 2 active) boot to the KONAMI logo at t≈38 s.  FM, RAM size
itself and the disk-ROM type (WD2793 or TC8566AF) do not matter; a sound
cartridge (SCC / SCC+) is required in all cases.  The board matches this table
(user, 2026-09-23).

---

## 2. Finding the cause

### 2.1 Ruling the core out

The stock openMSX FS-A1ST **never enters the `765D` loop at all**: that loop is
in the HB-F1XD (WD2793) disk ROM, and the stock machine has a TC8566AF with its
own driver.  So the pack's *configuration* had to be reproduced before anything
could be compared.  The sony session built `ST_pack` = stock FS-A1ST with the
TC8566AF block replaced by a Sony-style WD2793 + `hb-f1xd_disk.rom` (sha1
`12f2cc79…`) and slot 3-3 = `ascii_msxdos22.rom` (sha1 `42f4e336…`) — exactly
what `Panasonic FS-A1ST.xml` declares.

Result: **the hang reproduces in openMSX** on the 16th transfer (our capture's
1st–9th are its 8th–16th; the ring simply did not reach back further), same
destination, same FE/FF, same SP, same `0000`.  Core innocent.

### 2.2 Which ingredient

| machine | disk ROM | slot 3-3 | result |
|---|---|---|---|
| stock ST | TC8566AF (DOS 2.30 inside) | Panasonic firmware | completes |
| ST + WD2793, stock 3-3 | WD2793 / DOS 1 | Panasonic firmware | completes (DOS 1 path) |
| ST stock disk ROM + ASCII 2.20 in 3-3 | TC8566AF | ASCII 2.20 | completes — the *2.30 inside the disk ROM* stays the active kernel, the 2.20 is idle |
| **ST + WD2793 + ASCII 2.20 in 3-3** (= the pack) | WD2793 / DOS 1 | ASCII 2.20 | **RET pops 0000** |
| same with the European 2.20 or MK 2.20 | | | same failure |

So neither the WD2793 substitution nor the 3-3 kernel alone is the problem; it
is *WD2793 disk ROM (DOS 1) + an ASCII 2.20 kernel that becomes the active DOS*.

### 2.3 What 2.20 changes — it is the game, not a kernel bug

Two candidate mechanisms were checked and both were wrong:

* "The kernel hands out segment 0 through `ALL_SEG`": the game **never calls
  EXTBIO** (0 calls in 12 s).
* "The game writes a constant 0": the segment comes from game variable `F2CF`,
  computed from byte +1 of the DOS 2 mapper table (total segments, 16 in every
  configuration) — but by **different loader code** depending on which kernel
  is active (`499D…` under 2.30 → `0B`; `4971…` under 2.20 → `0F`).  The 2.20
  path also issues DOS 2 handle calls (BDOS 43h/6Ah) that the 2.30 path never
  makes.  `_DOSVER` is not called; how the game tells the kernels apart is
  unknown and irrelevant to the fix.

The decisive difference, measured at DSKIO entry (`4010h`) for the LBA 11 read:

| configuration | F2CF | destination | FE / FF | **SP** | outcome |
|---|---|---|---|---|---|
| stock ST (2.30) | 0B | EA00 (page 3) | 01 / 00 | **FAC6** | ok |
| ST + WD, no DOS 2 | 00 | EA00 | 01 / 00 | FAC6 | ok |
| ST + WD + 2.20 | 0F | AA00 → seg 0 (= EA00) | 00 / 00 | **EAF4** | dead |

The sector goes to the **same physical bytes in every case**; what differs is
where the stack is at that moment.  Under 2.20 the stack is inside the sector.

### 2.4 SD Snatcher, same root

With 2.20 active the boot sector is not executed.  The boot sector is a standard
one (`+1Eh: D0` = `RET NC`, then `DI / LD SP,DD00 / BDOS 1Ah / BDOS 2Fh … JP C200`).
DOS 1 and DOS 2.30 call it (`CY=0` then `CY=1`, ~0.2 s apart); 2.20 does not.
Why 2.20 skips it was **not** investigated further once the fix below made it
moot.

Nextor was tried as an alternative kernel (2.1.4 standalone in 3-3, and the MFRSD
cartridge's built-in Nextor): its default DOS 2 mode has the same SD Snatcher
symptom; its DOS 1 mode (hold `1` at boot) runs both games but needs a key press
every boot.  (A first reading that the MFRSD cartridge ROM held "Nextor 2.10
alpha 2" and failed both games was wrong: that test used a stale copy under
`releases/`; the ROM the packs build with is Nextor 2.1.4.)

---

## 3. The real machine's answer, and why we could copy it

How does the stock turbo R get away with running *both* DOS 2.30 and the games?
Measured in openMSX: when a game disk is booted, DOS 2 runs the front half of
its initialisation (`INIHRD → DRIVES → INIENV`), then **switches to bank 3 of
the disk ROM — a plain Microsoft DOS 1 kernel — at `58A8h`** and boots the game
under DOS 1.  Exactly once (ST t=8.54 s, GT t=9.24 s; not at all without a
disk).  Bank 3's `58A8-5A00` is byte-identical to the HB-F1XD ROM.

The 64 kB block at firmware offset `0x60000` (openMSX `firstblock 48-55`):

| bank | content |
|---|---|
| 0 | "MSX-DOS kernel version 2.30" (ST) / "2.31" (GT), Copyright ASCII 1990/1991, + TC8566AF driver at 7405–7FCF |
| 1 | more of the DOS 2 kernel (ST: message bank, English + SJIS text at 40FF–5CF3); **5C00–7FFF identical to bank 0** — the driver is shared |
| 2 | DOS 2 kernel data; references nothing in the FDC |
| 3 | Microsoft DOS 1 kernel ("MSX-DOS ver. 2.2 Copyright 1984 by Microsoft") + the same TC8566AF driver |

Every bank has the bank-switch stub `LD (7FF0),A / RET` at `7FD0`, and banks
0–2 have an interrupt trampoline at `7FD4` (read own bank number from `40FF`,
switch to bank 0, `CALL handler`, switch back).  Reset selects bank 0.

**The key observation:** bank 3's *kernel* region `4000–73FF` differs from the
HB-F1XD ROM in only **33 bytes at 15 places** (re-checked in this session).
Those 33 bytes are the entire kernel↔driver contract of a DOS 1 disk ROM: the
six-entry jump table at `4010–401F` and five absolute references (`INIHRD`,
`DRIVES`, `DEFDPB`, `INIENV`, `OEMSTA`).  Aligning bank 3's TC8566AF driver with
bank 0's (similarity 0.94) transfers that contract to the DOS 2 kernel, where
the same five call sites exist at the same addresses in 2.30 and 2.31:

| site (bank 0) | meaning | ST 2.30 target | GT 2.31 target | hb-f1xd target |
|---|---|---|---|---|
| 4010–401F | DSKIO / DSKCHG / GETDPB / CHOICE / DSKFMT / MTOFF | 7495 / 77CA / 7820 / 783B / 7C6D / 7746 | 7459 / 779D / 77F9 / 781A / 7C52 / 7713 | 751E / 78BA / 7943 / 795D / 79A0 / 7DE2 |
| 47D6 | `CALL INIHRD` | 7724 | 76F1 | 7827 |
| 48C6 | `CALL DRIVES` | 777A | 7747 | 7867 |
| 48F8 | `LD HL,DEFDPB` | 7416 | 73DA | 74E7 |
| 4904 | `CALL INIENV` | 77A1 | 7771 | 78A7 |
| 5796 | `JP OEMSTA` | 7878 | 785D | 7DE0 |

The other direction — what the driver calls in the kernel — is five routines
(`GETWRK`, `SETINT`, the "insert disk" prompt, a 16-bit divide, the generic
timer tail), whose call sites in the TC driver are byte-identical between the
DOS 1 and DOS 2 banks, so the register conventions are the same:

| DOS 1 (hb) | ST 2.30 | GT 2.31 | routine |
|---|---|---|---|
| 5FC2 | 4DCD | 4DD8 | GETWRK (6 call sites in the hb driver) |
| 5FF6 | 4DFE | 4E09 | SETINT |
| 625A | 4D4F | 4D5A | drive-change prompt |
| 492F | 4E67 | 4E72 | 16-bit divide |
| 6027 | 4E14 | 4E1F | generic timer (the handler's tail `JP`) |

The TC8566AF register references (`7FF1–7FF5`) live entirely inside the driver
region, so replacing the driver removes them all; the kernel itself never reads
those addresses.  The WD2793 registers (`7FF8–7FFF`, Sony layout) and the bank
register (`7FF0`) do not overlap, which is what makes a single-slot block
possible.

A trap worth recording: bank 1's message text, aligned byte-wise, produced a
convincing `JP M,DSKIO` at `59F3` inside an SJIS string.  It is text; patching it
would have corrupted a message.  The GT's driver region also starts lower
(`7024`) and holds a self-contained "SRAMdisk by JS" option (uses the firmware
SRAM as a drive) at `70C4–73A7`; it never calls above `7405`, so only
`7405–7FCF` is replaced and the SRAM disk code stays.  Without 3-3 SRAM in the
pack it registers nothing harmful (boot and both games unaffected).

---

## 4. The synthesized ROM

`tools/turbor_diskrom/synth_diskrom.py` (README there).  Per machine, 34 patches, each
asserting the original bytes:

1. Take the HB-F1XD driver `7405–7FCF` and re-point its five DOS 1 kernel calls
   to the DOS 2 kernel's equivalents (11 byte patches: GETWRK ×6, SETINT, prompt,
   divide, and the interrupt path below).
2. Interrupt path: the hb `INIENV` registers its handler directly with `SETINT`;
   under DOS 2 the handler must go through the `7FD4` trampoline so it runs in
   bank 0 whatever bank is paged in.  So `INIENV` registers `7FD4`, the
   trampoline's `CALL` (at `7FDE` in banks 0/1/2) targets the hb handler `78B7`,
   and the handler's tail jumps to the DOS 2 generic timer.
3. Banks 0 and 1: driver region ← patched hb driver; jump table `4010–401F` ←
   hb symbols.  Bank 0 only: the five absolute references ← hb symbols.
   `MYSIZE` (`489A`) is asserted and left (DOS 2 asks for more driver work
   area than hb needs; harmless, and keeps the RAM layout of the stock machine).
4. Bank 3 ← the whole HB-F1XD ROM + `7FD0: 32 F0 7F C9` + `7FD4: C3 B7 78`
   (its `7FC0–7FFF` is zero in the original).

Products: `synth_st.rom` sha1 `94f4587db749af02f82837b3dbad7fc6e55f15e9`,
`synth_gt.rom` sha1 `86f81c71c858d98e2d4031566efd3b5a3843e279`.  The GT's own
2.31 was used rather than the 2.31 found in the MMC/SD Drive BIOS tool
(`MMCSD.OVL` banks 20–23, same ASCII 2.31, bank 2 identical) because it is the
machine's own; that tool was useful as evidence that others have re-linked
these kernels onto other drivers.

---

## 5. Verification (openMSX, 2026-09-23)

openMSX has no device that puts a bank register and a WD2793 in one page, so a
small one was written (`tools/turbor_diskrom/omsx/BankedSonyFDC.{hh,cc}`:
`WD2793BasedFDC` + TurboRFDC-style 7FF0 bank with cache invalidation, Sony
registers at 7FF8–7FFF) and built into a scratch copy of the user's openMSX
tree.  Machines: the pack configurations with 3-3 empty and 3-2 = this device +
the synthesized ROM.  Control: stock ST / GT on the same binary.

| | F2CF | LBA 11 destination / SP | boot sector C01E | bank-3 switch | DSKIO calls | outcome |
|---|---|---|---|---|---|---|
| stock ST (2.30, TC8566AF) | 0B | EA00 / FAC6 | CY=0 10.32 s → CY=1 10.53 s | 8.54 s | 34 / 16 | IC asks for disk 2; SDS logo t=32–34 |
| **synth ST (2.30, WD2793)** | 0B | EA00 / FAC6 | 12.17 → 12.38 s | 10.39 s | 34 / 16 | same |
| stock GT (2.31, TC8566AF) | 1B | EA00 / FAC6 | 11.00 → 11.22 s | 9.24 s | 30 / 16 | IC FM-source menu; SDS logo t=32–38 |
| **synth GT (2.31, WD2793)** | 1B | EA00 / FAC6 | 12.17 → 12.38 s | 10.39 s | 30 / 16 | same |
| old pack (WD + ASCII 2.20) | 0F | AA00→seg 0 / EAF4 | never | — | — | IC dead, SDS BASIC |

The synthesized machines run 1.5–2 s behind the stock ones (WD2793 seek timing)
with identical order and values; the no-disk boot reaches the same BASIC key
wait with the same bank sequence (`00 / 01×3 / 02×1`).  Logs and probe scripts:
`tools/turbor_diskrom/{g,n}/`, `*.tcl`.

**Hardware: not yet verified.**  That needs a core build with `MAPPER_TRFDC`
(this branch) and the new packs (sony session).

---

## 6. Core and pack changes

* `rtl/package.sv`: `MAPPER_TRFDC` appended to `mapper_typ_t` (5-bit enum, room
  remained).
* `rtl/peripheral/slots/msxdos2.sv`: input `win_7ff0_only`.  With it set the
  bank window is `7FF0` alone.  The generic DOS 2 cartridge also decodes
  `6000–6FFF` and `7FFE`; in a page shared with the FDC that would let any
  ASCII8-style probe (`LD (6000),A`) or a stray write switch the kernel bank
  under the running driver.  The real TurboRFDC decodes only `7FF0`.
* `rtl/peripheral/slots/msx_slots.sv`: the `msxdos2` instance is selected for
  `MAPPER_MSXDOS2 | MAPPER_TRFDC`, narrow when `MAPPER_TRFDC`; address mux row
  added.  `fdc.sv` is untouched: it is selected by `device == DEVICE_FDC`, which
  the `MEMORY=FDC` block header already sets, and it never decoded `7FF0–7FF7`.
* `tools/CreateMSXpack/createMSXpack.py`: `MAPPER_TRFDC` appended to
  `MAPPER_TYPES` (index order is the enum order — append only), block type
  `TURBOR_FDC` = `{MEMORY: FDC, DEVICE: NONE, MAPPER: MAPPER_TRFDC}`.  The
  uploader already sizes the ROM from `block_count` (4 → 64 kB) and sets
  `use_FDC` from the memory type.
* Benches: `sim/tb_msxdos2.sv` gained the 7FF0-only checks (23 checks);
  `sim/tb_trfdc.sv` + `sim/run_trfdc.sh` exercise the mapper and `fdc.sv`
  sharing a page (12 checks).  `tools/buildgate/landmines.tsv` row `trfdc`.
* Full-machine Verilator lint (`sim/fullsys`) clean after the change.

Pack side (sony session, not in this branch): turbo R packs ST ×5 / GT ×4
replaced — 3-2 = `TURBOR_FDC`, 4 blocks, `fs-a1{st,gt}_diskrom_wd2793.rom`
(the synthesized ROMs, placed in the untracked ROM store), 3-3 empty.  The
`MSXDOS2` block removed from all 30 packs that carried it — Panasonic 18 (F FM /
FX / WX ×3, GT 4, ST 5) and Sony 12 (HB-F1XDmk2, HB-F1XV) — after the Sony
HB-F1XDmk2 1 MB showed the same two symptoms (sony, 37c7975; FS-A1WX 1 MB and
HB-F1XDmk2 1 MB then run both games, the WX t=80 screen pixel-identical to stock).  Built `.MSX` files are not
pushed.

---

## 7. Open items

1. **Hardware run** of a `MAPPER_TRFDC` build with the new ST/GT packs: DOS 2
   prompt, Illusion City past the ninth transfer (watch `EAE8` with the event
   recorder's `K_MW`), SD Snatcher to the logo.
2. ~~MFRSD pack: replace the Nextor 2.10 alpha 2 kernel.~~  Withdrawn: the packs already
   ship Nextor 2.1.4 (`mfrsd.rom` 411c6d8c…); the alpha-2 reading came from a stale
   copy under `releases/`.  Files renamed `*_nextor214.rom` (sony, 37c7975).
3. Why ASCII 2.20 skips SD Snatcher's boot sector — academic now.
4. The FS-A1GT SRAM-disk option inside the retained driver prefix: harmless in
   openMSX, never exercised.
5. Copyright: the synthesized ROM is ASCII + Microsoft + Sony (+ Panasonic
   prefix on the GT) code with 34 patched bytes of ours; the user treats these
   as abandonware, same as the firmware dumps already in the ROM store.

---

## 8. Chronology, for the record

* 09-22 — a7cde96 (cpuswap SETTLE rate hold) built as `20260922c_settlehold`;
  boot deaths gone by eye, 0/20 vs 0/20 in an automated `load_core` test (which
  therefore could not distinguish the builds).
* 09-22 — Illusion City hang captured on 22c (event ring); ninth transfer's
  destination found to overlap the stack; also reproduced on 22a.
* 09-23 — sony session reproduces it in openMSX with a pack-equivalent machine;
  the combination WD2793 + ASCII 2.20 isolated; ALL_SEG ruled out; loader path
  and SP difference measured.
* 09-23 — SD Snatcher matrix over the 13 Panasonic packs with an FDC: only the
  DOS 2.20 packs fail; confirmed on the board by the user.
* 09-23 — Options weighed: patch 2.20 (only half the problem), TC8566AF RTL
  (+350–450 ALM, 1–2 weeks, but a reference exists), synthesized ROM (chosen),
  Nextor (manual DOS 1 mode only).
* 09-23 — Static contract extraction, 34-patch synthesis, `BankedSonyFDC`
  verification; core block type implemented and benched.
