# ICS2115 "WaveFront" PCM Engine — Technical Analysis

Analysis of the ICS2115 implementation in `Arcade-IGSPGM_MiSTer`, written as a
reference point for comparison against the Yamaha YMF278B (OPL4) PCM engine.
The emphasis is on **sample-memory access architecture**, since that is the area
most relevant to the OPL4 comparison (sustained bulk sample traffic vs. read
budget / contention).

All file/line references are to the repo at
`/home/muhanpong/Documents/github/Arcade-IGSPGM_MiSTer`.

Source files studied:

| File | Role |
|------|------|
| `rtl/ics2115/ics2115.sv` | Top-level: voice RAM, sample-tick generator, voice sequencer, host bus, IRQ/timers, save-state |
| `rtl/ics2115/ics2115_osc.sv` | Per-voice oscillator FSM: ROM fetch → interpolation → volume/pan → mix; envelope/loop update |
| `rtl/ics2115/ics2115_pkg.sv` | Types, `voice_state_t`, register map, bit-position constants |
| `rtl/ics2115/ics2115_tables.sv` | Volume (4096×16) and pan-law (16-step) LUTs |
| `rtl/PGM.sv` | Core integration: instantiates `ics2115` + `audio_rom_cache`, wires to SDRAM ch2 |
| `rtl/rom_cache.sv` | `audio_rom_cache` (64-slot sample-ROM cache) |
| `rtl/sdram.sv` | 4-channel SDRAM controller; ch2 = audio, 4-word burst |
| `rtl/system_consts.sv` | ROM region base addresses in SDRAM |

---

## 1. Overview

The ICS2115 (ICS WaveFront) is a **32-voice PCM / wavetable synthesizer** used as
the sound chip in the IGS PGM arcade platform. It reads sample data from an
external sample ROM, performs per-voice pitch (phase-accumulation) playback with
linear interpolation, applies a per-voice volume envelope and pan, and sums all
voices into a 16-bit stereo output. It also provides two general-purpose timers
and an IRQ system used by the PGM Z80 sound CPU.

### Key parameters

| Property | Value | Source |
|----------|-------|--------|
| Voices | 32 (`NUM_VOICES`) | `ics2115_pkg.sv:10` |
| Active voices | programmable `active_osc`, default 31 | `ics2115_pkg.sv:11`, `ics2115.sv:957` |
| Sample formats | 16-bit signed, 8-bit signed linear, 8-bit µ-law (companded) | `ics2115_osc.sv:96-111`, `:189-225` |
| Sample-ROM addressing | 24-bit **byte** address = `{saddr[3:0], addr[19:0]}` | `ics2115_osc.sv:182-187` |
| Phase accumulator | 29-bit, 20.9 fixed-point | `ics2115_pkg.sv:52,72` |
| Interpolation | linear, 9-bit fraction | `ics2115_osc.sv:155-164` |
| Volume table | 4096×16-bit, registered (1-cycle) | `ics2115_tables.sv:31-45` |
| Pan law | 16-step attenuation table | `ics2115_tables.sv:53-72` |
| Output | 16-bit signed stereo, clamped | `ics2115.sv:495-512` |
| Engine clock enable | `ce_50m` (= full 50 MHz rate here) | `PGM.sv:842`, `system_consts`/`PGM.sv:93` |
| Sample-rate tick | `ce_33m` ≈ 33.8688 MHz, ÷((active_osc+1)·32) | `ics2115.sv:264-288`, `PGM.sv:399-407` |

### Clocking

The core's master clock is **50 MHz** (`clk = clk_50m`, `PGM.sv:76`). Two clock
enables matter for the ICS2115:

- `ce_50m` — held at `1` in this core (`PGM.sv:93`), so the oscillator FSM
  (`u_osc`, clocked by `ce_50m`) advances **every** clock at 50 MHz.
- `ce_33m` — a fractional clock enable produced by `jtframe_frac_cen` with
  ratio 464/685 of 50 MHz ≈ **33.8688 MHz** (`PGM.sv:399-407`). This is the
  authentic ICS2115 clock and drives the sample-tick divider.

The **per-sample period** is `(active_osc + 1) × 32` cycles of `ce_33m`
(`ics2115.sv:264,269`). With the default `active_osc = 31`, that is
`32 × 32 = 1024` clocks, giving an output sample rate of
33.8688 MHz / 1024 ≈ **33.1 kHz**. The chip trades sample rate against active
voice count exactly like the real part: fewer active voices → higher sample
rate.

