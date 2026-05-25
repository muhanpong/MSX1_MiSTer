# YMF278B PCM v2 — Remaining Work

## Current state (commit `a3270b8`)

PCM v2 engine is functionally complete and Quartus-compiles cleanly.
**59 + 264 = 323 iverilog tests pass.**

What works:
- Pipeline (Stage A/B/C/D) with timing fixes (latches eliminated, D2 split)
- 8/12/16-bit sample decode (12-bit verified `tb_decode_12bit`)
- Pan L/R per openMSX tables (`tb_pan_lr`)
- CPU register decoder all 10 fields per slot (`tb_cpu_reg_decode`)
- HF FSM fetches headers from SDRAM ch4 (`tb_hf_fsm`)
- ROM tables converted to functions (`tb_eg_roms` confirms 264/264 values match openMSX)
- `dl_tab_rom` shift bug fixed (was `idx<<3`, now correct `idx<<5`)
- `pcm_left` saturating extraction (was `master_accum[23:8]` = ÷256, now saturated `[15:0]`)
- All path verified end-to-end in `tb_integration` (max `|pcm_left|` = 16384)

## Open issue

**MiSTer PCM output is ~43 dB below openMSX reference**, and the time-binned
RMS profile shows a flat constant low level (never modulates with music) —
not "quiet music" but "constant noise around the noise floor".

### Measured (NeonHorizon ROM, 30–40 sec capture)

| Source | Peak | RMS | Profile |
|---|---|---|---|
| openMSX PCM-only (FM/PSG muted) | -5.3 dBFS | -23.1 dBFS | varies -65 → -16 dB over time |
| openMSX FULL mix | -3.5 dBFS | -21.9 dBFS | similar (PCM dominates this game) |
| **MiSTer (FM Mute=ON, PCM Mute=OFF)** | **-50.7 dBFS** | **-65.6 dBFS** | **flat constant -65 dB ± 5 dB** |

The "flat constant" profile is the key signal. Real music would have
20–40 dB of dynamic range across 100ms RMS bins (silence → peaks). MiSTer
output has only ±5 dB variation, meaning the engine is NOT producing
note-modulated audio — it's producing roughly constant low-magnitude
data, consistent with **reading wrong/garbage bytes from SDRAM ch4**.

### Leading hypothesis: `yrw801.rom` not actually loaded into SDRAM

`dbg_pcm_base_set` (overlay row 1) lights up when
`pcm_rom_base != 27'h1800000` (default).  This *only* confirms the
`memory_upload` module changed the register — it does **not** verify
that the actual 2 MB of yrw801.rom data was successfully written to
that SDRAM region.

