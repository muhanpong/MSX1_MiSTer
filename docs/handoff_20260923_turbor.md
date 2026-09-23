# Handoff 2026-09-23 — turbo R packs: DOS 2 synthesized disk ROM, LDIR fix, MIDI stub, kanji on the R800

Branch `nextz80`, worktree `.claude/worktrees/readcache`, HEAD `b6d3d6a` (origin is one behind:
the kanji bench commit is pushed together with this handoff).  Predecessor:
`docs/handoff_20260922_turbor.md`.  The full write-up of the disk-ROM work is
`docs/turbor_diskrom_20260923.md`; read that before touching anything in it.

## 0. Read first

* **Board**: core `MSX1_20260923c_midikanji.rbf` (md5 dbb91493…) loaded, pack `Panasonic FS-A1WX.MSX`,
  sitting at a BASIC prompt with the kanji probe program in memory.  RBFs deployed today, all on
  the board and in `output_files/`: `20260923a_trfdc` (d30beb5e), `20260923b_ldirfix` (cd4194fd),
  `20260923c_midikanji` (dbb91493).  Never delete an RBF.
* **Nothing is unbuilt on this branch** (everything through `b6d3d6a` is in 23c except the kanji
  bench, which is a bench).  No Quartus process is running.
* **One open defect, reproduced and narrowed, NOT understood**: kanji ROM reads (D9h/DBh) return
  stale bytes **only on the NextZ80 (R800) path** — §3.  Illusion City's dialogue text is
  therefore unreadable on the R800 even though the game now runs.
* Two hardware confirmations still owed: GT DOS2 pack Illusion City past the loader (23c has the
  MIDI fix), and kanji readable once §3 is fixed.

## 1. What changed today (all pushed except b6d3d6a)

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
| b6d3d6a | `tb/kanji_tb.sv`: kanji.sv + real sdram.sv at Z80 INI timing — PASS (so §3 is not in those two files alone) |

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

## 3. OPEN — kanji ROM reads are stale on the R800

Symptom: Illusion City dialogue glyphs fragmented (screenshots `20260923_065003`, `072928`).

Measured with the BASIC probe (scratchpad `kanjiprobe.bas`; type it with
`tools/hinotori_rig/keyinject_remote.py --file`; it POKEs two routines at D000h: `OUT (C),H /
OUT (C),L / INIR` and a plain `IN A,(C)` loop, JIS 07FBh, prints the 32 bytes):

| core | pack | CPU | INIR | plain IN |
|---|---|---|---|---|
| 23c | FS-A1WX | Z80 | **32/32 correct** | correct |
| 23c | FS-A1WX | R800 (OUT E5,40) | **stale**: `00 08 04 04 04 04 04 04 04 47 3C 3C 3C 04 00 00 …` (right order, each new word lags; 18 distinct bytes in 32) | **all 00** |
| 23c | ST DOS2 | (R800 after DOS2 boot) | same stale pattern | all 00 |
| 0913b | FS-A1WX | Z80 | correct | correct |

Reference (msx-machine-expert, `scratchpad/dos23/ic2/kanji3.log`): JIS 07FB =
`00 08 04 04 04 47 3C 04 00 00 00 08 7C 84 08 10 04 04 04 04 04 03 00 00 20 00 00 00 10 F8 00 00`;
the game reads with exactly that `OUT/OUT/INIR` idiom (2AC1h), on the R800, 32 bytes in ~2 µs.

What is ruled out: the font file (same 5aff2d9b… as openMSX, all Panasonic 2+/turbo R share it);
kanji.sv + sdram.sv alone (`tb/kanji_tb.sv` passes at Z80 timing, also with the ROM at high
addresses); the read cache tag (26 bits); the bus-guard classification (b64aaea changed nothing
on the board); the turbo R block's decode (D8–DB are not its ports); STA (no SDC exception on
the clk_sdram → CPU data path; 23c signs off).

What is NOT known: whether the bus data at the end of the IN cycle is already stale (kanji/SDRAM
request side — e.g. `ram_addr` switching to the kanji address at the same instant `sdram_ce`
rises, which violates the "address leads the request" assumption the `-end 6` multicycle on
`*sdram*ch2_*` encodes; the T80 gets away with it) or whether NextZ80 samples DI before the
data is home (nz_bus `adv` is combinational in `wait_n`).  The plain-IN "all 00" is a second
clue nobody has explained.

Next step (proposed, not started): add ports D8h–DBh to evt_trace's recorded I/O set (one line,
`p_rd`/`p_wr` in `rtl/evt_trace.sv`), rebuild, run the probe on the R800, and read the ring:
`rd_val` is sampled at the END of each read, so it says whether the bus lags or the CPU samples
early.  If the bus lags: give the kanji read an address lead (register the kanji request one
clk21m after `ram_addr` switches, or key the `ram_addr` mux on IORQ+address before RD).  If the
CPU samples early: hold `guard_open` one clk21m after `sdram_hit`/`hs_done` for I/O reads on
`use_nz`.  SignalTap on `ram_ce/ram_addr/sdram_ce/ch2_dout/guard_open/wait_n` is the heavier
alternative (`docs/signaltap_msx1_stp.md`).

## 4. Other open items

* GT DOS2 pack + Illusion City on 23c: not yet confirmed past the loader (user tested ST).
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
