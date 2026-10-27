# Geo3D: flat rows as HMMV in SCREEN 8 — material and upstream TODO (2026-10-27)

In this core (custom build, 59dcd96 / b1fff1f): OSD "Geo3D fill (SCREEN 8)" = LINE (default) / HMMV;
active only with the V9968 in SCREEN 8 and Geo3D LOP = IMP. Release rbf 20261027a (f227328).
Upstream checked 2026-10-27: hra1129 main (geo3d last changed 7820668, v2.0.0) and alexmoncks
geo3d-v2.0 (d354695) both issue LINE only; no issue/PR about it (alexmoncks has issues disabled;
the Geo3D discussion lives in hra1129 issue #9).

## TODO (separate from the core's work; nothing posted, nothing pushed)

- [ ] Upstream-style patch on the pristine v2.0 `geo3d_engine.v`: enable by a Geo3D register bit
      (a free CTRL/XCTRL bit) instead of the core's OSD + V9968 screen-mode port, so no V9968
      change is needed; software turns it on because it chose SCREEN 8 itself.
- [ ] Verify that patch with upstream's own benches (`gen_scenes.py`, filled/textured scenes):
      bit-exact with the bit off, identical VRAM with it on in SCREEN 8.
- [ ] English proposal text for hra1129 issue #9 with numbers only (user 2026-10-27): the
      per-row LINE/HMMV fits (synthetic bench) and the NICCC 3D frame times named as a scene,
      plus the patch inline. No video, ROM or model data attached (PICONICCC models have no
      licence file; putting them into an upstream repo would need Megus's OK). User posts it. Push of V9968_Geo3D (59dcd96, b1fff1f, f227328) only if a link is wanted.

## Numbers (V9968 RTL in sim/v9968_vram's bench, SCREEN 8, R#20 HS = 1)

`gen_g7.py` writes the command file; run the bench built from `sim/v9968_vram/tb_v9968_vram.sv`
with `+m128=1 +cmdf=cmds_g7.txt`. Per-command times in `rtl_g7_rows.txt` (ps). Linear fits:

| command (one row) | fixed | per pixel | 200 x 32-px rows, mean |
|---|---|---|---|
| LINE | 0.77 us | 0.177 us | 6.36 us |
| HMMV | 0.34 us | 0.063 us | 2.39 us |

## A real scene (NICCC 3D, frames 495-505, 3 RUNs a frame)

`sim/geo3d_perf` (+hmmv, Q page read-back op) driven by `~/data/msx_niccc_3d/tools/stream2stim.py`.
RUN times in `niccc3d_f495_505_{line,hmmv}.txt`: per frame 17.1 ms (LINE) -> 9.2 ms (HMMV).
Pages read back after frames 500 and 505: LINE and HMMV identical (0 px), and equal to the
niccc_3d `geo3d.py` model; negative control frame 500 vs 505: 36,914 px differ. texdemo (SCREEN 5)
RUN times identical with the switch on (mode gate works).

## The core's change

`core_custom_vs_upstream_geo3d_{engine,bus}.diff`: the custom build against pristine v2.0 (with the
`V9968_UPSTREAM` ifdefs in place). Details and history: `rtl/video/geo3d/ORIGIN.md`.

## NICCC 3D real-time engine stream (2026-10-27)

The R800 engine's ops (msx_niccc_3d `out/rt_expect.bin`, op 08 expanded: `rt_flat.bin`) through
`sim/geo3d_perf`, four frames from each of six places, Geo3D RUN time per frame (ms):

| frames | LINE | HMMV |
|---|---|---|
| 18-21 (letters) | 9.2-9.6 | 7.0-7.3 |
| 338-341 | 16.9-17.2 | 8.2-8.5 |
| 698-701 | 15.8-16.2 | 7.2-7.4 |
| 998-1001 | 13.3-13.4 | 6.1-6.2 |
| 1298-1301 | 13.2-13.4 | 6.2-6.4 |
| 1698-1701 (cubes) | 18.3-18.5 | 10.8-11.0 |

Pages after frames 701 and 1701: LINE = HMMV = geo3d.py model (0 px); the two frames differ in
all 54,272 bytes. With LINE the RTL needs more than one 60 Hz period in three of six places, so
mode A (and mode 1) cannot hold 60 fps on the board there; with HMMV every sampled frame fits.
