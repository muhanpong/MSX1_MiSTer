# V9968 VDP -- upstream sources, unmodified

- Source: https://github.com/hra1129/V9968_Cartridge , commit 7820668b9f200ee745c6b01289f048e6a9981418 (2026-10-19),
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

## Upstream sync (2026-10-24): 8a37b33 "Modified" -- horizontal display width

- upstream changed two lines in files that also carry local changes, so they were applied by hand
  (ORIGIN.md5 now holds 8a37b33's sums for these two files; every other file is still 7820668):
  `vdp_video_out.v` active area / h_en 1600 -> 1440 clocks; `vdp.v` bilinear scaler
  `reg_denominator` 200 -> 180, `reg_normalize` 41 -> 46.  The other upstream commits since 7820668
  (31d82b8 detect tool, a678a53 system controller + updater) touch no file copied here.

## Local change (2026-10-27, feature): screen mode output for Geo3D's HMMV fill

- `vdp.v`: new output `screen_mode[4:0]` = `reg_screen_mode` ({M5,M4,M3,M2,M1}); msx.sv enables
  Geo3D's HMMV rows only in SCREEN 8 (11100). No behaviour inside the VDP changes.
