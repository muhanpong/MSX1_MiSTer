# SCC+ register-stream replay harness

Feeds openMSX's real SCC+ register writes into our RTL and compares against a
tick-accurate openMSX-algorithm reference.  See
`docs/scc_replay_measurement_20260904.md` for method and findings.

- `passingb_A_regstream.log.gz` — captured A-slot writes, `SC PASSINGB.SDT` on
  Sony_HB-F1XV2MB + 2×scc+.  Lines `W <t_seconds> <addr> <val> <slotbyte>` plus
  `SYNC <t>` marking record start.
- `passingb_A_openmsx_solo.wav` — the matching openMSX solo recording (44.1k).
- `render_ideal.py` / `render_ideal_ch.py` — openMSX-faithful renderer (validated
  +/-0.2 dB vs the wav).  Edit the hardcoded J=... tmp path before use.
- `tb_sccreplay.sv` — Verilator replay TB (use `verilator --binary --timing -O3`;
  iverilog is ~100x too slow).  SAMPLES_PATH / EVENTS_PATH substituted at build.
- `compare_replay.py` — band-energy comparison of an s16 render vs the wav.

Preprocess the log into `replay_events.txt` (`<tick> <addr_lo_hex> <val_hex>`,
tick = round((t-SYNC)*3579545), min 4-tick gap, slot==1 only) before feeding either
the TB or the renderer.