### Register / host interface

The host bus is a 4-port, 8-bit interface (`host_addr[1:0]`, `host_din/dout`,
`host_cs_n/rd_n/wr_n`, `host_irq`, `host_ready`) modeled on the real chip and
the MAME driver (`ics2115.sv:16-24`). Indirect register access:

- Port 1 latches the register selector `reg_select` (`ics2115.sv:1096`).
- Ports 2/3 read/write the low/high byte of the selected register
  (`ics2115.sv:746-748`, `:1122-1169`).
- Port 0 is the IRQ/status register (`ics2115.sv:734-745`).

Registers 0x00–0x1F are **per-voice** (oscillator + volume-envelope fields);
0x40–0x7F are **global** (timers, IRQ enable, chip revision, oscillator-select,
active-osc count). The full map is in `ics2115_pkg.sv:96-124`.

A notable integration detail: per-voice register **writes are buffered through a
16-entry FIFO** (`HOST_FIFO_*`, `ics2115.sv:822-839`) and only committed to voice
RAM when the target voice is **not** currently in the sample sequencer pipeline
(`host_voice_wr_busy`, `ics2115.sv:837-838`). This decouples the asynchronous Z80
write stream from the synchronous voice processing loop without a true CDC
(both run on the same 50 MHz `clk`).

---

## 2. Voice / oscillator architecture

### Time-multiplexed single oscillator

There is exactly **one** physical oscillator datapath (`ics2115_osc` instance
`u_osc`, `ics2115.sv:367-389`). All 32 voices are processed **sequentially**, one
per "sample tick," by a top-level sequencer FSM (`SEQ_*`, `ics2115.sv:311-519`):

```
SEQ_IDLE → (on sample_tick) for voice 0..active_osc:
  LOAD_ADDR → LOAD_WAIT → LOAD_CAPTURE   (read voice state from dual-port RAM)
  → START → WAIT (osc_done)              (run the per-voice oscillator FSM)
  → STORE                                (write voice state back, accumulate audio)
→ SEQ_OUTPUT (clamp + emit stereo sample)
```

Voice state lives in a **dual-port BRAM** `voice_ram` (`ics2115.sv:57-68`),
`$bits(voice_state_t)` wide × 32 deep. Port A is owned by the sequencer
(read current voice / write back result); port B is shared by the host-write
FSM, IRQV auto-clear, and save-state bus. The per-voice state struct
(`voice_state_t`, `ics2115_pkg.sv:70-91`) holds the oscillator accumulator,
frequency counter, loop start/end, sample-bank `saddr`, config/control flags,
and the volume-envelope accumulator/start/end/incr/pan/ctrl/mode.

This is the **opposite** of a fully-pipelined design: the 32 voices share one
datapath and one ROM port, serialized by the sequencer. The budget is generous
because at 50 MHz there are ~1024 × (33.87/50) ≈ many `clk` cycles per sample
tick, far more than the ~14-state oscillator FSM needs per voice.

### Per-voice oscillator FSM

`ics2115_osc` (`ics2115_osc.sv:50-65`) runs a ~14-state FSM per voice:

```
IDLE → VOL_LOOKUP → PAN_LOOKUP_L → PAN_LOOKUP_R → VOL_WAIT_L
→ SAMPLE_FETCH_1 → VOL_WAIT_R(*) → SAMPLE_FETCH_2 → SAMPLE_WAIT(*)
→ INTERPOLATE → MIX → OSC_UPDATE → VOL_ENV_UPDATE → DONE
```

States marked `(*)` stall until `rom_data_valid` (`ics2115_osc.sv:239,241`).
This is the handshake that lets the oscillator wait for the variable-latency
sample-memory read (see §3).

### Pitch / phase accumulation

- The phase accumulator `osc_acc` is **29-bit, 20.9 fixed-point**: bits
  `[28:9]` are the 20-bit integer sample index within the bank, bits `[8:0]`
  are the interpolation fraction (`ics2115_osc.sv:155-157,334-337`).
- The frequency counter `osc_fc` is 16-bit; **bit 0 is unused**, so the step is
  `osc_fc[15:1]` (`ics2115_pkg.sv:73`, `ics2115_osc.sv:462-473`). The update is
  `osc_acc ± osc_fc[15:1]`, with sign chosen by `OSC_INVERT` for reverse
  playback (`ics2115_osc.sv:467-473`).
