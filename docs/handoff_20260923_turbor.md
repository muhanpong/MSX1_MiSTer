# Handoff 2026-09-23 — turbo R packs: DOS 2 synthesized disk ROM, LDIR fix, MIDI stub, kanji on the R800

Branch `nextz80`, worktree `.claude/worktrees/readcache`.  Updated 2026-09-24 when §3 closed on
hardware; the kanji fix and its harness are `d031a4c`.  Predecessor:
`docs/handoff_20260922_turbor.md`.  The full write-up of the disk-ROM work is
`docs/turbor_diskrom_20260923.md`; read that before touching anything in it.

## 0. Read first

* **Board**: core `MSX1_20260923d_kanjifix.rbf` (md5 5a2d8184…).  RBFs deployed, all on the board
  and in `output_files/`: `20260923a_trfdc` (d30beb5e), `20260923b_ldirfix` (cd4194fd),
  `20260923c_midikanji` (dbb91493), `20260923d_kanjifix` (5a2d8184).  Never delete an RBF.
* **Nothing is unbuilt on this branch.**  No Quartus process is running.
* **§3 is CLOSED (2026-09-24, hardware)**: the kanji fix `d031a4c` is in 23d and the user confirms
  Japanese kanji AND the Korean patch font both render correctly.  Illusion City is now fully
  playable — this was the last of its five gates.
* **Illusion City is closed on both packs.**  The Korean translation ran on `Panasonic FS-A1GT
  DOS2-ILLUK`, which differs from the GT DOS2 pack only in the Kanji font file, so the GT DOS2
  configuration (3-2 TURBOR_FDC, MIDI, 512 KB) is confirmed on hardware too.

## 1. What changed (all pushed)

| commit | what |
|---|---|
| 7614b3a | tb_scc_subslot: drive `scc2_slot` (bench had failed since 35f3ae8; blocked precheck) |
| fb88193 / 93b621c | **TURBOR_FDC block**: `MAPPER_TRFDC`, `msxdos2.sv win_7ff0_only`, createMSXpack `TURBOR_FDC`, benches `tb_trfdc`/`tb_msxdos2`, `tools/turbor_diskrom/` (synth2.py, 34-patch json, BankedSonyFDC, logs) + ROM material |
| 9e8a30c / 90e3899 / 1789604 | docs: corrections (MFRSD kernel is Nextor 2.1.4; DOS2 block removed from 30 packs) |
| 9566a02 | qsf SEED 8 (seed 7 missed by 0.100 ns on ascal, the documented seed-sensitive path) |
| 31c130f | evt_trace: wedge timer frozen while `msx_pause` (OSD pause inside the boot delay tripped it twice) |
| 5fba913 | **NextZ80 patch 0004**: repeating LDIR/LDDR re-fetches its opcode (self-erasing fill stops as on a Z80).  cpuswap bench section L.  Capture `tools/evtrace/captures/evt_ic_dos2_halt.txt.gz` |
| b64aaea | guard: I/O read that is really an SDRAM read (kanji) takes the closed loop, not the I/O floor.  **Did not fix §3.**  Harmless, kept. |
| 913a4ab | **midi stub**: `IN A,(E9h)` decoded on `~cpu_m1` (was `cpu_m1` = only the interrupt acknowledge, so the game read FFh and took its MIDI branch).  `sim/run_midi_stub.sh` |
| b6d3d6a | `tb/kanji_tb.sv`: kanji.sv + real sdram.sv at Z80 INI timing — PASS (so §3 was not in those two files alone) |
| d031a4c | **kanji fix** (§3): latch which JIS counter the post-read increment bumps; `sim/fullsys/tb_kanji.sv` + `run_kanji.sh` (whole machine, real pack, one run per CPU); `NZ_BUS` shape in `tb/kanji_tb.sv`; landmines `kanji` |

