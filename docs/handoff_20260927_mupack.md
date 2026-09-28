# Handoff 2026-09-27 — MIDI accuracy, MT32-pi, μ·PACK, ASO last line

Worktree `.claude/worktrees/readcache`, currently **detached at `origin/mupack` 8443c50**
(= origin/nextz80 fb6995a + 4 mupack commits) plus this document.  Predecessor:
`docs/handoff_20260926_midi.md`.  Reporting frame (user rule): confirmed + by what /
unknown + the measurement that settles it / user decisions.  "Conclusion/confirmed" only
with discriminating evidence, a harness proven to have run, and a stated scope.

## 0. Read first

* **Board core**: `MSX1_20260927c_mupack.rbf` (md5 2b8a3bb41d68), built from origin/mupack
  8443c50, BUILDGATE PASS.  **Hardware-confirmed by the user**: ST + slot B MU-PACK plays
  ARMI v1.02 and the Korean Illusion City μ·PACK port; OSD shows "MIDI: MU-PACK (Slot B)
  activ(e)"; CALL RAMDISK 352; 25269 bytes free.
* **Board FW packs live in TWO places**: `games/MSX1/CART_FW_*.MSX` and
  `games/MSX1/MSX/CART_FW_*.MSX`.  Both now hold the MU_PACK builds (md5 JP 4e3cd697 /
  JP_2slot e201fdf4 / EN a3b8166c / EN_2slot 6bde3678).  Originals backed up in the old
  session's scratchpad (`fw_backup_board_20260927/`, md5 04fda78c / 5d95539b / ff0ff1eb /
  87798f1b).  I replaced only the top-level copies first; the user loads from `MSX/`
  (`config/MSX1.f2`), and half a day went into chasing a "bug" that was the old FW pack.
  **Before replacing a board file: `find` every copy and read `config/MSX1.f1/.f2`.**
* Never delete an RBF.  Build only on the user's explicit "해".  Kill only literal PIDs you
  started (`~/.claude/CLAUDE.md`).

## 1. What shipped today (all on the board)

