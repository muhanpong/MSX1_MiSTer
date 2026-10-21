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
