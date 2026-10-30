# V9990 (E-VDP-III)

`v9990_*.vhd` are taken unchanged from rampa069/v9990 (https://github.com/rampa069/v9990),
commit 36170c5 (2026-10-16), under its 3-Clause BSD License (see the file headers).
`v9990_vram_bram.vhd` is the upstream block-RAM VRAM (512 KB; not used here, the VRAM is in SDRAM).
Local changes:
- `v9990_vram_cache.vhd`: posted writes (ports `w_room` / `w_post`).  When the
  wrapper's queue has room a write is acked the next clock, like the block RAM,
  instead of waiting for the memory; the 3D demo's full-screen LMMV went from
  12.4 ms to 9.2-9.6 ms on the SDRAM path (8.9 ms with ideal block RAM).  With `w_room` low the original
  m_req / m_ack write path is used.
