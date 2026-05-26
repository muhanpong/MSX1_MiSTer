# YMF278B PCM v2 — Session handoff

Companion to `pcm_v2_task_list_post_8agents.md`.  Captures everything a
future session needs to pick up from `669bfb8`.

## Where things stand (commit `669bfb8`)

PCM playback on real hardware: **silent**.  Last known "noisy but audible"
state: commit `12a12ac` (HF backfill of slot regs).  Commit `d5c40c5` added
the Stage B `drop_next_valid` race fix, which caused the silence regression.
**Start of next session: revert `d5c40c5`'s drop_next_valid change**.

## Architecture map

### Clock domains

```
clk21m  (~21.477 MHz)          clk_sdram  (~85.909 MHz)
─────────────────────         ─────────────────────────
T80 CPU                       ymf278b_top
V9938 VDP                       └─ ymf278b_regs (I/O port decode)
PSG                             └─ ymf278_pcm_engine
PPI                                 └─ Stage A/B/C/D pipeline
                                    └─ HF FSM
                                    └─ CPU mem access (reg 0x02-0x06)
                              SDRAM controller (4-channel)
                                ch1: memory_upload writes yrw801
                                ch2: main RAM
                                ch3: flash
                                ch4: PCM (engine read + CPU read/write)

Bridge (in msx.sv): clk21m → clk_sdram CDC
  - toggle-synchronizer for CPU I/O writes/reads to ymf278b
  - 4-state bridge for engine mem_addr/mem_rd_en ↔ ch4
```

### Pipeline stages (engine, `ymf278_pcm_engine.sv`)

```
Stage A (dispatch_now, slot_phase=0):
  - latch ram_regs[cur_slot], ram_header[cur_slot], ram_dyn[cur_slot]
  - 1 cycle

Stage B (stage_advance):
  - compute next_pos/next_stepPtr via calc_step
  - compute byte addresses (a0/a1/a2/b0/b1)
  - sequencer fetches 5 bytes via mem_addr/mem_rd_en
  - ~40-60 cycles per slot (varies with SDRAM latency)

Stage C (stage_advance):
  - decode_sample on bytes[]
  - linear interpolation between samp_a, samp_b
  - 1 cycle

Stage D (3-cycle: D1→D2→D3):
  - D1: process_eg (envelope update), key_on_edge detect
  - D2a/D2b: calc_vol multiplied with interp
  - D3: pan, master_accum, writeback ram_dyn
  - master_accum saturated to pcm_left/right at sample_start

Frame: CYCLES_PER_FRAME = 1948 cycles ≈ 44102 Hz sample rate
  - Dispatch window: cycles 0..1535 (24 slots × 64 cyc)
  - Pipeline drain: 1536..1727
  - Idle window: 1728..1947 (HF FSM + CPU mem access run here)
```

### Key files (recent edits)

