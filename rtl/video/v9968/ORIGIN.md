# V9968 VDP -- upstream sources, unmodified

- Source: https://github.com/hra1129/V9968_Cartridge , commit 7820668b9f200ee745c6b01289f048e6a9981418 (2026-10-19),
  path `fpga/V9968_Cartridge_TangNano20K/src/v9968/*.v` (the 21 RTL files; test benches, docs and demos not copied).
- Author: Takayuki Hara (HRA!).  Licence: the header of every file (Japanese text is the formal one): redistribution
  of source keeps the notice; binary redistribution carries the notice in its documentation; no sale or commercial
  use without prior written permission.  The core's existing V9958 (rtl/video/VDP) carries the same clause.
- Rule: files in this directory stay byte-identical to upstream.  Any change for this core lives in a separate file
  (wrapper) or, if unavoidable, is listed here with the reason.
- md5 of the copied files: see ORIGIN.md5 (regenerate with `md5sum *.v > ORIGIN.md5`).