Pack side (sony / `msx-machine-expert` session, branch `sony-dos2-3-3`, not pushed): 37c7975
(MSXDOS2 block removed from 30 packs, MFRSD ROMs renamed `*_nextor214.rom`), b920a87 (nine new
`… DOS2.MSX` turbo R packs with the TURBOR_FDC block; I copied them to the board, md5 9/9).
`tools/omsxprobe/pack2omsx.py` (pack XML → openMSX machine) lives there; it cannot handle
`<skip>` blocks yet.

## 2. Established today (do not re-derive)

1. **Illusion City "9th transfer pops 0000"** = the ASCII DOS 2.20 kernel in slot 3-3 made the
   game take a loader path whose stack sits inside the LBA-11 sector.  Not the core.  SD Snatcher
   "boots to BASIC" = the same kernel never calls the boot sector.  Both fixed by removing 2.20
   (30 packs) and giving the turbo R packs the machine's own DOS 2.30/2.31 kernel re-linked to
   the HB-F1XD WD2793 driver (`tools/turbor_diskrom/`).  openMSX (custom `BankedSonyFDC`) runs
   both games along the stock machine's path; the board confirmed SD Snatcher and, after 5fba913,
   Illusion City on the ST pack.
2. **Illusion City "hangs after the R800 switch"** = NextZ80 executed LDIR as an internal loop and
   did not see the fill erase its own `ED B0` at 801Bh; it wiped 801Dh–B5FFh and ran into FFh.
   Patch 0004.  CPIR/INIR/OTIR still loop internally (deliberately left).
3. **GT hangs, ST does not** = the game's ISR reads E9h and branches on bit 7; our stub answered
   only the interrupt acknowledge.  913a4ab.  The 2026-09-20 "E9 = 05h" commit had never worked.
4. **evt_trace ring**: its 2 s wedge counted through OSD pauses; with "Pause on OSD" on, the BIOS
   boot delay (2CAB, 1.65 s) plus the OSD time fired it at boot, twice.  Fixed in 31c130f (in 23c).
   Even so: judge a phase by SP/registers/caller, not by PC alone (2CAB is BIOS boot code, 119E is
   the BIOS PSG driver inside the BIOS ISR — both were misread before the reference settled them).
5. `build.sh --expect` takes the fit.rpt spelling (`NextZ80:NZ`, `dev_midi:`), not the module name.
6. The E6h timer works on hardware (BASIC `INP(&HE6)` advances); `CALL CHGCPU` is a Syntax error in
   BASIC on these packs (the extension lives in the missing 3-3 firmware) — use
   `OUT &HE4,6:OUT &HE5,&H40` (R800) / `&H60` (Z80); `turbor_en` is OSD-global, so this works on
   any pack.
7. A DOS 2.30-booted turbo R **runs BASIC on the R800** (the reference boots on the R800).  A
   measurement "on Z80" made after a DOS2 boot is on the R800 unless you switched.

## 3. CLOSED — kanji ROM reads were stale on the R800

Fixed by `d031a4c`, built as `20260923d_kanjifix`, **confirmed on hardware 2026-09-24**: Japanese
kanji and the Korean Illusion City patch font both render correctly on the R800.

**The defect.**  `kanji.sv`'s post-read pointer increment fires one clock AFTER `ram_ce` falls, and
it chose between the JIS1 and JIS2 counters from `addr[1]` **on that clock** — i.e. from whatever
the address bus held after the strobe had gone.

* T80s (Z80) still shows the port address there, so `addr[1]` was 0 and `addr1` advanced.  Correct.
* `nz_bus` (NextZ80 / R800) drops the strobes on the same edge that puts the NEXT stage's address on
  the bus.  That address is the following opcode fetch; when its bit 1 was set the increment went to
  `addr2` (JIS2) and `addr1` stayed put — the CPU re-read the same JIS1 byte.

One cause, both symptoms: under INIR the fetch address alternates, so each new word lagged (18
distinct bytes in 32); under a plain `IN A,(C)` loop the loop's fetch address has bit 1 set every
time, so the pointer never moved at all — the "all 00" nobody had explained.