- Boundary handling (`ST_OSC_UPDATE`, `ics2115_osc.sv:462-505`): compute signed
  distance to `osc_end` (forward) or `osc_start` (reverse); if crossed, optionally
  fire the oscillator IRQ, then either loop-wrap or one-shot stop.

### Interpolation

Linear, combinational (`ics2115_osc.sv:159-164`):

```
interp_diff = sample2 - sample1;
interp_raw  = (sample1 <<< 9) + interp_diff * interp_fract;   // 9-bit fract
interp_sample = interp_raw[24:9];                              // ST_INTERPOLATE
```

Two adjacent samples (`cur_addr`, `cur_addr+1`) are fetched and blended by the
9-bit fraction. **This is the key driver of the memory access pattern: two ROM
reads per voice per sample.**

---

## 3. ★ Sample-memory access architecture (primary focus)

This is the most important section for an OPL4 comparison. The ICS2115 design
demonstrates a clean separation: the **engine** issues simple word reads with a
valid-handshake, and a **dedicated cache** absorbs all the SDRAM traffic and
contention.

### 3.1 Engine-side ROM interface (inside the chip)

The oscillator presents a minimal, latency-tolerant interface
(`ics2115.sv:26-31`, `ics2115_osc.sv:29-33`):

| Signal | Width | Meaning |
|--------|-------|---------|
| `rom_byte_addr` | 24-bit | byte address `{saddr[3:0], addr[19:0]}` |
| `rom_addr` | 23-bit | word address = `rom_byte_addr[23:1]` (`ics2115.sv:396`) |
| `rom_rd` | 1 | single-cycle read strobe |
| `rom_data` | 16-bit | sample word in |
| `rom_data_valid` | 1 | handshake: data valid this cycle |
| `rom_voice_id` | 5-bit | which voice is currently reading (`= seq_voice_idx`) |

The address is built from the per-voice 8-bit `saddr` (only low 4 bits used,
selecting a 1 MB bank) concatenated with the 20-bit integer part of the phase
accumulator (`ics2115_osc.sv:182-187,335`). So the addressable sample space is
**16 banks × 1 MB = 16 MB** of byte-addressed sample data, accessed as 16-bit
words.

**Reads per voice per sample = 2** (sample1 at `cur_addr`, sample2 at
`next_addr = cur_addr+1`), issued in `ST_SAMPLE_FETCH_1` and `ST_SAMPLE_FETCH_2`
(`ics2115_osc.sv:366-368,411-413`). Each read **stalls** the FSM in
`ST_VOL_WAIT_R` / `ST_SAMPLE_WAIT` until `rom_data_valid` arrives
(`ics2115_osc.sv:239,241`). There is **no DMA and no engine-side burst** — the
engine treats memory as a single-word, variable-latency synchronous ROM.

8-bit / µ-law formats pack two samples per 16-bit word; the low address bit
(`cur_addr[0]` / `next_addr[0]`) selects high vs. low byte
(`ics2115_osc.sv:393-409,419-434`). 16-bit format uses the whole word.

### 3.2 The FPGA sample memory: SDRAM + 64-slot cache

Sample ROM lives in **SDRAM** (not DDR3, not BRAM). The region bases are in
`system_consts.sv` (`BIOS_MUSIC_ROM_SDR_BASE = 0x0030_0000`,
`CART_MUSIC_ROM_SDR_BASE = 0x0400_0000`, `system_consts.sv:34,38`). The chip's
23-bit word address is translated to a 27-bit SDRAM byte address in `PGM.sv`
(`PGM.sv:738-740`), selecting BIOS or cart music ROM.

Crucially, the engine does **not** talk to SDRAM directly. It talks to a
**dedicated `audio_rom_cache`** module (`PGM.sv:742-755`, `rom_cache.sv:159-232`):

```
ics2115  ──rom_addr/rom_rd/rom_data/rom_data_valid──►  audio_rom_cache
   ▲                                                          │
   └── rom_voice_id (channel) ───────────────────────────────┘ (cache index)
                                                              │
                            sdr_audio_addr/req/ack/data (64b)  ▼
                                                          SDRAM ch2
```

### 3.3 The cache (the heart of the contention story)