Symptoms consistent with this:
- Engine alive, frame_cycle ticking (overlay row 2 ON)
- Register writes reach engine (NEW2 latches, hf_pending fires)
- HF FSM reads from SDRAM at `pcm_rom_base + wave*12` — gets garbage
- → `ram_header[slot].startAddr/endAddr/bits` populated with garbage
- → Stage B fetches sample bytes from garbage addresses
- → Output = low-magnitude constant pattern (user heard "지직거리는 잡음")
- → Toggling PCM Mute drops the level (confirms it's our engine producing it)
- → No note modulation because the "samples" don't follow MIDI note events,
  they're just whatever happens to be at those SDRAM addresses

### Verification steps (start of next session)

1. **Confirm yrw801.rom file exists on the user's SD card.**
   Common paths:
   - `/media/fat/games/MSX/yrw801.rom`
   - `/media/fat/MoonSound/yrw801.rom`
   - File should be exactly 2 MB.
2. **Check MiSTer OSD for any "load MoonSound ROM" / "Wave ROM"
   option** that might need to be explicitly enabled.
3. **Watch MiSTer's serial debug / boot messages** for any
   `ROM_MOONSOUND` upload activity at boot — `memory_upload.sv:360`
   has a `$display` for "FILL RAM ID:X addr:Y size:Z kB" that should
   show a ~2048 KB upload for yrw801.rom.

If yrw801.rom is missing, putting it on the SD card and rebooting
should immediately resolve the audio problem (no rebuild needed,
since the engine already works correctly in simulation).

### Fallback hypotheses (if yrw801.rom is present and loaded)

In likelihood order:

1. **SDRAM ch4 contention causing slot drops.** In real hardware with
   CPU+VDP heavy on SDRAM ch1/ch2/ch3, ch4 round-trip may exceed
   the 64-cycle Stage B slot window. `stage_b_bytes_done` would be
   FALSE → that slot's contribution dropped from `master_accum`.
   Many slots dropping → consistent low output.

   Mitigation: widen `CYCLES_PER_SLOT` from 64 to 96 or 128 (reduces
   max slot count per frame from 24 to 16 or 12, but ensures byte
   fetches complete). Or pipeline SDRAM ch4 to allow overlapping
   requests.

2. **Synthesis quirk.** Quartus could be inferring an unexpected
   truncation somewhere. To investigate:
   - Run TimeQuest report worst paths in PCM engine
   - Check fit.rpt for any deleted `master_accum_left[N]` or
     `pcm_left[N]` bits
   - Compare iverilog tb_integration `max |pcm_left|=16384` against
     a Quartus simulation run.

3. **CPU writes to PCM regs corrupted by SDRAM ch2 timing fail.**
   We saw earlier that T80 → SDRAM ch2_addr_1 paths have -9.4 ns
   slack (worst path in fit). If CPU's writes to PCM registers
   (via I/O, not SDRAM) are reliable but the game depends on
   reading PCM RAM via CPU (reg 0x06), the read returns 0 (our
   stub) — game might misbehave because it can't verify RAM.
   Less likely to cause flat noise output.

## Diagnostic capture files

Already captured for comparison:

| Path | Description |
|---|---|
| `/tmp/neon_pcm.wav` | openmsx, NeonHorizon, PCM only (FM/PSG muted), 30 sec |
| `/tmp/neon_full.wav` | openmsx, NeonHorizon, full mix, 30 sec |
| `/tmp/mister_neon.wav` | MiSTer, NeonHorizon, FM Mute on (PCM mostly), 40 sec |
| `/tmp/2026-05-25 23-46-18.mp4` | original OBS recording of MiSTer |

Analysis script (Python, stdlib only) — measures peak/RMS:

```python
import wave, struct, math
with wave.open("/tmp/PATH.wav", "rb") as w:
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    samples = struct.unpack(f"<{n*ch}h", w.readframes(n))
left = samples[0::ch]; skip = sr * 2  # skip boot blip
L = left[skip:]
peak = max(abs(s) for s in L)
rms = math.sqrt(sum(s*s for s in L) / len(L))
db = lambda v: 20*math.log10(max(v,1)/32767)
print(f"peak {peak} ({db(peak):+.2f} dBFS)   rms {rms:.1f} ({db(rms):+.2f} dBFS)")
```

## How to reproduce openmsx capture (reference)

```bash
ROM="/home/muhanpong/Projects/NeonHorizon/archives/roms/originals/Neon Horizon v1.0 - Norakomi (2026)[MSXdev25]No16X].rom"

# Mute everything except MoonSound wave; record PCM-only 30 sec
cat > /tmp/openmsx_pcm_capture.tcl <<'EOF'
after time 2 {
    foreach d [machine_info sounddevice] {
        if {[string match -nocase "*wave*" $d]} { puts stderr "Keep: $d" } \
        else { set "::${d}_volume" 0; puts stderr "Mute: $d" }
    }
}
after time 5 { catch {record start /tmp/neon_pcm.wav -audioonly -stereo} }
after time 35 { catch {record stop}; after time 1 { exit } }
EOF

timeout 50 openmsx -machine Panasonic_FS-A1WX -ext moonsound \
  -carta "$ROM" -romtype Ascii16-x \
  -script /tmp/openmsx_pcm_capture.tcl
```

OSD setting to reproduce on MiSTer:
- MoonSound = ON
- PCM Mute = OFF
- FM Mute = ON

## Commits in this session (chronological, all under MSX2_Dev branch)

| Hash | Description |
|---|---|
| `e064ebe` | Stage B serial sequencer + Stage C decode + CPU reg decoder |
| `ba4874b` | HF FSM + Stage D + integration test |
| `8efb6e5` | real-core integration + 12-bit decode + pan L/R |
| `0aa7e1c` | Quartus timing — latches eliminated + Stage D 3-stage pipeline |
| `6da6656` | D2 split → D2a (compute tmp) + D2b (sample × tmp) |
| `a233c18` | stretch dbg_pcm_valid for reliable overlay CDC capture |
| `1279f21` | Revert diagnostic code — speakers were off |
| `78a5dac` | **fix output amplitude — saturating master_accum → pcm_left/right** |
| `934cc38` | fix iverilog build (ROM tables → functions) + amplitude threshold |
| `a3270b8` | **fix `dl_tab_rom` shift count + add ROM verification test** |

## Key files

| File | Role |
|---|---|
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine.sv` | The v2 engine (Stage A/B/C/D pipeline, HF FSM, register decoder) |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_alu.sv` | Package of pure-combinational helpers (`calc_step`, `calc_vol`, `calc_interp`, `byte_addr`, `decode_sample`, `pan_att_*`) |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_eg_step.sv` | Package: EG ROM tables (as functions) + `process_eg` task |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv` | OPL3 + PCM combo top — mixer is here |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_regs.sv` | I/O port 0x7E/0x7F/0xC4..0xC7 decoder, NEW2 gating |
| `rtl/peripheral/slots/memory_upload.sv` | Where yrw801.rom should be loaded to SDRAM (line ~365 `ROM_MOONSOUND` case) |
| `rtl/msx.sv` | Lines 617-680: pcm_state bridge between engine and sdram ch4. Lines 126-131: PSG + MoonSound audio mix. |
| `MSX1.sv` | OSD options @ line ~289 (MoonSound, PCM Mute, FM Mute on status[45..47]) |
| `rtl/debug_overlay.sv` | The 4-row overlay (ROM base / PCM valid / PCM level / NEW2) |

## Testbench coverage (8 testbenches, 323 PASS)

```
tb_pipeline_scaffold (9)   — slot pipeline propagation + 5-read SDRAM budget
tb_cpu_reg_decode    (17)  — all 240 reg writes per slot
tb_hf_fsm            (6)   — full HF cycle, header populates ram_header
tb_integration       (4)   — CPU→HF→Stage B→C→D→pcm_left ≥ 0x1000
tb_bridge_realism    (4)   — works against msx.sv bridge replica
tb_decode_12bit      (7)   — 12-bit a0/a1/a2 fetched correctly
tb_pan_lr            (12)  — all 16 pan values match openMSX
tb_eg_roms           (264) — every ROM entry matches openMSX
```

Build/run all:
```bash
cd rtl/peripheral/SOUND/ymf278b_fpga
for tb in tb_pipeline_scaffold tb_cpu_reg_decode tb_hf_fsm tb_integration \
          tb_bridge_realism tb_decode_12bit tb_pan_lr tb_eg_roms; do
  rm -f /tmp/$tb.vvp
  iverilog -g2012 -o /tmp/$tb.vvp \
    rtl/pcm/ymf278_pcm_alu.sv rtl/pcm/ymf278_pcm_eg_step.sv \
    rtl/pcm/ymf278_pcm_engine.sv tb/$tb.sv 2>&1 | grep -E error
  vvp /tmp/$tb.vvp | grep "==="
done
```

## Known gaps (not blocking sound, just feature completeness)

- CPU memory read path (reg 0x06): `pcm_reg_dout` stubbed to return `8'h20`
  for reg 0x02 (device ID) and zero elsewhere.  Some software may probe
  PCM RAM via this path.
- LFO / VIB: declared but not wired (LFO active/reset bits ignored in
  reg decoder field 4).
- TL ramp (sr_TLdest in legacy v1 — gradual TL change).  Currently we
  load TL immediately on any write.
- Reg 0x68 KEY_ON_OFF batch field (was used by some software for global
  voice gating).
