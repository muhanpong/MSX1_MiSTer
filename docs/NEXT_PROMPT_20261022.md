Work in `~/data/MiSTer_build/sdram128` (branch `v9968_v9990`, never push). Report in Korean.
Read `docs/handoff_20261022_v9968_irq_geo3d.md` first, then the memory index.

1. Check the 7fcf4fe SEED 11 build (`output_files/compile_MSX1_V9968.log`).
   - On TIMING PASS: name the rbf `MSX1_20261022b_sdram128v9968_7fcf4fe.rbf` and tell me. Send it only when I ask.
   - On failure: propose a new seed, or a build with DEBUG off, and do not start it.
   - Afterwards: `git checkout -- MSX1.qpf MSX1_V9968.qsf MSX1.qsf`, regenerate MSX1_V9968.qsf with `tools/sdram128/mk_v9968_qsf.sh`, and commit it.
2. Report the VPROBE result at `/data/_claude/tmp/msx1-handoff/vp_7fcf4fe.log`. Stock and turbo must PASS and every mutant must FAIL.
3. Wait for my board results: ASO 224 starts with SPACE, km224 HUD, overlay, About.
4. Optional: the replay dark frames 510–528 (handoff §4).