`audio_rom_cache` (`rom_cache.sv:159-232`) is a **direct-mapped, 64-slot cache
of 64-bit (4-word) SDRAM lines**:

- `N_SLOTS = 64` (`rom_cache.sv:175`). The slot index is
  `{channel, addr[3]}` (`rom_cache.sv:184`) — i.e. **2 slots per voice**
  (32 voices × 2). Each 64-bit line holds 4 consecutive 16-bit samples
  (`addr[2:1]` selects the word, `rom_cache.sv:186-193`).
- A read is a **hit** when the stored tag (`addr[26:3]`) and slot match
  (`data_valid`, `rom_cache.sv:198`). On a hit, the data is available
  **combinationally the same cycle** — `rom_data_valid` goes straight back to the
  oscillator and the FSM does not stall.
- On a **miss**, the cache issues **one SDRAM request** for the aligned 64-bit
  line (`rom_cache.sv:215-218`), waits on `sdr_req == sdr_ack`
  (`rom_cache.sv:222`), fills the slot, and asserts valid.

Why 2 slots per voice and 4 samples per line matters:

- Linear interpolation needs `cur_addr` and `cur_addr+1`. These are almost always
  in the **same 4-sample line**, so the second read is a guaranteed hit.
- As a voice plays forward through memory, it consumes 4 samples per cache line,
  so it triggers **one SDRAM line fetch roughly every 4 output samples** (in the
  worst, undecimated case). The 2 slots per voice cover the line-crossing case so
  forward playback never thrashes its own slot.
- Because slots are keyed by `channel`, voices **cannot evict each other** — each
  voice has its own private cache real estate. This is the single most important
  property for avoiding sustained-traffic contention.

### 3.4 SDRAM controller: ch2 = audio, burst, high priority

The SDRAM controller (`sdram.sv`) is 4-channel with a fixed priority arbiter.
After an emergency refresh, **ch2 (audio) is checked first**
(`sdram.sv:239-246`), ahead of ch1 (tiles), ch4 (sprites), ch3 (CPU). So sample
fetches win arbitration over almost everything.

Each access is a **4-word burst** (`BURST_LENGTH = 4`, `sdram.sv:73`), returning
a full 64-bit line into `ch2_dout[63:0]` over four CAS beats
(`sdram.sv:165-169`) with `CAS_LATENCY = 3`. So one cache miss = one burst =
4 samples fetched. The amortized SDRAM bandwidth per voice is therefore very
low: ~1 burst per voice per ~4 samples.

### 3.5 Read latency / budget per voice per sample

- **Hit:** 0 stall cycles — `data_valid` is combinational, the oscillator FSM
  flows straight through `ST_SAMPLE_FETCH → ST_INTERPOLATE`.
- **Miss:** `CACHE_CHECK → SDR_WAIT` until the burst completes
  (CAS 3 + burst 4 + request handshake ≈ ~10–15 `clk` cycles), absorbed by the
  oscillator's `rom_data_valid` stall states.
- Per voice per sample the engine issues **2 reads**; with 32 voices that is 64
  read requests per output sample, but thanks to the per-voice cache the vast
  majority are hits and only ~1 SDRAM burst per voice per ~4 samples actually
  reaches SDRAM.

There is no prefetch beyond the implicit 4-sample line; the "prefetch" is simply
that a 64-bit burst pulls the next 3 samples along with the requested one.

### 3.6 Read vs. write paths

The audio path is **read-only** from the chip's perspective — the ICS2115 never
writes sample memory. Sample ROM is uploaded once at load time over the
MiSTer `ioctl` ROM-load path into SDRAM (the music-ROM regions in
`system_consts.sv`, loaded via the `rom_loader`/`memory_stream`/SDRAM ch3 write
path in `Arcade-IGSPGM.sv`). The only writes the chip handles are **register**
writes from the Z80 host (§1), which go to voice BRAM, not to sample memory.
(Save-state save/restore uses the separate DDR `memory_stream` path and the
`ssbus`, `ics2115.sv:88-211,876-949` — unrelated to sample playback.)

---

## 4. Envelope / volume / pan

### Volume envelope (EG)