| RBF | commit | what | hardware |
|---|---|---|---|
| 20260926c_midistrobe | 7df8915 | dev_midi: one side effect per bus cycle (writes on the strobe's first clock, reads on its end); mode-3 odd N period N | user: "better, still some notes missing" |
| 20260927a_mt32pi | 4815a4b | MT32-pi on the USER port (page under menumask 'F', 1:1 saturated audio, LCD overlay, hanging-note quiet); USER-side MIDI IN from mt32pi (pin 0 = the Pi's I2C SDA no longer read as MIDI) | page shows, Illusion City opening enters with the Pi attached, Pi plays correctly |
| 20260927b_buildid | fb6995a | build.sh writes build_id.v before map (OSD date was stuck at 260914 since abf2b54) | — |
| 20260927c_mupack | 8443c50 (origin/mupack) | μ·PACK in slot B (see §3) | ARMI + Illusion City port play |

origin/nextz80 = fb6995a (pushed).  origin/mupack = 8443c50 (not merged).
origin/pcm-mlab = msx1-audit's PCM MLAB work (not merged, not cross-checked here).
*(Superseded later the same day -- see §7.)*

## 2. MIDI — what is known

* Board byte stream (26c, MidiLink UDP capture) = openMSX GT midi-out-logger for the first
  60,951 bytes (97 %), all 104 SysEx included; the divergence is a scene cut 355 bytes
  later in the song loop.  Inter-byte timing not compared.
* MT32-pi plays without missing notes (user by ear) → the remaining note loss is most
  likely downstream in MidiLink LOCAL mt32d (ARM MUNT).  Not A/B'd: `DELAYSYSEX=TRUE` in
  `MidiLink.INI`, ARM load.
* Not confirmed on hardware: MT32-pi page status bits 120-126 (Synth/ROM/SoundFont/Reset)
  actually reach the Pi; LCD overlay; info popup; hanging-note quiet.
* Known wrong, not fixed (MIDI IN only): 8251 receive samples at the bit boundary; receive
  completion vs E8h read on the same edge loses the byte.  KNOWN WRONG note in midi.sv.

## 3. μ·PACK (origin/mupack 8443c50) — design as agreed

* Priority GT built-in (DEV_MIDI) > MU-PACK (E2h-controlled) > OSD `O[24]` MIDI (MIDI
  Interface 3).  One dev_midi instance (there is one physical MIDI OUT).
* Slot B list index 5 = MU-PACK (0-4 unchanged).  cart_typ_t widened to 4 bits.  Expanded
  slot: 2-1 = own 256 kB msx2_ram_mapper (16 blocks; own instance because of the size
  mask, not the registers — FC-FF writes reach every mapper, read-back ANDs), 2-2 =
  mu-pack.rom @4000h (FW pack ID 9), both rows carry DEV_MIDI_EXT so MIDI survives a FW
  pack without MU_PACK.
* Menu: menumask 9 = MIDI fixed, 10 = GT (freed by H9→h7, HA→h8).  OSD MIDI row hidden with
  a notice line when GT or MU-PACK; GT cannot pick MU-PACK (second slot-B line); a saved 5
  on a GT keeps the built-in (slot B still shows the ROM/mapper — upload order, accepted).
  Sub-slots On ignores MU-PACK (as MFRSD in slot A).
* Verified: MIDI benches ×4, lint, pins, run_fwsearch (NOFIX 0→4), fullsys run_mupack.sh
  18/18 (and S1 with the real mu-pack.rom), board as in §0.
* **Not yet checked on the board**: GT pack shows "FS-A1GT built-in active" and no MU-PACK in
  the slot-B list; SLOT A/B sub-slots pages after the h7/h8 change; DOS2 mapper total
  (+256 kB).
* Detection facts (openMSX disassembly): ARMI v1.02 and the Illusion City μ·PACK patch share
  one routine — 002E bit0 (GT) → 002D≥3 → RDSLT 401Ch "MIDI" over slot IDs 80h-8Fh → OUT
  (E2),00 / OUT (EA),00.  MIDRY /I5 needs no ROM (probes E9h, writes E2=00 itself);
  /I52-54 need two MSX-MIDI systems and MIDRY expects the μ·PACK at E0h-E1h (E2 bit0=1),
  which nobody sets — "I/F not found" even on GT+μ·PACK in openMSX.

## 4. Decisions waiting on the user

1. Merge origin/mupack into nextz80 and push (core feature hardware-confirmed).
2. Bring in origin/pcm-mlab (msx1-audit: ced5ea1 MLAB, 76c16a4 stress bench + mutants,
   61da7ae drops the two 10999 baseline lines; claims golden 8/8, ~29.6k ALM on an older
   base vs 32,304 now).  Cross-check before building.  Open hole they admit: nothing checks
   the reset width from ABOVE (a longer reset swallowed load_sram on 24b); the top-level
   ≥63 clk check (tb_uphold case R) is not on origin.
3. Commit msx-machine-expert's review doc into mupack docs/ (their file:
   `…MSX1-MiSTer-sonydos2/…/scratchpad/mupack/REVIEW_mupack_20260927.md`).
4. msx1-audit's 256 kB mapper unit test (tb_mapper16.sv) is only in their scratchpad.

## 5. Closed / parked today

* **ASO + GT last scan line flicker — user decided to close ("덮기로")**.  If the user
  reports it again, say first: re-examined 2026-09-27, closed.  Cause (openMSX + board):
  the busy-wait at 6D29 (`ld a,4/djnz/dec a/jr nz`) runs faster on our R800 so the playfield
  return lands before the frame ends.  Workaround disks on the board:
  `DSKS/ASO_WAIT/*_wait07.DSK` (07 is the smallest value that clears it; up to 14 no top
  breakage).  Memory: project_aso_lastline_flicker.
* GT/ST 3-3 firmware SRAM: RTL exists (050965e) but no pack declares 3-3 → not active.
* Illusion City disks: `I-City(k)(1-8)_muPack_fix.dsk` (Korean, μ·PACK patch ported),
  JP + IPS `(muPack_fix).dsk`, `ARMI102_MIDI11.DSK` (DOS2 boot + ARMI v1.02 + MIDI-11.LZH
  contents).  Translations: `~/Downloads/midry106/MIDRY106_KO.TXT`, `MIDRY106_1ST_KO.TXT`.
* `docs/TODO_mt32pi.md` is now mostly done; its open items are the unconfirmed page bits.

## 6. Other sessions

* msx1-audit (Remote Control, another machine): implemented mupack; pushed pcm-mlab.
* msx-machine-expert (local): reviewed mupack, generated the FW packs.
* midi-expert (Remote Control): informed of 27a resources.
* "MULUB/MULUW and SendUserFile findings": waiting to push 23 local commits incl. a72ed9e;
  their fullsys/tb_msx.sv edits and msx1-handoff's uncommitted tb_msx.sv/stubs.sv overlap
  e6ea084.

## 7. Update, later on 2026-09-27 (stable_Turbo-R, after the handover)

* **Merged and pushed to nextz80**: mupack (fast-forward, feeecdc), then the
  review doc (b0af284), `sim/run_reset_width.sh` (846586e: rst_hold must stay in
  6..63 clk21m -- the MLAB sweep's 24 clk_sdram from below, the save benches'
  63 from above; `--selftest` makes two wrong copies fail), then **pcm-mlab as a
  merge commit f9294c8**.  pcm-mlab was re-run on this PC first: golden 8/8,
  lockstep 64/64, `run_stress.sh` PASS (193 logs, mutants 4x32/32 fail,
  reset_len=8 fails, event counts equal to the README's).  Not built yet.
* **The MLAB engine did reach hardware once**: `MSX1_20260926_v2b.rbf` (built on
  msx1-audit's machine, md5 e1310957, copy in `~/Downloads`), sent by SendUserFile
  and later deleted from the board by the user.  That tree still had `midi_int_n`
  undriven and USER_IN[0] read as MIDI IN; the user reports nothing wrong beyond
  MIDI-IN.  Board identity rests on the Downloads md5, so: hardware observation,
  not an A/B.
* **Hardware confirmed by the user (27c_mupack, 27a_mt32pi)**: GT pack shows
  "FS-A1GT built-in active" and slot B cannot take MU-PACK (§3 item, review plan
  #9); every MT32-pi page function (status bits 120-126, LCD overlay, info popup,
  hanging-note quiet); the remaining MIDI note loss was in MidiLink's mt32d and
  the user has fixed it there (details not recorded here).
* **msx1-audit handed over to msx1-audit2** (pcm-mlab, mupack, S3 flash save,
  reset-width guard).  Read "msx1-audit" in §4/§6 as msx1-audit2.  They own the
  `run_neg.sh` defect (no compile step; mutants m1-m3 no longer build against the
  new TB) and `tb_mapper16.sv`; both wait on their user's push approval.
* **20260927d_pcmmlab** (a1026c8 = f9294c8 + the GT slot-B line listing
  "MU-PACK (RAM/ROM only)"): BUILDGATE PASS, 30,101 ALM (72 %, was 32,304),
  u_pcm 2,662, map.rpt 10999 = 0, fit.rpt RAM summary: all 11 pcm_mlab24 in
  MLAB, worst slack all positive (slow setup +0.090).  md5 d70bcf5bf616.
  **Hardware (user)**: GT label shows as intended; OPL4/PCM plays; save
  auto-load and save both work.  The MLAB engine is closed on hardware.
* Review plan closed: #10's sub-slot pages show after the h7/h8 change (user,
  27d); #1 is implied by #3/#4 matching openMSX's absolute values; #7 was seen
  during the old-FW-pack chase (no ROM, no menu); #8 is covered by fullsys
  S1/S3 and no board pack lacks MU_PACK.  Only the uncommitted
  `docs/aso_bgm_opl2_alias_20260915.md` edit from the previous session remains.


## 8. 2026-09-28: one OPLL, a boot failure that was not the OPLL, and an SDC hole

* **365ef58** merges the three IKAOPLL instances into one (user decision: the
  YM2413 is an I/O device at 7C/7D, one per machine).  −1,262 ALM.  Bench
  `sim/opll_single/` (6 scenarios + mutant), landmine row `opll`.
* **28a_opll1 did not boot** (logo, then nothing, on GT and on a Daewoo with no
  OPLL).  27d booted.  Debug overlay vs a 27d baseline: RST38 spin 0→17 (0038
  read as FF), "C3 seen at 0038" 1→0, rampage origin 5FE7→BFFF, jump-to-0000
  from 4170→FD9A (H.KEYI), one reboot.  Everything else identical: memory bytes
  were being misread.
* **Cause** (msx1-audit2 reproduced the same placement on their machine):
  `MSX1.sdc:47 set_multicycle_path -end 6 -to {*sdram*ch2_*}` has no `-from`,
  so it also relaxed the read cache's stage-2 paths in sdram.sv (cmem →
  ch2_saved_data and six siblings), which are true single-cycle clk_sdram paths
  that the file's own comment says must stay outside the exception.  Quartus
  never tried to meet them; 27d's placement happened to (+), 28a's did not
  (−4.206 ns at 1 cycle, +54 under the exception).
* **Fix, 28b_ch2mc** (msx1-audit2, their machine): two SDC lines
  `-from {*sdram:sdram|*} -to {*sdram*ch2_*}` setup -end 1 / hold -end 0, and a
  REL row `SD_int_to_ch2` (11.641 ns) in relations.tcl.  All seven targets
  close (+2.38 .. +3.49), signoff all positive (slow setup +0.462).  Negative
  control: the same fit with the HEAD SDC makes the new REL row FAIL
  (69.846 vs 11.641).  **Hardware (user, 19:06): boots, RST38 spin 0, no
  reboot, no jump to 0000; the single OPLL plays (listened, same day).**
  Commit/push by msx1-audit2.
* Lesson for the landmines: a `-to`-only wildcard multicycle relaxes every
  same-named internal path too.  Assert the intended relationship with a REL
  row so signoff fails when the exception swallows something new.
* Not measured: the same path's slack on the 27d fit (the comparison fit was
  stopped); the twelve M10K that moved outside the OPLL between 27d and 28a.