| File | Recent role |
|---|---|
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine.sv` | Engine FSM, pipeline stages, HF, CPU mem |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_alu.sv` | `calc_step`, `byte_addr`, `decode_sample`, `calc_vol`, `pan_att_*` (all audit-clean) |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_eg_step.sv` | `process_eg`, EG rate tables |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_regs.sv` | I/O port decode, NEW2, status sig 0x02, reg 0x02 fall-through |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv` | Engine instantiation, pcm_reg_dout mux |
| `rtl/peripheral/slots/memory_upload.sv` | FW pack search → SDRAM upload, pcm_rom_base capture |
| `rtl/msx.sv` | OPL3+PCM mix, ch4 bridge, I/O port CDC |
| `MSX1.sv` | Top-level SDRAM ch4 wiring |

### Reference sources

| File | Purpose |
|---|---|
| `rtl/peripheral/SOUND/ymf278b_fpga/reference/YMF278.cc` | openMSX implementation (authoritative) |
| `rtl/peripheral/SOUND/ymf278b_fpga/reference/YMF278.hh` | openMSX struct definitions |
| `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/legacy_v1/` | Earlier v1 RTL implementation |
| `/home/muhanpong/Downloads/YMF278B.pdf` | Yamaha YMF278B (OPL4) application manual |
| `/home/muhanpong/Downloads/MB_DEV/` | MoonBlaster source — useful for usage patterns |
| `tools/CreateMSXpack/ROM/extensions/yrw801.rom` | The 2 MB wave ROM itself |

## Commit chain (this session)

```
669bfb8  docs: post-8agent task list                       <- HEAD
d5c40c5  fix HF/CPU same-slot race + Stage B late-valid    <- silence regression
38a64dc  mix scaling /16 + status sig 0x02 one-shot
12a12ac  HF_STORE backfills LFO/AR/D1R/DL/D2R/RC/RR/AM     <- last "noisy" state
1b066d2  drop pcm_reg_rd guard from reg-read mux
148a02e  stop overriding reg 0x02 read with 0x20
d81b6b2  reg 0x02 readback reflects latched bits
6628673  write path fix (data hold + adr timing)
32a484c  CPU memory access (reg 0x02-0x06) impl
f1d1fb7  memory_upload: revert FW header skip back to +7
72dc0d0  memory_upload: (wrong) +7 → +8 fix
```

**Tested-good states**:
- `12a12ac`: PCM out, but noise + 0 dBFS saturation. Single slot saturates,
  no recognizable pitch, "지지지극 잡음".
- `38a64dc`: same noise but at −24 dB (volume sane).

**To revert**: `git revert d5c40c5` (or hand-edit to drop `drop_next_valid`)
should restore `38a64dc`-era behavior (noisy but audible).

## Known-good vs known-broken

### Confirmed working
- yrw801.rom loads to SDRAM at `pcm_rom_base`.  BASIC dump shows
  `40 18 00 00 00 FF D6 00 F0 00 0F 00` at SDRAM offset 0.
- yrw801 wave 0 sample data at SDRAM offset 0x1800 reads back correctly
  via BASIC (CPU reg 0x06 read path).
- CPU memory **write+readback**: 0xAB → 0xAB at any address.
- HF FSM populates ram_header per yrw801 wave headers.
- HF backfill of slot's envelope params (LFO/AR/D1R/DL/D2R/RC/RR/AM) from
  header bytes 7..11 — verified by tb_integration & tb_bridge_realism.
- Reg 0x02 readback: 0x20 after reset, 0x21 with mem_access_mode=1, etc.
- 352 testbench tests pass in iverilog (9 testbench files).
- OPL3 FM still works fine (NeonHorizon's FM tracks audible).

### Confirmed broken
- **Wave playback sounds like meaningless noise**, not the intended
  instruments.  "음정 무시" (pitch ignored) — different notes don't appear
  to play at different pitches.
- After commit `d5c40c5`: completely silent (drop_next_valid regression).

### Not yet tested
- MoonBlaster Wave player detection: status sig 0x02 was implemented in
  `38a64dc` but never re-verified on hardware (silence intervened).
- BUSY status bit polling: not implemented; software at machine-speed could
  lose writes to PCM RAM.
- Sound-gen halt when reg 0x02 bit 0 (mem_access_mode) = 1: not implemented.

## Diagnostic BASIC snippets

### Read 32 bytes from SDRAM at address 0x1800 (= yrw801 wave 0 sample data)
```basic
10 OUT &H7E,&H02 : OUT &H7F,&H01  ' mem_access_mode = 1
20 OUT &H7E,&H03 : OUT &H7F,&H00  ' adr[23:16] = 0
30 OUT &H7E,&H04 : OUT &H7F,&H18  ' adr[15:8]  = 0x18
40 OUT &H7E,&H05 : OUT &H7F,&H00  ' adr[7:0]   = 0
50 OUT &H7E,&H06
60 FOR I=0 TO 31 : PRINT HEX$(INP(&H7F));" "; : NEXT
```
Expected: `00 56 ED DA EB C8 B8 55 A9 9C 74 91 89 51 83 80 ...`

### Read reg 0x02 (Device ID + latched mode bits)
```basic
10 OUT &H7E,&H02
20 PRINT HEX$(INP(&H7F))
```
Expected: `20` after reset, `21` if mem_access_mode=1 was written, etc.

### Write+readback test
```basic
10 OUT &H7E,&H02 : OUT &H7F,&H01     ' enable mem access
20 OUT &H7E,&H03 : OUT &H7F,&H02     ' addr = 0x20_0000 (well past yrw801)
30 OUT &H7E,&H04 : OUT &H7F,&H00
40 OUT &H7E,&H05 : OUT &H7F,&H00
50 OUT &H7E,&H06 : OUT &H7F,&HAB     ' write 0xAB, auto-increment
60 OUT &H7E,&H03 : OUT &H7F,&H02     ' reset to same addr
70 OUT &H7E,&H04 : OUT &H7F,&H00
80 OUT &H7E,&H05 : OUT &H7F,&H00
90 OUT &H7E,&H06 : PRINT HEX$(INP(&H7F))  ' should print AB
```

## Debug overlay rows

Currently `rtl/debug_overlay.sv` shows 4 rows at top-left:

1. **ROM Base Set** (green=set, red=missing): `pcm_rom_base != 0x1800000`
2. **PCM Valid** (bright green=pulsing, dark green=quiet): `dbg_pcm_valid`
3. **PCM Level** (yellow bar): `|pcm_left|` peak
4. **NEW2** (bright cyan=on, dark=off): OPL3 NEW2 bit

To add new rows: extend the if/else chain in `always_comb` block, increase
`PH` localparam.  Adding slot 0 fn/oct/keyon overlay was discussed but
deferred.

## Build / deploy workflow

```bash
# Full build + deploy to MiSTer
cd /home/muhanpong/Documents/github/MSX1_MiSTer
make build deploy
# (~5-10 min Quartus compile, then scp .rbf to MiSTer at 192.168.1.86)

