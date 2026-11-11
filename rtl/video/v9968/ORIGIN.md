# V9968 VDP -- upstream sources, unmodified

- Source: https://github.com/hra1129/V9968_Cartridge , commit 419d1ffd (2026-11-04; first copied at 7820668b9f200ee745c6b01289f048e6a9981418, 2026-10-19),
  path `fpga/V9968_Cartridge_TangNano20K/src/v9968/*.v` (the 21 RTL files; test benches, docs and demos not copied).
- Author: Takayuki Hara (HRA!).  Licence: the header of every file (Japanese text is the formal one): redistribution
  of source keeps the notice; binary redistribution carries the notice in its documentation; no sale or commercial
  use without prior written permission.  The core's existing V9958 (rtl/video/VDP) carries the same clause.
- Rule: files in this directory stay byte-identical to upstream.  Any change for this core lives in a separate file
  (wrapper) or, if unavoidable, is listed here with the reason.
- md5 of the copied files: see ORIGIN.md5 (regenerate with `md5sum *.v > ORIGIN.md5`).

## Local changes (2026-10-21, user request: scanlines adjustable like the core's other VDP output)

Two files differ from upstream; ORIGIN.md5 keeps the upstream sums, so `md5sum -c` lists exactly these two.
- `vdp_video_out.v`: input `has_scanline` (upstream tied 1 in vdp.v) -> `scanline_level[1:0]`; the dim line's
  gain is fixed 96/64/32 (25/50/75%) instead of upstream's brightness-dependent `w_scanline_gain[9:3]`;
  level 0 = no scanlines (upstream has_scanline = 0); interlace handling unchanged when level != 0.
- `vdp.v`: new input port `scanline_level[1:0]`, passed to vdp_video_out.
Driven from the OSD "Scandoubler Fx" (MSX1.sv: CRT 25/50/75% -> 1/2/3, others 0).

## Local change (2026-10-22, bug): sprite request level held across a display-off

- `vdp_sprite_select_visible_planes.v`: in the hold branch (display off / outside the active
  area) `ff_vram_valid` is now cleared.  Upstream holds it: a request set on the clock before
  R#1 turns the display off (2 of 128 clocks) stays asserted until the display is on again,
  and `vdp_vram_interface` issues the sprite request before the command / CPU paths on every
  slot, so a command that reads VRAM (LRMM, LMMM, ...) waits for data for ever and the VDP
  freezes.  Found by the openMSX-V9968 trace replay (sim/v9968_replay) of SUPER CAT /
  COASTAL FLIGHT (first LRMM after `R#1=00`); reproduced on its own in sim/v9968_vram
  (`+cmd=3 +demo=1 +ct55=1 +offat=29` and `125`: STILL RUNNING; the other 126 offsets
  finish in 12.66 ms).  On the board the same ROM runs 126 times out of 128.  Worth
  reporting upstream (hra1129/V9968_Cartridge).

## Local change (2026-10-22, user request): per-command waits from outside (V9938 option)

- `vdp_command.v`: the twelve `c_wait_*` localparams (all 40) are now 8-bit slices of a new
  input `cmd_wait[95:0]`; `ff_wait_count` 6 -> 8 bits and `ff_wait_counter` 8 -> 10 bits so
  waits above 63 fit.  `vdp.v`: new input `cmd_wait`, passed through.
- The values come from `rtl/video/v9968_cmdwait.sv`: 40 everywhere (bit-identical to
  upstream; checked: the 256x128 HMMM takes 1014.61 lines before and after) or, with the
  OSD "VDP command speed: V9938" (status[127]), a table calibrated per command to openMSX's
  V9938 (sim/v9968_vram +wl=0..6: 0.970-1.007 x; Go Figure's boot HMMM 269.1 lines, pass
  boundary 259.5).  HS=1 untouched.  Not for upstream: it changes the chip's defined speed.