**The fix**: latch the counter select while the strobe is high (`last_sel`).  Three lines.

**How it was found.**  Not by a probe build.  `sim/fullsys/tb_kanji.sv` runs the whole machine in
Verilator from a real `.MSX` pack with the probe written over the BIOS reset vector, once per CPU:
the R800 column reproduced the board's bytes exactly and the Z80 column was correct, so the two
could be diffed at clock resolution.  Getting there also fixed the harness blocker from
`handoff_20260922` §"fullsys": the bench's DDR3 model returned the byte at the live address instead
of latching it on the accept, so the pack header read "SX@" and the upload was skipped in silence.

**Regression**: `make -C tb kanji` now runs both bus shapes (`NZ_BUS=0/1`); the nz_bus shape fails
on the pre-fix RTL and passes on this one.  `tools/buildgate/landmines.tsv` has a `kanji` record.

**The general lesson**, worth applying elsewhere: a device that acts one clock AFTER a bus cycle
ends must latch its select signals **during** the strobe.  How long the address stays valid past the
strobe is a property of the CPU core, and this machine now has two with different answers.

**A harness trap paid for here**: `build.sh --expect` matches strings in `fit.rpt`, which is not an
exhaustive register list — `--expect 'kanji:kanji|last_sel'` GATE-FAILed on a build that did contain
the register.  Register-level presence is checked with `quartus_sta` and `get_registers`, not the
report.

## 4. Other open items

* Slot 3-3: `MAPPER_PANASONIC` exists (`050965e`, peer session) but no pack XML declares it yet.
  Parked on purpose, and **not because it is risky**: `matsushita.sv` reports port 41H bit 7 = 1,
  the front-panel firmware switch OFF with no OSD toggle, so the built-in software never runs and
  the one path that needs the unimplemented main-RAM banks (>= 0x180, `mem_unmaped` in
  `panasonic.sv`) is GT + switch ON -> MSX-View.  openMSX, 90 s boots (peer session,
  `docs/panasonic_mapper.md`): switch OFF, ST and GT both write 7FF8 non-zero 0 times; only GT
  MSX-View does, 639 times.  So turning 3-3 on today buys nothing visible — that is the reason to
  wait, and a firmware-switch toggle is what would change it.
  When it IS turned on, the first thing to get right is the SRAM size (ST 16 KB / GT 32 KB): a
  plain BASIC boot already selects SRAM block 0x81 (ST once, GT twice), and a wrong window reads
  ROM there instead, silently.
* `docs/turbor_diskrom_20260923.md` needs a §9 with the LDIR/MIDI/kanji chapter (the memory file
  has it; the doc stops at §8).
* Turbo R internal SRAM (ST 16 KB / GT 32 KB, slot 3-3 PANASONIC mapper): no block type; user wants
  it eventually.  Not related to any of the above.
* `pack2omsx.py` `<skip>` support (sony side).
* PCM engine mux cleanup: research only, gated on a golden bit-exact harness (memory
  `reference-pcm-engine-optimization`).

## 5. Peer sessions

`msx-machine-expert` (was `msx1-mister-sonydos2-1c`; openMSX reference measurements, pack XMLs —
every reference number in this document came from there), `mister-super-expert` (board file ops,
on standby), `rsrv` = `msx1-mister-40` on another machine with Quartus 17.0.2 (not a sign-off
build), a Remote Control session named "Z80 CPU 타이밍 수렴" that may still hold a withdrawn
seed-build request.

## 6. Tools that exist now

`sim/run_trfdc.sh`, `sim/run_midi_stub.sh`, `tb/kanji_tb.sv` (`make -C tb kanji`), cpuswap bench
section L (self-erasing LDIR), `tools/turbor_diskrom/` (regenerate the synthesized ROMs with
`synth2.py`; `omsx/BankedSonyFDC.*` for openMSX), landmines rows `trfdc` and `midi`,
`tools/evtrace/captures/evt_ic_dos2_halt.txt.gz`.