## 9. 2026-09-28/29: turbo R follows the pack, a CPU page, MIDI IN cut

* **Symptom**: an FS-A1F told Z80BENCH it was a turbo R.  "Turbo R features"
  (status 117) was OSD-global; with it On, turbor.sv overlaid BIOS byte 002Dh
  with 03 on any machine.  User: now that real turbo R packs run, the MSX2+
  masquerade has no use.
* **e46accc**: memory_upload latches byte 002Dh of the ROM that lands in slot
  0-0 page 0 into `bios_config.ver` (0/1/2/3 = MSX1/2/2+/turbo R; FF until
  read; first record wins).  `turbor_en = (ver == 3)`.  The 40h/41h Panasonic
  turbo request stays gated on ~turbor_en.  OSD: the four CPU rows become page
  P6 "CPU", masked by 'D' = pack is turbo R (plain MSX: Z80 Speed only; turbo
  R: CPU Auto/Force, both ladders, R800 VDP access wait moved from Video).
  Status bits unchanged; masks D/E (hide the unused ladder) retired, E free.
  turbor.sv untouched.  Bench `sim/fullsys/run_packver.sh`: ST DOS2 -> 03,
  Daewoo CPC-300 -> 01, Sony HB-F1XV -> 02, ST with 002Dh patched to 01 -> 01
  (negative control), one latch each.  Landmine row `turbor_pack`.  The sample
  packs live in `sim/fullsys/packs/` (gitignored, d8d36d6) so the gate can run it.
