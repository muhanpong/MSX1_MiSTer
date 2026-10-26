# Geo3D -- upstream sources, unmodified

- Source: https://github.com/hra1129/V9968_Cartridge , commit 4c7fa6a (fetched 2026-10-22),
  path `fpga/V9968_Cartridge_TangNano20K/src/geo3d/` -- geo3d v2.0 by Alex Moncks
  (https://github.com/alexmoncks/V9968_Cartridge/tree/main/geo3d).  Licence: MIT (SPDX header
  in every file).  Copied: geo3d_bus.v, geo3d_engine.v, geo3d_core.v, readme.md
  (geo3d_z80if.v is the stand-alone phase-1 interface; geo3d_engine instantiates geo3d_core
  itself, so it is not needed).
- Rule: byte-identical to upstream (`md5sum -c ORIGIN.md5`); core-specific glue lives in
  rtl/msx.sv (MSX_V9968 branch).
- Hook-up (MSX1 core, 2026-10-22): ports 9Dh (index / status) and 9Fh (data) of the V9968's
  98h-9Fh block, through the same v9968_bus host-bus adapter; 9Eh stays with the V9968 side
  (upstream leaves it free for MegaRAM).  clk = clk_vdp 85.909 MHz, clk_eng = clk_geo
  42.954 MHz from the same PLL (rtl/pll_v9968.v outclk_3, phase 0).  The engine drives the
  V9968's ext_cmd_wr / ext_cmd_num / ext_cmd_data and reads ext_cmd_ce.

## Local change (2026-10-27, feature): flat rows as one-row HMMV (OSD "Geo3D fill (SCREEN 8)")

- `geo3d_engine.v`: input `fill_hmmv`; when set and LOP = IMP, a filled face's row is issued as
  HMMV (DX, DY, NX = pixels, NY = 1, CLR, CMD C0h) instead of LINE (NX = pixels - 1, NY = 0,
  CMD 7xh). `geo3d_bus.v` passes it through. msx.sv drives it from OSD status[35] AND the V9968
  in SCREEN 8 (1 byte per pixel), so other modes keep LINE.
- Why: V9968 RTL, HS, SCREEN 8: one-row HMMV 0.34 us + 0.063 us/px, LINE 0.77 + 0.177 us/px
  (cmdcmp/gen_g7.py). NICCC 3D frames 495-505 (sim/geo3d_perf + stream2stim): RUN time per frame
  17.1 -> 9.2 ms; the read-back pages are identical to LINE's (0 px) and to the geo3d.py model.
  texdemo (SCREEN 5) RUN times are unchanged with the switch on.

## Build switch: V9968_UPSTREAM (2026-10-27, user request)

Every local change above sits in `ifndef V9968_UPSTREAM ... `else <upstream text> `endif, generated with
`diff --ifdef` against the pristine upstream files (ORIGIN.md5 sums). Default (macro undefined) is the
MSX1 core's custom build. `V9968_UPSTREAM=1 tools/sdram128/mk_v9968_qsf.sh` (or compile.sh with that
env) builds the RTL as upstream ships it; the ports the core added (scanline_level, cmd_wait, screen_mode,
fill_hmmv) stay in both builds, unused in the upstream one, and the OSD hides the custom-only rows.
Checked 2026-10-27 with `verilator -E`: custom == the previous custom files; upstream == pristine except
those port lines. Behaviour: upstream build reproduces the double write (run_mix bench 1567/74 errors)
and ignores the HMMV switch; custom build: run_gates.sh GATES PASS.