The EG is a **linear ramp accumulator**, not a multi-stage ADSR. State:
`vol_acc` (26-bit), `vol_start`, `vol_end`, `vol_incr`, `vol_mode`, `vol_ctrl`
(`ics2115_pkg.sv:80-87`). Each sample, the envelope steps by `vol_step` derived
from `vol_mode[1:0]` and `vol_incr` (`calc_vol_step`, `ics2115_osc.sv:113-149`),
which encodes several measured "rate families" (very-slow / compact-floating /
linear). On crossing `vol_start`/`vol_end` it loops, ping-pongs (bidir), or marks
done — mirroring the oscillator boundary logic (`ST_VOL_ENV_UPDATE`,
`ics2115_osc.sv:510-558`). These step shapes are explicitly noted as
hardware-measured, not datasheet-derived.

### Volume + pan application

1. `volacc = vol_acc[25:14]` — 12-bit log-domain volume index
   (`ics2115_osc.sv:305`).
2. Pan law: `pan_tbl[255 - pan]` (left) and `pan_tbl[pan]` (right) are
   subtracted from `volacc` to form per-side indices `vlefti_s/vrighti_s`
   (`ics2115_osc.sv:306,313-326`). Pan is a 16-step attenuation table
   (`ics2115_tables.sv:53-72`).
3. The per-side index drives the 4096×16 volume LUT (registered, 1-cycle,
   `ics2115_tables.sv:43-45`) to produce linear `vleft`/`vright`
   (`ics2115_osc.sv:353-390`).
4. Mix: `interp_sample × vleft/vright`, then `>>> 15`
   (`ics2115_osc.sv:166-169,446-454`).

### 32-voice accumulation / mixing

The per-voice stereo result is **summed in the top-level sequencer** into 24-bit
signed accumulators `acc_left`/`acc_right` during `SEQ_STORE`
(`ics2115.sv:481-484`). After the last active voice, `SEQ_OUTPUT` **clamps** the
24-bit sums to 16-bit signed and emits them with `audio_valid`
(`ics2115.sv:495-512`). Per-voice contributions are also exported for the
simulator debug UI (`debug_voice_sample_*`, `ics2115.sv:331-332,483-484`).

---

## 5. FPGA implementation notes

- **Clock domains:** effectively single-domain. Everything (host bus, sequencer,
  oscillator, cache, SDRAM controller) runs on the 50 MHz `clk`; pacing is by
  clock-enables (`ce_33m`, `ce_50m`). The oscillator is instantiated on `ce_50m`
  (held high → full 50 MHz) while the sample tick is paced by `ce_33m`
  (`PGM.sv:841-842`, `ics2115.sv:279`).
- **Host writes crossing into audio processing:** handled not by a CDC FIFO but
  by the 16-entry register-write FIFO plus a "don't commit while the target
  voice is in the pipeline" guard (`host_voice_wr_busy`, `ics2115.sv:837-839`,
  `:1044-1062`). IRQV auto-clear and timer-IRQ auto-clear are similarly
  registered side-effects applied a cycle after the host read
  (`ics2115.sv:1174-1202`).
- **Timing-critical paths:** the 4096-entry volume table is **registered**
  specifically for timing closure (`ics2115_tables.sv:4,42-45`), which is why the
  oscillator FSM has explicit `VOL_WAIT_L`/`VOL_WAIT_R` wait states. The pan law
  is small enough to stay combinational. The interpolation multiply
  (`interp_diff * interp_fract`) and the mix multiplies are combinational but
  narrow.
- **Resource usage (inferred, not from a fit report):** 1 voice-state BRAM
  (32 entries × ~`voice_state_t` bits), 1 volume LUT BRAM (4096×16), the 64-slot
  audio cache (64×64-bit data + 64×24-bit tags ≈ a few BRAMs), plus the
  single shared oscillator datapath (a handful of small multipliers/adders). The
  single-oscillator, time-multiplexed approach keeps logic/DSP usage low at the
  cost of needing many clocks per sample (which it has).
- **Save state:** full save/restore via `ssbus` with a legacy 8-words-per-voice
  packing for backward compatibility (`ics2115.sv:133-211`).

---

## 6. Notable design choices, strengths, and quirks (for PCM-engine comparison)

**Strengths / smart choices**

- **Per-voice private cache slots** (`{channel, addr[3]}` keying,
  `rom_cache.sv:184`): voices cannot evict each other, so 32 simultaneous
  streaming voices generate a *bounded, well-behaved* SDRAM load with no
  thrashing. This is the cleanest possible answer to "sustained bulk sample
  traffic without contention."