## Local change (2026-10-22, compatibility): display start fixed once per frame

- `vdp_timing_control_ssg.v`: `ff_top_line` (display start from LN / 50 Hz) is updated only
  at the frame boundary (`w_h_count_end && w_v_count_end`), as the V9958 does.  Upstream
  re-evaluated it on every clock: R#9 LN=0 written mid-frame (the 224-line overscan trick)
  moved `screen_pos_y` back 10 lines at once (sim/v9968_vram `+lnsw=207`: 206 -> 197, and
  229 -> 240 when LN=1 comes back), so Knightmare 224's HUD showed 10 lines low.  The end
  of the active area still follows LN live (the trick needs that).  Worth reporting upstream.

## Local change (2026-10-22, bug): an interrupt event on the clock of a status read is lost

- `vdp_cpu_interface.v`, the interrupt-flag block: upstream used one `if (port-1 read) /
  else if (port-4 write) / else { events }` chain, so a line match (a one-clock pulse), the
  frame interrupt or the command end that fell on the clock of a status read (any S#n) or
  a Port#4 write never set its flag.  The clears are now applied first and the events after
  them in the same clock (the events win).  ASO 224 waits for FH (R#19 = C6h) by polling
  S#1: a lost FH left it waiting for ever -- the black screen after SPACE on the board,
  V9968 build only (the V9958 build and openMSX V9958/V9968 run it).
  sim/v9968_vram `+aso=30`: unfixed 11 waits never answered (every stage, ~1 in 11 FH),
  fixed 0.  Worth reporting upstream.

## Local change (2026-10-24, bug): FH survives the frame interrupt (ASO 224 black screen)

- `vdp_cpu_interface.v` (~920): upstream cleared FH (`ff_line_interrupt`) on `clear_line_interrupt`
  (= the frame-interrupt timing, vdp_timing_control_ssg.v:250/431) and on `intr_frame`.  That clear
  is gone; FH is still cleared by the S#1 read (unchanged), port #4 bit1, and an R#0/R#19 write.
  openMSX resets irqHorizontal only at reset, on the S#1 read with IE1 on and on an R#0 write that
  turns IE1 off; this core's ESE VDP removed the same clear for the same game
  (rtl/video/VDP/vdp_interrupt.vhd:120-140).
- Why it matters: ASO's line-104 handler sets R#19 = D2h and R#9 = 212 lines.  FH is set at line
  210 and the frame-interrupt timing comes 1248 clk_vdp (14.5 us) later; the game's IRQ path
  (0038h -> H.KEYI FD9Ah -> 80BBh, S#1 read at 80F2h, callback 058Bh only if bit0) needs ~48 us on
  this core's R800 (~87 us in openMSX), so it always read FH = 0, never ran phase BAh, never set
  (9402) and the main loop spun at 065Dh for ever (board overlay of b90a9d4: R800 last fetch 0660h,
  1 INTA per frame, R#0/R#2 unwritten for 576 frames).
- Bench: sim/v9968_vram `+ie1=6 +ie1line=D2 +ie1r9=80 +ie1dly=<clk>`: upstream reads FH = 0 in 6 of 6
  frames at 20 / 48 / 90 us and 0 of 6 at 5 / 10 us; fixed: 0 of 6 at every delay.  Control line 68h
  at 48 us: 0 of 6 on both.  Worth reporting upstream (hra1129/V9968_Cartridge).

## Local change (2026-10-29, bug): FH arms only while IE1 is on (Knightmare 224 v2 does not run)

- `vdp_cpu_interface.v` (~980): upstream sets FH on every line match, whatever IE1 (R#0 bit4) says;
  only `int_n` is gated.  The frame-interrupt clear (removed above for ASO) used to wipe that stray
  FH before a VBLANK handler could see it.  With the clear gone, FH set at the R#19 line while IE1
  is off stays set into VBLANK.  Now the line match sets FH only with `ff_line_interrupt_enable`.
  openMSX does the same (VDP::execHScan: `if (controlRegs[0] & 0x10) irqHorizontal.set()`), and so
  does this core's ESE VDP (vdp_interrupt.vhd, the Zanac-EX note).
- Why it matters: Knightmare 224 v2 (knightmare_ex src/bank4.asm `isr`) reads S#1 first and takes
  FH = 1 as a line interrupt; in its 192-line mode (IE1 off, frame interrupt only) that path ends
  in `isr_s0` and the game frame (G_FRAME) never runs.  rbf 20261024b..20261027a (b82ef60 and
  later) did not start the game; 20261024a and earlier did, because of the frame-time clear.
- Bench: sim/v9968_vram `+fhoff=6` (IE1 off, R#19 = 68h, R#1 = 62h; the VBLANK handler reads S#1
  first): before 6 of 6 frames read FH = 1, fixed 0 of 6.  Gate `run_fhoff.sh` (mutant = the gate
  removed, must read FH = 1), now part of `run_gates.sh`; `run_irq.sh` (ASO, IE1 on) still passes.

## Upstream sync (2026-10-24): 8a37b33 "Modified" -- horizontal display width

- upstream changed two lines in files that also carry local changes, so they were applied by hand
  (ORIGIN.md5 now holds 8a37b33's sums for these two files; every other file is still 7820668):
  `vdp_video_out.v` active area / h_en 1600 -> 1440 clocks; `vdp.v` bilinear scaler
  `reg_denominator` 200 -> 180, `reg_normalize` 41 -> 46.  The other upstream commits since 7820668
  (31d82b8 detect tool, a678a53 system controller + updater) touch no file copied here.

## Local change (2026-10-27, feature): screen mode output for Geo3D's HMMV fill

- `vdp.v`: new output `screen_mode[4:0]` = `reg_screen_mode` ({M5,M4,M3,M2,M1}); msx.sv enables
  Geo3D's HMMV rows only in SCREEN 8 (11100). No behaviour inside the VDP changes.

## Local change (2026-10-25, bug): a host request latched while busy ran twice (a85c175)

- `vdp_cpu_interface.v`: the host-bus latch also requires `!ff_busy`, like `bus_ready`. Upstream latched
  on `ff_bus_ready` alone, so a write the host held during a busy VRAM access ran on the edge busy fell
  and again when the host saw bus_ready: the byte written twice, later addresses +1 (SUPER CAT / PRISM
  FLIGHT glitches; board LRMMWR). Gate: sim/v9968_vram/run_mix.sh.

## Build switch: V9968_UPSTREAM (2026-10-27, user request)

Every local change above sits in `ifndef V9968_UPSTREAM ... `else <upstream text> `endif, generated with
`diff --ifdef` against the pristine upstream files (ORIGIN.md5 sums). Default (macro undefined) is the
MSX1 core's custom build. `V9968_UPSTREAM=1 tools/sdram128/mk_v9968_qsf.sh` (or compile.sh with that
env) builds the RTL as upstream ships it; the ports the core added (scanline_level, cmd_wait, screen_mode,
fill_hmmv) stay in both builds, unused in the upstream one, and the OSD hides the custom-only rows.
Checked 2026-10-27 with `verilator -E`: custom == the previous custom files; upstream == pristine except
those port lines. Behaviour: upstream build reproduces the double write (run_mix bench 1567/74 errors)
and ignores the HMMV switch; custom build: run_gates.sh GATES PASS.

## Local change (2026-11-01, bug): R#25 MSK hides sprites at screen X 0-7 (WBML V9968 dashboard)

- `vdp_timing_control_sprite.v`: the sprite colour enable is cleared while R#25 MSK is on and the
  palette's latch position (`screen_pos_x[13:4]`) is below 15 -- the same screen column where the
  bitmap's mask ends (bitmap dot 8 and a sprite at X=8 both land there). Upstream (still in v0.93,
  bee8f7e) takes `reg_left_mask` but never uses it; the palette's gate with the background enable
  ends one dot early in sprite mode 3 and not at all in modes 1/2, so sprites at X 0-7 showed in the
  masked strip. openMSX draws the strip as border (VDP::getLeftBorder): no sprites. Found from
  knightmare-v2's WBML V9968 port (dashboard sprites at X=0 one dot left of the bitmap bands), its
  openMSX register/VRAM dump replayed in sim/v9968_vram (+stt). Gate: sim/v9968_vram/run_spmask.sh
  (one-dot sprites X=7 hidden / X=8 shown, modes 2 and 3; mutant mask at 14 must fail).
  256-dot modes only (2026-11-02): in G5/G6 this core's bitmap mask ends half a dot before column 15,
  and the GT boot logo covers that gap with blue sprites over a black bitmap; the first version
  (rbf 20261101a) masked sprites there too and opened a one-pixel black column in the logo animation
  (board). Found by replaying an openMSX GT boot trace (sim/v9968_vram +rpl, +ppm frame dump) on the
  old and new RTL. G5/G6 keep upstream's behaviour; run_spmask.sh adds the G5 case (mutant
  SPRITE_MASK_ALLMODES = the 20261101a rule must show the bitmap gap). GT logo replay: 28 frames
  identical to the 20261029d RTL.

## Upstream merge (2026-11-05, user request): 7820668 / 8a37b33 -> 419d1ff

Three-way merge of the five RTL files upstream changed (vdp.v, vdp_color_palette.v, vdp_command.v,
vdp_cpu_interface.v, vdp_video_out.v; base 7820668, or 8a37b33 for the two files hand-applied on
2026-10-24). Checked both ways: resolving V9968_UPSTREAM gives 419d1ff exactly (apart from the ports
the core added, kept in both builds); the custom build equals a separate merge of the custom sources.
- Upstream now holds a host request in ff_bus_valid until ff_busy falls (bus_ready = ~ff_bus_valid),
  its own fix of the double write; our a85c175 latch condition is retired. run_mix.sh's mutant now
  releases the held request while ff_busy is up.
- New upstream ports: bus_write_done (left open) and ext_cmd_fill_span (tied 0 in msx.sv and the
  benches: our Geo3D engine does not drive it; the core's own OSD HMMV path stays).
- Also in: LMCM reads (SX, SY) and its HS wait, YJK/YAE palette fixes, the Geo3D fill-span HMMV
  conversion in vdp_command.v, h_en_start 748 -> 749.
- ORIGIN.md5 now holds 419d1ff's sums.

## Upstream fix taken early (2026-11-11): the 16th sprite of a line

- `vdp_sprite_makeup_pixel.v` is upstream 1df063f ("Bugfix CC=1 sprite", 2026-11-08), not
  419d1ff; the other files stay at 419d1ff.  ORIGIN.md5 still holds the 419d1ff sum for it.
- Plane N is selected in sub-phase N and reaches `ff_color_*` in sub-phase N+4, but the
  mixer started a dot at sub-phase 3: the 16th plane (sub-phase 15 -> 3) was taken as the
  FIRST plane of the next dot -- drawn one dot to the right and on top of every other
  sprite.  Lines with 15 sprites or fewer were unaffected (the 16th slot is inactive).
  Seen on the board in WBML V9968: the right wall (16th sprite) under a 12-column text box.
- Gate: `sim/v9968_replay/run_spr16.sh` (N = 13, 15, 16, 17 PASS; with the 419d1ff file
  N = 16 and 17 FAIL: runs `213:13 226:16` instead of `213:14 227:14`).
- Not taken: c71bc9d (R#23 latched at line start for the sprite Y test) and the rest of
  419d1ff..2a99ac9 (v0.94-v0.99) -- a full upstream merge is a separate step.
