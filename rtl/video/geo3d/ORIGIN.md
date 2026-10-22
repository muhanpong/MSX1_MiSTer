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