- **Burst-fill cache lines** (4 samples/line, `BURST_LENGTH=4`): amortizes SDRAM
  latency across 4 output samples per voice, turning a latency-bound problem into
  a bandwidth-light one (~1 burst/voice/4-samples).
- **Audio is the highest-priority SDRAM channel** (`sdram.sv:239`): sample fetches
  are never starved by video/CPU traffic.
- **Latency-tolerant engine interface** (`rom_rd` + `rom_data_valid` handshake,
  oscillator stall states): the engine doesn't care how long memory takes, so the
  cache/SDRAM backend can be swapped or retimed freely.
- **Time-multiplexed single datapath**: small footprint; the generous
  clocks-per-sample budget (50 MHz vs. ~33 kHz × ~14 states × 32 voices) makes
  serialization free.

**Quirks**

- `osc_fc[0]` and `vol_acc[9:0]` low bits are deliberately unused/zeroed to match
  measured hardware register granularity (`ics2115.sv:788,793`).
- Volume/envelope step tables are **hardware-measured**, with explicit comments
  that several `VMode` codes collapse to the same rate
  (`ics2115_osc.sv:122-147`).
- The IRQV register read has a destructive auto-clear side effect deferred to
  after the read completes, to match Z80 sampling behavior
  (`ics2115.sv:532-535,704-716`).

### Comparison hooks vs. YMF278B (OPL4) PCM

| Aspect | ICS2115 (this core) | What to compare on OPL4 |
|--------|---------------------|--------------------------|
| Sample memory | SDRAM ch2, highest priority | OPL4 uses SDRAM read budget → burst (per MEMORY notes) |
| Cache | **64-slot, per-voice (2/voice), 4-sample burst lines** | OPL4 has no per-voice cache; relies on read budget/burst window |
| Reads/voice/sample | 2 (linear interp), almost always cache hits | OPL4 interpolation + envelope reads vs. its budget |
| Contention strategy | private per-voice slots → no eviction | OPL4 must schedule all voices within a fixed read budget |
| Voice processing | 1 shared datapath, time-multiplexed, latency-tolerant | OPL4 engine pipelining and stall behavior |
| Companding | 8-bit linear, 8-bit µ-law, 16-bit | OPL4: 8/12/16-bit |

The headline architectural difference: **ICS2115 front-loads a generous,
per-voice cache between the engine and SDRAM**, so the engine can be naive
(2 single-word reads/voice with a valid handshake) and never worry about budget.
The OPL4 engine, by contrast, has to live within a fixed per-sample SDRAM read
budget (the noise→burst issue in the MSX core), so it is far more sensitive to
read scheduling and bulk-traffic contention. If the OPL4 PCM path ever needs to
scale up sustained sample bandwidth without glitching, the ICS2115's
**per-voice private cache + burst-line fill + highest-priority audio channel** is
the model to copy.

---

## Key takeaways

1. **Sample memory = SDRAM, fronted by a dedicated 64-slot `audio_rom_cache`
   (2 slots per voice, 64-bit / 4-sample burst lines).** The engine itself never
   touches SDRAM; it issues 2 single-word reads per voice per sample with a
   `rom_rd`/`rom_data_valid` handshake (`ics2115_osc.sv:366-413`,
   `rom_cache.sv:159-232`).
2. **Per-voice cache keying (`{channel, addr[3]}`) means voices cannot evict each
   other**, so 32 streaming voices produce bounded, contention-free SDRAM load —
   the cleanest available solution to sustained bulk sample traffic.
3. **Audio is the top-priority SDRAM channel and each miss is a 4-word burst**
   (`sdram.sv:239,73`), amortizing latency to ~1 burst per voice per ~4 samples.
4. **32 voices share one time-multiplexed oscillator datapath**, paced by a
   sample tick of `(active_osc+1)×32` cycles of ~33.87 MHz `ce_33m`
   (`ics2115.sv:264-288`); the engine is latency-tolerant, so the memory backend
   is fully decoupled.
5. **Formats: 16-bit, 8-bit linear, 8-bit µ-law**, 29-bit 20.9 phase accumulator,
   9-bit linear interpolation, registered 4096-entry volume LUT + 16-step pan law.
6. **For the OPL4 comparison:** the decisive contrast is that the ICS2115 invests
   in a per-voice cache so its engine is read-budget-agnostic, whereas the OPL4
   PCM engine must schedule all voice reads inside a fixed budget — exactly the
   axis where contention/noise problems show up.
