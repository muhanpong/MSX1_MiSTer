# YMF278B PCM v2 — Task list after 8-agent code review

## Current state (commit `d5c40c5`)

Last build deployed: **fully silent** on hardware.  Two fixes were applied
this round:

1. **HF / CPU same-slot ram_regs write race** (Agent 8 finding)
   - When `wr_slot_reg && hf_state==HF_STORE && wr_snum==hf_cur_slot`, the HF
     backfill's read of `ram_regs[hf_cur_slot]` (blocking) sees the stale
     value before the CPU's pending NBA, then writes back stomping the CPU's
     update.  Fix: use the CPU's `reg_upd` blocking variable as the
     backfill base when the slots collide.
   - This passed all 352 testbench cases.

2. **Stage B late-valid leak** (Agent 6 finding)
   - When the previous slot leaves a read outstanding in the msx.sv bridge
     and `stage_advance` fires for the next slot, the stale `mem_rd_valid`
     pulse can write into the new slot's `bytes[0]`.
   - Fix attempt: `drop_next_valid` flag armed at `stage_advance` if
     `b_state == B_WAIT_VALID`, consumed by the first raw mem_rd_valid.

## Suspected regression

The post-fix hardware state is **completely silent**, indicating the
`drop_next_valid` fix introduced a deadlock — likely because:

- Previous slot's read occupies the msx.sv bridge (state 1/2/3) when
  `stage_advance` fires.
- New slot's `B_ISSUE` pulses `mem_rd_en` while the bridge is non-IDLE.
- The bridge edge-detects on IDLE only — so the new slot's read request is
  **lost** entirely.
- `drop_next_valid` then consumes the previous slot's late valid.
- The new slot has no outstanding read and no valid to wake it from
  `B_WAIT_VALID` → permanent stall.  All slots end up stuck.

## 8-agent review summary

| Agent | Area | Verdict | Suspect |
|---|---|---|---|
| 1 | byte_addr formula | Clean | (None — matches openMSX) |
| 2 | decode_sample logic | Clean | (None — matches openMSX) |
| 3 | calc_step | Clean | (None — matches openMSX) |
| 4 | stepPtr / pos accumulation | **BUG** | Sample-A addr uses `next_pos` instead of `stage_a_reg.dyn.pos` — 1-frame phase shift, NOT primary noise cause |
| 5 | next_pos_calc loop wrap | Clean | (None — matches openMSX) |
| 6 | Stage B byte fetch sequence | **BUG** | (a) Late valid from previous slot corrupts `bytes[0]` after `stage_advance`; (b) Stage B's 5-byte fetch can exceed 64-cycle slot window under SDRAM latency |
| 7 | Pipeline propagation A→D | Clean | (None — slot index + reg fields flow correctly) |
| 8 | HF FSM / backfill | **BUG** | Same-cycle CPU+HF writes to `ram_regs[same slot]` race; second NBA wins, CPU update lost |

## Tasks (priority order)

### P0 — Get back to "noise-but-not-silence" baseline

- [ ] **Revert Stage B `drop_next_valid` fix** (the new silence-causing
      regression).  Restore commit `12a12ac`-era Stage B behavior, keep only
      the Bug 8 HF/CPU race fix.
- [ ] Confirm hardware still produces *some* PCM output (even if noisy).

### P1 — Properly handle Stage B / bridge serialization

Two valid approaches; pick one:

- [ ] **A. Back-pressure stage_advance** until previous slot's outstanding
      read returns.  Add a "bridge busy" signal (1 cycle after `mem_rd_en`
      until `mem_rd_valid`); hold `stage_advance` while it's high.  Less
      timing budget but guarantees correctness.
- [ ] **B. Track outstanding read's slot tag**.  Add a small shift-register
      of `{slot, byte_idx}` per outstanding read in the bridge round-trip.
      On `mem_rd_valid`, route data to the tagged slot/byte rather than
      `stage_b_reg.bytes[b_byte_idx]`.  Higher hardware cost, no time loss.

### P2 — Open questions still on the table

- [ ] **Agent 4** (pos shift): Sample-A address should use
      `stage_a_reg.dyn.pos` per openMSX, not `next_pos`.  Cosmetic
      difference; defer until P0/P1 done.
- [ ] **Agent 6** also flagged: time budget — 5-byte Stage B fetch can
      exceed 64-cycle slot window under SDRAM contention.  Currently
      `stage_b_bytes_done` gates `stage_c_reg.valid` so an unfinished slot
      contributes nothing (silence for that slot), not noise.  Audit timing
      report from the next Quartus build to see slack.
- [ ] **Volume scaling** (commit `38a64dc`): `[19:4]` → single slot at
      −24 dB.  If music returns and is too quiet, dial back to `[18:3]`
      (−18 dB) or `[17:2]` (−12 dB).

### P3 — Larger structural changes (only if P0–P2 don't resolve noise)

- [ ] **Split HF backfill into separate `ram_hdr_regs[24]` array** with its
      own dedicated `always_ff` writer (Agent 8's "shadow array" recommendation).
      Merge with `ram_regs` at Stage A's dispatch read.  Eliminates the
      multi-write concern entirely at synthesis level, at the cost of a
      few hundred extra registers.
- [ ] **Implement Status reg BUSY bit** wired to `cpu_mem_busy`.  Allows
      software that polls BUSY to safely write reg 0x06 sequentially.
      Required for custom-sample-uploading software at machine-speed.
- [ ] **Implement mem_access_mode=1 sound-gen halt** per spec.

## What we know for sure (do not re-prove)

- yrw801.rom is correctly loaded into SDRAM (BASIC dump confirms
  `40 18 00 00 00 FF D6 00 F0 00 0F 00` at offset 0).
- CPU memory access (reg 0x02–0x06) path is functional both for read
  and write — write 0xAB → readback 0xAB succeeds.
- `memory_upload.sv` FW header skip is **+7** (not +8) — verified by
  BASIC dump showing correct yrw801 bytes at SDRAM[pcm_rom_base+0].
- HF backfill DOES make slot envelopes work (commit `12a12ac` un-stuck
  the previous "always silent" state).
- Reg 0x02 read-back works: returns `{3'b001, wavetblhdr, mem_type,
  mem_access_mode}` — verified 0x21 hw read after writing 0x01.

## Notes for next session

The next session should resume from this file.  Start with P0 (revert the
`drop_next_valid` change), then proceed.  All 8 agent reports are referenced
in commit `d5c40c5`'s log and the 4 build logs at `/tmp/build_*.log`.