* **ad7db57 MIDI IN disconnected**: hot-plugging the MT32-pi under Illusion
  City (MIDI mode) froze the machine -- overlay RST38 spin saturated at 0038.
  Until detection, mt32pi.sv hands USER_IN[0] (the Pi's I2C SDA) to the 8251
  as MIDI IN; the game has RTS on and never reads E8h, so one stray byte is a
  permanent RxRDY interrupt.  Nothing needs MIDI IN today, so MSX1.sv holds
  `midi_rx` at 1.  Bringing it back needs a settle time after any source change.
* **29a_cpupage** (ad7db57+d8d36d6): BUILDGATE PASS, 28,943 ALM, M10K 436, slow
  setup +0.372, REL SD_int_to_ch2 +2.374, no new warnings.  Two gate stumbles
  worth remembering: the new bench looked for packs outside the tree (fixed by
  the cache), and `--expect 'rec_bios'` gave a false FAIL because --expect
  matches fit.rpt instance names, not registers (the 0923 note said so); the
  latch was confirmed by `bios_config.ver[..]` in fit.rpt, then
  `--signoff-only` re-ran timing for a PASS log.
* **Hardware (user, 03:25)**: non-turbo R machine: Z80BENCH "MSX2", no F2
  TurboR item; OSD CPU page shows "Z80 SPEED 3.58MHZ" + BACK.  Still to see: the
  four rows on a GT pack, MT32-pi hot-plug not freezing, saved CPU settings.
* Also noted: the board's `Daewoo/Daewoo_CPC-400S.MSX` (2026-05-24) is an older
  "MSx" file the upload FSM rejects at the first header.