# Iverilog testbench regression (all 9 tb files)
cd rtl/peripheral/SOUND/ymf278b_fpga
for tb in tb_pipeline_scaffold tb_cpu_reg_decode tb_hf_fsm tb_integration \
          tb_bridge_realism tb_decode_12bit tb_pan_lr tb_eg_roms tb_cpu_mem; do
  iverilog -g2012 -o /tmp/$tb.vvp \
    rtl/pcm/ymf278_pcm_alu.sv rtl/pcm/ymf278_pcm_eg_step.sv \
    rtl/pcm/ymf278_pcm_engine.sv tb/$tb.sv 2>&1 | grep error
  vvp /tmp/$tb.vvp | grep "==="
done
```

## 8-agent reports

Each agent's full report is in commit `669bfb8`'s message history; agents
reviewed 8 disjoint areas of the engine and identified bugs in only 3:
Stage B (Agent 6), HF/CPU race (Agent 8), pos shift (Agent 4).  Agents 1,
2, 3, 5, 7 found no bug in their areas (byte_addr / decode_sample /
calc_step / next_pos_calc / pipeline propagation).

Critical takeaway: the wave-rendering math is correct.  The bugs are in
**inter-stage / inter-FSM hand-off** — Stage B fetch race, HF/CPU register
race.  Future sessions should focus there.

## Open hypotheses to test (priority order)

1. **Sample data IS being fetched correctly but interpreted/decoded wrong
   per slot due to ram_regs corruption.**  Could be confirmed by adding an
   overlay row showing slot 0's fn (= CPU-written F-number) — if it stays
   constant across software's note changes, CPU writes are being lost.
2. **bits / format field is wrong**, causing 12-bit decoding of 8-bit data
   or vice versa.  Could be confirmed via overlay of ram_header[0].bits.
3. **stepPtr is not accumulating properly** across frames — could be the
   ram_dyn writeback dropping writes.  Check `ram_dyn[d2_pkt.slot]` write.
4. **Header values for non-zero waves are wrong** (HF fetched wrong bytes).
   Could verify by BASIC dump at `wave * 12` for several wave numbers.

## What NOT to do next session

- Don't re-verify ROM loading; confirmed solid.
- Don't change `memory_upload.sv` `+7` (verified correct via BASIC dump).
- Don't add more "improvements" before reverting `drop_next_valid` and
  re-establishing the noisy-but-audible baseline.
