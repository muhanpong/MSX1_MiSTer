# FPGA YMF278B (OPL4 / MoonSound) PCM — Functional-Unit Match Analysis

Verification target: the SystemVerilog reimplementation under
`rtl/peripheral/SOUND/ymf278b_fpga/`.
Ground truth: `docs/moonsound_mechanism/01_openmsx_mechanism.md` (Units 1..13),
cross-checked against `openMSX/src/sound/YMF278.cc`.

The FPGA is a 24-slot time-sliced pipeline (CYCLES_PER_SLOT=64, 1948-cycle
frame). openMSX is a per-sample scalar loop. "MATCH/EQUIVALENT" therefore means
*functional* equivalence after accounting for pipelining.

Files:
- `engine` = `rtl/pcm/ymf278_pcm_engine.sv`
- `alu`    = `rtl/pcm/ymf278_pcm_alu.sv`
- `eg`     = `rtl/pcm/ymf278_pcm_eg_step.sv`
- `regs`   = `rtl/ymf278b_regs.sv`
- `top`    = `rtl/ymf278b_top.sv`

---

## Summary verdict table

| Unit | Topic | Verdict | Severity |
|------|-------|---------|----------|
| 1  | Architecture / dataflow / 44.1 kHz tick | EQUIVALENT | — |
| 2  | I/O port decode, NEW2 gating | MATCH (mostly) ; 1 LOW gap | low |
| 3.1 | Slot register fan-out (fields 0..9) | MATCH | — |
| 3.1-hdr | Field-0 header auto-backfill (bytes 7..11) | EQUIVALENT | — |
| 3.2 | Non-slot regs 0x00..0x06 | MATCH | — |
| 3.3 | Register read (reg 2 / reg 6) | MATCH | — |
| 4  | Wave memory map & 12-byte header | EQUIVALENT | — |
| 5.1 | getSample 8/12/16-bit decode | MATCH | — |
| 5.2 | calcStep (oct/fn/vib) | MATCH | — |
| 5.3 | nextPos loop-wrap | MATCH | — |
| 5.4 | interp + step accumulate | EQUIVALENT | — |
| 6  | EG state machine (ATT/DEC/SUS/REL/OFF) | MATCH | — |
| 6.2 | keyOnHelper / key-on edge | EQUIVALENT (intended [07]) | — |
| 6.3 | eg_cnt | MATCH | — |
| 7.1 | compute_rate (RC / OCT / FN9) | MATCH | — |
| 7.2 | compute_decay_rate (DAMP / PRVB) | MATCH | — |
| 8.1 | env+AM combine + 0x280 clip | MATCH | — |
| 8.2/8.3 | vol_factor two-stage env/TL | MATCH (intended [09]) | — |
| 8.4 | TL interpolation/ramp | **MISSING** | med |
| 8.5 | Panning | MATCH | — |
| 8.6 | PCM mix level (reg 0xF9) | **MISSING** | med |
| 8.7 | anyActive / muting | EQUIVALENT | — |
| 9  | CPU wave-memory access | EQUIVALENT ; 1 DISCREPANCY (chan-halt) | low |
| 10.1 | LFO counter | MATCH | — |
| 10.2 | compute_vib (mag/12 reciprocal) | MATCH (verified exact) | — |
| 10.3 | compute_am | MATCH | — |
| 11.1 | dl_tab | MATCH | — |
| 11.2 | eg_inc | MATCH | — |
| 11.3 | **eg_rate_select** | **DISCREPANCY** | med |
| 11.4 | eg_rate_shift | MATCH | — |
| 11.5 | lfo_period/vib_depth/am_depth/pan | MATCH | — |
| 12 | Status / IRQ / busy / load | EQUIVALENT | — |
| 13 | FM core (structural) | OUT OF SCOPE | — |

Counts: **MATCH ≈ 19, EQUIVALENT ≈ 8, DISCREPANCY = 2 (1 table bug + 1 chan-halt),
MISSING = 2.**

Top issues:
1. **Unit 11.3 `eg_rate_select_rom` is row-shifted for internal rates 48..55**
   (med) — fast decay/release run too slow.
2. **Unit 8.4 TL interpolation/ramp not implemented** (med).
3. **Unit 8.6 PCM mix level reg 0xF9 not implemented** (med).

---

## Unit 1 — Architecture & top-level dataflow — EQUIVALENT

Ref §1: OPL3(YMF262) + PCM(YMF278) mixed externally; PCM internal rate 44100 Hz;
`advance()` (EG+LFO+TL) ticks once per output sample.

FPGA: `top` instantiates `opl3 u_opl3` + `ymf278_pcm_engine u_pcm`, summed in the
mix block (`top:317-321`). One 1948-cycle frame = one PCM sample
(`engine:129,172-177`); `eg_cnt` increments once per frame (`engine:177`) — the
exact analogue of openMSX `eg_cnt++` per `advance()`. The per-slot EG/LFO/TL all
advance once per frame.

Divergence (benign): FPGA mixes FM+PCM *inside* the core into one stereo stream
(`top:317`), whereas openMSX registers them as two devices summed by the host
mixer. Same audible result. The 44100 Hz rate is approximated by the
frame=1948-cycle divider off the 85.9 MHz `clk_sdram` rather than a literal
44100 Hz clock; this is the intended FPGA clocking. **EQUIVALENT.**

---

## Unit 2 — I/O port decode + NEW2 gating — MATCH (one LOW gap)

Ref §2: WAVE = ports 0x7E/0x7F; FM = 0xC4..0xC7; discriminator `(port&0xFF)<0xC0`.
NEW2=0 ignores ALL WAVE writes (select + data) but WAVE *reads* still work.

FPGA `regs:134-174`:
- `io_port[7:1]==7'b0111111` → 0x7E/0x7F WAVE. Select on `!io_port[0]`, write on
  `io_port[0]`. **WAVE writes gated by `if (new2)`** (`regs:136`) — matches.
- `io_port[7:2]==6'b110001` → 0xC4..0xC7 FM, bank0/bank1 select + write
  (`regs:154-173`). Matches Ref §2.
- WAVE read path (`regs:176-202`) is NOT gated by new2 — matches "reads happen
  even when NEW2=0".

Discrepancies:
- **Special FM-side 0xF8/0xF9 mix-level writes on the WAVE port** (Ref §2,
  `YMF278B.cc:164-168`) are not specially decoded; reg 0xF9 reaches the engine as
  a normal reg write and is a no-op there (no `setMixLevel`). See Unit 8.6.
  Severity **low** (it is the same omission as 8.6, surfaced here).
- The "read port 0 returns 255" and the WAVE read still advancing memAdr are
  handled (reg 6 path, Unit 9). The device-ID one-shot signature (`regs:114-116,
  210-211`) is an FPGA-added MoonSound chip-detect aid, consistent with the
  datasheet, not contradicting the Ref.

**Verdict: MATCH** for the decode + NEW2 gating; mix-level decode gap rolled into
Unit 8.6.

---

## Unit 3.1 — Slot register block (fields 0..9) — MATCH

Ref §3.1 field map vs FPGA `engine:1336-1385`:

| field | Ref | FPGA (`engine`) | verdict |
|-------|-----|------|---------|
| 0 | wave[7:0] (+ header load) | `wave[7:0]=data` (1340), sets hf_pending | MATCH |
| 1 | wave[8]; FN[6:0]=data>>1 | `wave[8]=data[0]; fn[6:0]=data[7:1]` (1343-1344) | MATCH |
| 2 | FN[9:7]=data[2:0]; PRVB=data[3]; OCT=sext(data[7:4]) | `fn[9:7]; prvb; oct=$signed(data[7:4])` (1347-1349) | MATCH |
| 3 | t=data>>1; TLdest=(t!=0x7f)?t:0xff; bit0 load | `tl=(tl_t!=0x7f)?tl_t:0xff` (1355-1356) | MATCH (ramp not done, see 8.4) |
| 4 | pan/DO1(mute=8)/LFO-reset/DAMP/keyon | `pan=data[4]?8:data[3:0]; damp; keyon; lfo_active=~data[5]` (1359-1364) | MATCH |
| 5 | lfo=(data>>3)&7; vib=data&7 | `lfo_speed=data[5:3]; vib=data[2:0]` (1367-1368) | MATCH |
| 6 | AR=data>>4; D1R=data&0xF | `ar=data[7:4]; d1r=data[3:0]` (1371-1372) | MATCH |
| 7 | DL=dl_tab[data>>4]; D2R=data&0xF | `dl_idx=data[7:4]; d2r=data[3:0]` (1375-1376) | MATCH (FPGA stores INDEX, applies dl_tab_rom at use — EQUIVALENT) |
| 8 | RC=data>>4; RR=data&0xF | `rc=data[7:4]; rr=data[3:0]` (1379-1380) | MATCH |
| 9 | AM=data&7 | `am=data[2:0]` (1382) | MATCH |

Field-3 OCT sign-extend and field-2 OCT both store signed 4-bit; FPGA `slot_regs_t.oct`
is `signed [3:0]` (`engine:216`). MATCH.

`calcStep` is not re-evaluated at field-1/2 write time (Ref recomputes
`slot.step`); instead the FPGA recomputes `calc_step` combinationally every
dispatch from the live `oct/fn` (`engine:408`). Same result — EQUIVALENT (the
cached-step invariant is unnecessary because the FPGA never caches step).

**Verdict: MATCH.**

---

## Unit 3.1 (header auto-backfill) — EQUIVALENT

Ref §3.1: writing field 0 loads 12 header bytes; bytes 7..11 are written back
into the slot's own fields 5..9 via recursive `writeRegDirect`. Does NOT touch
TL/pan/FN/OCT/PRVB.

FPGA: a write to field 0 or 1 sets `hf_pending[slot]` (`engine:1556,1564`). The HF
FSM (`engine:1478-1530`) reads the 12 bytes from SDRAM, builds the header
(`engine:1534-1539`), and at `HF_STORE` writes bytes 7..11 into
`lfo_speed/vib/ar/d1r/dl_idx/d2r/rc/rr/am` (`engine:1411-1419`). This is exactly
fields 5..9, and TL/pan/FN/OCT/PRVB are untouched. MATCH on the *content* of the
backfill.

Divergences (all benign / intended):
- **Latency:** openMSX loads the header *synchronously* at write time; the FPGA
  defers it to an SDRAM-windowed FSM (~1 frame). During that window the slot's
  header (startAddr/loop/end/bits) is stale, so the engine asserts a
  **stale-header output gate**: `vs_gated = hf_pending ? 0 : vol_sample`
  (`engine:1208`). This silences the slot until the header arrives — intended,
  and closer to the chip's LOAD-busy behavior than openMSX's instant load.
- **Note:** the duplicate "TODO also override ram_regs ... Skipped for v2 MVP"
  comment at `engine:1546-1548` is stale — the backfill IS implemented in the CPU
  decoder block (`engine:1400-1421`). Cosmetic only.

**Verdict: EQUIVALENT.**

---

## Unit 3.2 — Non-slot registers — MATCH

Ref §3.2 vs FPGA:
- `0x00/0x01` TEST: ignored. FPGA never decodes them. MATCH.
- `0x02`: header-base selector bits 2..4 → `wavetblhdr<=reg_data[4:2]`
  (`engine:1334`); bit0 mem-access mode, bit1 mem-type → `reg02_mem_access_mode`,
  `reg02_mem_type` (`engine:1629-1631`). MATCH.
- `0x03` masked `&0x3F`, store only, no memAdr update: FPGA stores
  `cpu_mem_adr[23:16]<=reg_data` (`engine:1645`). FPGA does NOT apply the `&0x3F`
  mask on the stored high byte, but the address is later truncated to 22 bits at
  use (`mem_addr<=cpu_mem_adr[21:0]`, `engine:1733/1737`), so bits above 21 are
  dropped anyway. Ref keeps `memAdr` 24-bit and masks reg-3 readback to 6 bits;
  the FPGA does not read reg 3 back. EQUIVALENT.
- `0x04` mid, store only: `cpu_mem_adr[15:8]` (`engine:1646`). Note the FPGA
  commits the high/mid bytes into `cpu_mem_adr` immediately rather than into a
  shadow `regs[]`, but since reg 5 also writes only the low byte
  (`engine:1647`), the *committed* address after a 3/4/5 sequence equals
  `{regs3,regs4,data}` — same as Ref. EQUIVALENT.
- `0x05` commits low byte (`engine:1647`) + arms a read prefetch (`cpu_rd_pend`,
  `engine:1664`). MATCH (commit), EQUIVALENT (prefetch is the FPGA's async
  read model).
- `0x06` data port: write→`writeMem` gated by mode bit; read→`readMem`.
  See Unit 9. MATCH.
- `0xF8/0xF9`: no-op in engine. MATCH to Ref §3.2 ("no-op here"), but the
  *external* setMixLevel is not implemented anywhere — see Unit 8.6.

**Verdict: MATCH.**

---

## Unit 3.3 — Register read — MATCH

Ref §3.3: reg2 returns `(regs[2]&0x1F)|0x20`; reg6 returns readMem(memAdr) when
mode set, else 0xFF; readReg(6) increments memAdr.

FPGA: `reg02_readback = {3'b001, wavetblhdr, reg02_mem_type, reg02_mem_access_mode}`
(`engine:1696`) = device-ID `001b` in the top 3 bits + the live low-5 bits ==
`(regs[2]&0x1F)|0x20`. MATCH.
Reg 6 read returns `cpu_mem_rd_buf` (`engine:1683`) routed via
`pcm_reg_dout` (`top:213-215`); auto-increment at `cpu_rd_06` (`engine:1648`).
MATCH. (The mode-bit gating for the 0xFF-when-disabled case is handled by the
prefetch only issuing in mem-access mode; reg 6 read with mode off returns the
last buffered byte rather than literal 0xFF — minor, see Unit 9.)

**Verdict: MATCH.**

---

## Unit 4 — Wave memory map & 12-byte header — EQUIVALENT

Ref §4: 4 MB space wrapping at 4 MB; 32×128 kB chunks; ROM/RAM mode0/mode1 map;
header base `wave<384||!hdr ? wave*12 : hdr*0x80000+(wave-384)*12`.

FPGA: physical memory is the MiSTer SDRAM ch4 (mapped in `msx.sv`/`sdram.sv`),
not chunk pointers. The 22-bit address bus (`mem_addr`) wraps at 4 MB implicitly
(22 bits). HF address calc (`engine:1451-1455`):
`wave<384 || wavetblhdr==0 ? wave*12+idx : (wavetblhdr<<19)+(wave-384)*12+idx`.
`wavetblhdr<<19` == `*0x80000`. **MATCH** to Ref §4.2 base formula.

Header byte layout (`engine:1534-1539`):
`bits=buf[0][7:6]; startAddr={buf[0][5:0],buf[1],buf[2]} (22-bit);
loopAddr={buf[3],buf[4]}; endAddr={buf[5],buf[6]}`. Big-endian loop/end exactly
as Ref §4.2. MATCH.

Divergences (benign): the ROM-vs-RAM/mode0/mode1 chip-select table and the
ROM-must-be-2MB constraint are openMSX host-memory bookkeeping; on the FPGA the
yrw801 ROM + RAM live in one flat SDRAM region addressed identically, so the
mapping modes collapse to a flat address space. The header *addressing* and
*parsing* — the only parts that affect generated audio — match.

**Verdict: EQUIVALENT.**

---

## Unit 5.1 — Sample decode (getSample) — MATCH

Ref §5.1 vs FPGA `alu:byte_addr` (195-209) + `alu:decode_sample` (215-231):

- **8-bit (fmt 0):** Ref `readMem(start+pos)<<8`. FPGA addr `base+pos`
  (`alu:203`); decode `$signed({b0,8'h00})` (`alu:221`). MATCH.
- **12-bit (fmt 1):** Ref `addr=start+(pos/2)*3`; even = `(b0<<8)|((b1<<4)&0xF0)`,
  odd = `(b2<<8)|(b1&0xF0)`. FPGA addr `base+(p>>1)*3+byte_sel` (`alu:204`);
  decode even = `{b0,(b1<<4)&0xF0}`, odd = `{b2,b1&0xF0}` (`alu:223-226`).
  Bit-exact MATCH including the low-nibble-zero behavior.
- **16-bit (fmt 2):** Ref `(b0<<8)|b1` big-endian, addr `start+pos*2`.
  FPGA addr `base+{pos,1'b0}+byte_sel[0]` (`alu:205`); decode `{b0,b1}`
  (`alu:228`). MATCH.
- **fmt 3:** Ref returns 0; FPGA returns `16'sh0` (`alu:229`). MATCH.

The Stage-B burst sequencer reads 16-bit words and reconstructs the 3-byte
12-bit chunk and the loop-seam B chunk (`engine:668-707`); the
**loop-seam fix [19]** decodes sample B by its OWN `next_pos` parity at a split
(`engine:697-698`), which is exactly what `getSample(sl, nextPos(...))` does in
the Ref (sample B address derived from the wrapped position). This correctly
reproduces the Ref's independent decode of pos and pos+1 even across the loop
wrap. MATCH.

**Verdict: MATCH.**

---

## Unit 5.2 — calcStep — MATCH

Ref §5.2: `oct==-8 → 0`; else `((fn+1024+vib)<<(8+oct))>>3`.

FPGA `alu:calc_step` (12-23): `if (o==-8) return 0; t=(fn+1024+sext(vib))<<(8+o);
return t>>3`. Bit-exact, including signed oct shift distance and the
`<<(8+oct)>>3` precision trick. MATCH. The `vib` argument is sign-extended to
32-bit and added before the shift, matching `(fn+1024+vib)`. MATCH.

**Verdict: MATCH.**

---

## Unit 5.3 — nextPos loop-wrap — MATCH

Ref §5.3: `pos+=inc; if ((uint32)pos+endAddr >= 0x10000) pos += endAddr+loopAddr`.

FPGA `engine:next_pos_calc` (347-358):
`p2 = pos+inc; if ((p2[15:0]+endAddr) >= 0x10000) p2 = p2+endAddr+loopAddr;
return p2[15:0]`. Same 16-bit wrap arithmetic, same "negated end" comparison,
same loop-back. The Lizard-Star overrun (advance > loop length) is reproduced
because there is no clamp — the wrap math is identical. MATCH.

The whole-sample increment is derived from `step[31:16] + (stepPtr carry)`
(`engine:415-423`), correctly handling multi-sample advances. MATCH.

**Verdict: MATCH.**

---

## Unit 5.4 — interpolation + step accumulate — EQUIVALENT

Ref §5.4: `sample = (getSample(pos)*(0x10000-stepPtr) + getSample(pos+1)*stepPtr)>>16`;
then `stepPtr += step; if (stepPtr>=0x10000){pos=nextPos(pos, stepPtr>>16);
stepPtr&=0xffff;}`; vibrato recomputed each sample when active.

FPGA `alu:calc_interp` (111-121): `samp_a + ((samp_b-samp_a)*stepPtr)>>16`.
Algebraically identical to the Ref's weighted form
(`a*(1-f)+b*f == a + (b-a)*f`). The Ref uses 16-bit `stepPtr` as a 0..0xFFFF
weight; FPGA uses the same. EQUIVALENT (provably equal).

Step accumulate: `next_stepPtr = stepPtr + step[15:0]`; carry/overflow advances
pos by `step[31:16] + carry` (`engine:414-423`). Matches `stepPtr += step` plus
`pos += stepPtr>>16`. Vibrato is gated `lfo_active && vib!=0`
(`engine:405`) and fed into `calc_step` (`engine:408-410`) — matches Ref's
per-sample `calcStep(OCT,FN,compute_vib())`.

Subtle (benign): vibrato uses the **registered** `vib_off_r` (1-cycle-delayed)
into `calc_step` (`engine:410`) for timing closure, so the vib offset applied is
from the previous dispatch cycle's `lfo_cnt`, not the exact current one. Within a
slot's 64-cycle window this is the same sample's LFO phase (lfo_cnt only advances
once per frame, at D1b), so no functional error. EQUIVALENT.

**Verdict: EQUIVALENT.**

---

## Unit 6 — Envelope generator state machine — MATCH

Ref §6.1 vs FPGA D1a/D1b (`engine:884-1091`) and the reference `process_eg` task
(`eg:125-236`). The live datapath uses the inlined D1a/D1b split, not the task,
so I verify D1a/D1b.

- **EG_ATT:** Ref `if (rate>=63) break;` (freeze) else gated step
  `env_vol += (~env_vol*inc)>>4`; on `<=MIN` → `DL?EG_DEC:EG_SUS`.
  FPGA `engine:1020-1028`: `if (rate<63 && do_update){ new_vol=calc_attack_step;
  if (new_vol<=MIN) state = dl_idx?EG_DEC:EG_SUS }`. `calc_attack_step`
  (`alu:278-287`) = `ev + ((~ev * inc)>>>4)` with arithmetic shift — exactly
  the Ref `(~env_vol*inc)>>4` (env_vol is non-negative so logical vs arithmetic
  agree on the product sign). When `rate>=63` (AR=15 freeze) the branch is not
  taken → env holds (the Ref `break`). MATCH.
- **EG_DEC:** Ref gated `env_vol += inc; if (env_vol>=DL) state =
  (env_vol<MAX)?EG_SUS:EG_OFF`. FPGA `engine:1030-1039`: same, with explicit
  `vol_add>0x3FF` clamp on the int16 add. `dl_tab_rom(dl_idx)` applied at compare
  (`engine:1035`). MATCH. The DL=15 → `dl_tab[15]=0x3E0 > MAX(0x280)` case: when
  env reaches 0x280 it has not yet reached 0x3E0, so the `>=DL` test is false and
  EG_SUS is not entered; instead env keeps climbing until the `vol_add` clamp /
  the EG_DEC→EG_OFF path. Actually the Ref hits EG_OFF only via `env_vol>=DL`
  being false until 0x3E0, but env is clamped to 0x3FF and the slot keeps
  decaying; **both** Ref and FPGA never enter SUS for DL=15 and the voice decays
  to silence — matches Ref §11.1/flag 7 intent. MATCH.
- **EG_SUS:** Ref `env_vol += inc; if (>=MAX){MAX; EG_OFF}`. FPGA
  `engine:1041-1048`. MATCH.
- **EG_REL:** Ref same as SUS with RR. FPGA `engine:1050-1058`. MATCH.
- **EG_OFF:** nothing. FPGA default — holds. MATCH.

Key-off transition: FPGA `engine:1011-1017` sets EG_REL on `!keyon &&
state∉{OFF,REL}`. The **EG_REL exclusion** is the [07]/release-freeze fix — without
it the branch would re-assert EG_REL every frame and the EG_REL advance would
never run (note rings forever). This correctly mirrors the Ref, where key-off
sets `state=EG_REL` exactly once (edge-triggered) and subsequent frames run the
EG_REL advance. EQUIVALENT-correct.

**Verdict: MATCH.**

---

## Unit 6.2 — keyOnHelper / key-on edge — EQUIVALENT (intended [07])

Ref §6.2: on key-on edge: `env_vol=MAX; if (compute_rate(AR)<63) EG_ATT else
{env_vol=MIN; state=DL?EG_DEC:EG_SUS}; stepPtr=0; pos=0`. Edge-triggered
(only when keyon changes), and also fired on wave-load if keyon already set.

FPGA: edge = `(keyon & ~key_on_prev) | key_retrig` (`engine:909-910`). On edge:
`new_vol=MAX; if (rate<63) EG_ATT else {new_vol=MIN; state=dl_idx?EG_DEC:EG_SUS}`
(`engine:998-1010`), and `pos=0; stepPtr=0` (`engine:1247-1250`). MATCH to
keyOnHelper.

Two intended deviations, both verified correct:
1. **[07] key-on restarts on EVERY edge**, not only from EG_OFF. The standalone
   `process_eg` task still gates on `cur_state==EG_OFF` (`eg:161`) — but that
   task is NOT in the live datapath; the live D1a/D1b path (`engine:998`) restarts
   unconditionally. This matches openMSX, where `keyOnHelper` is called on the
   key-on edge regardless of prior state (the edge guard is `if (!slot.keyon)`,
   i.e. only that keyon was previously 0 — not that the envelope was OFF). The
   FPGA's `key_on_prev`/`key_retrig` reproduce exactly the `!slot.keyon` guard.
   **The dead `process_eg` task's EG_OFF gate is a latent trap if ever wired in;
   flag as documentation/dead-code, not a live bug.**
2. **key_retrig** (`engine:1577-1589`) latches a key-on write while the slot's
   current keyon==0 — catching an intra-frame keyoff→keyon (wave change) that the
   once-per-frame dispatch sample would miss. openMSX processes each write
   immediately so always sees the edge; the FPGA's write-time latch reproduces
   that. Correct and necessary.

**Verdict: EQUIVALENT (intended, correct).**

---

## Unit 6.3 — eg_cnt — MATCH

Ref §6.3: `eg_cnt++` once per output sample, used for EG gate + TL timebase.
FPGA `eg_cnt` increments once per frame (`engine:177`); used for EG gate
(`eg_do_update`, `engine:950`). MATCH for EG use. (TL-timebase use is absent —
see Unit 8.4.) `eg_cnt` is 24-bit (`engine:134`) vs openMSX `unsigned` (32-bit);
the low 24 bits drive all gate masks (max shift 12 → mask 0xFFF), so the width is
ample. MATCH.

---

## Unit 7.1 — compute_rate — MATCH

Ref §7.1: `val==0→0; val==15→63; res=val*4; if (RC!=15){res += 2*clamp(OCT+RC,0,15);
res += FN&0x200?1:0;} clamp(res,0,63)`.

FPGA `alu:calc_eg_rate` (236-260): `val==0→0; val==15→63; res=val*4;
if (rc!=15){oct_rc=rc+oct; clamp [0,15]; res += 2*clamped; if (fn[9]) res+=1;}
clamp res [0,63]`. Bit-exact, including the signed `OCT+RC` clamp at 0 and the
FN bit9 (`fn[9]`) +1. MATCH.

---

## Unit 7.2 — compute_decay_rate (DAMP / PRVB) — MATCH

Ref §7.2: DAMP highest prio: `env_vol<dl_tab[4]?48:63`; PRVB: `env_vol>=dl_tab[6]?20`;
else compute_rate. `dl_tab[4]=0x80`, `dl_tab[6]=0xC0`.

FPGA `alu:calc_decay_rate` (262-273): `if (damp) return ev<0x080?48:63; if (prvb
&& ev>=0x0C0) return 20; return calc_eg_rate(...)`. The constants `0x80` and
`0xC0` are exactly `dl_tab[4]` (4*0x20) and `dl_tab[6]` (6*0x20). Priority order
DAMP > PRVB > normal matches. MATCH.

---

## Unit 8.1 — env + AM combine + 0x280 clip — MATCH

Ref §8.1: `envVol = min(env_vol + (lfo_active&&AM ? compute_am() : 0), 0x280)`.

FPGA D2a `engine:1115-1117`: `env_idx = next_eg_vol + am_off; if (env_idx>0x280)
env_idx=0x280`. `am_off` computed at D1b `engine:1065-1067` gated
`lfo_active && am!=0`. MATCH.

---

## Unit 8.2 / 8.3 — vol_factor two-stage env/TL — MATCH (intended [09])

Ref §8.2/8.3: `smplOut = vol_factor(vol_factor(sample, envVol), TL<<2)`, each
`vol_factor` independently clipping to 0 at index>=0x280:
`vol_mul=0x80-(env&0x3F); vol_shift=7+(env>>6); (x*((0x8000*vol_mul)>>vol_shift))>>15`.

FPGA splits this across D2a/D2b/D2c:
- D2a (`engine:1116-1135`): computes BOTH gains separately, each with its OWN
  0x280 clip — `gain_e = (env_idx>=0x280)?0 : (0x8000*vmul_e)>>vsh_e`;
  `gain_t = (tl_idx>=0x280)?0 : (0x8000*vmul_t)>>vsh_t`. `tl_idx = tl<<2`
  (`engine:1118`). This is the **[09] separate env/TL** fix — two independent
  clips, exactly Ref §8.3.
- D2b (`engine:1155`): `inner = (interp*gain_e)>>>15` — env applied.
- D2c (`engine:1175`): `vol_sample = (inner*gain_t)>>>15` — TL applied.

This is precisely `vol_factor(vol_factor(sample,env),TL<<2)` with each stage's
`>>15` and each stage's independent silence clip. `vmul=0x80-idx[5:0]`,
`vsh=7+idx[9:6]` match Ref bit-for-bit. MATCH.

(The standalone `alu:calc_vol` (128-148) does the OLD single-clip-on-summed-index
form and is NOT used by the live datapath — dead code; flag as documentation
only, not a live bug.)

**Verdict: MATCH.**

---

## Unit 8.4 — TL interpolation / ramp — MISSING (med)

Ref §8.4: `advance()` ramps `TL` toward `TLdest` — volume decrease at 1 step / 27
samples (`tl_int_step==0`), increase at ~1 step / 13.5 samples
(`tl_int_step!=0`), gated by `eg_cnt%9==0`. Direct loads (field-3 bit0=1) set
TL=TLdest instantly.

FPGA: field 3 ALWAYS loads `tl` directly to the destination
(`engine:1355-1356`), regardless of the bit0 load-immediate flag. There is **no
`TLdest`, no `eg_cnt%9` ramp, no per-sample TL stepping**. The code comment
admits it: "Skip TL ramp logic ... TODO: implement TL ramp" (`engine:1352-1354`).

Exposing condition: software that writes a new TL with field-3 bit0=0
(interpolate) expecting a smooth volume glide (common in fade-in/out and
expression on sustained MoonSound voices). On the FPGA the volume jumps
immediately to the new TL instead of ramping over tens of milliseconds.

Effect: audible volume *steps* / zipper noise where the chip would glide; missing
fade smoothing. Not a dropout or wrong-note. **Severity: MEDIUM.**

---

## Unit 8.5 — Panning — MATCH

Ref §8.5: `pan_left/pan_right` tables; `vol = (0x20-(v&0xF))>>(v>>4)`;
`bufs[2j] += (smplOut*volLeft)>>5`. pan=255 → 0 (mute), pan=8 mutes both.

FPGA `alu:pan_left_rom/pan_right_rom` (163-181) reproduce the Ref tables
entry-for-entry (verified: left {0,8,16,24,32,40,48,255,255,0,...},
right {...,255 at 8, 255 at 9, 48,40,32,24,16,8}). `pan_att_calc`
(`alu:158-161`): `p==255?0 : (0x20-p[3:0])>>p[7:4]` — exactly Ref's
`(0x20-(v&0xf))>>(v>>4)` with the 255→0 special-case. Applied at D3a:
`d3_left = (vs_gated*pl_gain)>>>5` (`engine:1209-1210`), the `>>5` normalization.
MATCH. pan=8 → left rom 255 → 0 AND right rom 255 → 0 = both muted (DO1). MATCH.

Panning is applied AFTER the two vol_factor stages and is a third independent
attenuation (`engine:1207-1210`) — matches Ref §8.5 note.

**Verdict: MATCH.**

---

## Unit 8.6 — PCM mix level (reg 0xF9) — MISSING (med)

Ref §8.6: reg 0xF9 → `setMixLevel`, an 8-entry dB table
`{1,0.75,0.5,0.375,0.25,0.1875,0.125,0}` applied as software stereo volume of the
WHOLE PCM device (L=bits0..2, R=bits3..5).

FPGA: reg 0xF9 is not decoded anywhere. The engine's per-slot path has a global
`pcm_vol` OSD gain (`engine:1223`, +6..+24 dB shift), but that is an FPGA-only
master-volume control, NOT the software-programmable per-channel mix level. The
FM-side 0xF8 mix level is likewise absent.

Exposing condition: MoonSound software that sets the PCM (or FM) mix level via
0xF9/0xF8 to balance FM vs PCM or to do master fades. On the FPGA those writes are
silently ignored, so FM/PCM relative balance is fixed and software master fades on
the wave part don't take effect.

Effect: wrong FM/PCM balance and missing master volume automation for titles that
program 0xF8/0xF9. **Severity: MEDIUM** (many MoonSound titles set these once at
init; some animate them).

---

## Unit 8.7 — anyActive / muting — EQUIVALENT

Ref §8.7: device outputs null when no slot active; EG_OFF slots skipped.

FPGA: every slot is always dispatched (MAX_STALL=0, `engine:161`); EG_OFF slots
still flow through the pipeline but contribute `vol_sample≈0` (env clipped to
silence at 0x280) — algebraically the same as "skip + add 0". The accumulator is
zeroed each frame (`engine:1277-1278`) and saturated to 16-bit
(`engine:1272-1275`). No explicit anyActive short-circuit, but the result is
identical (silent slots add 0). EQUIVALENT.

(One real difference vs Ref §8.7 TODO: the FPGA DOES keep updating internal state
of all slots even when "muted", which the Ref flags as a TODO it does NOT do.
The FPGA behavior is arguably more correct.)

**Verdict: EQUIVALENT.**

---

## Unit 9 — CPU wave-memory access — EQUIVALENT (1 low DISCREPANCY)

Ref §9: mode bit R#2[0]; addr regs 3/4 store only, reg 5 commits; reg 6
read/write gated by mode bit with auto-increment; device ID in reg 2 top bits;
"channels stop during mem access" is NOT modeled by openMSX (open TODO).

FPGA: implemented as a low-priority SDRAM requester (`engine:1607-1684`):
- mode bit `reg02_mem_access_mode` (`engine:1630`). Reg 6 write/read only issue
  when mode is set via `cpu_mem_active = mode & cpu_mem_busy` gating dispatch and
  the issue path. Auto-increment on read at `cpu_rd_06` and on write at issue
  (`engine:1648-1649`). MATCH to the access semantics.
- Address commit: high/mid latched at reg 3/4, low at reg 5 (`engine:1645-1647`).
  EQUIVALENT (see Unit 3.2 — committed result equals `{regs3,regs4,low}`).
- Device ID reg 2 readback `001b` top bits (`engine:1696`). MATCH.

**DISCREPANCY (intended, opposite of openMSX):** the FPGA **halts slot dispatch
while a CPU mem transfer is in flight** (`cpu_mem_active` suppresses
`dispatch_now`, `engine:204`). Ref §9/flag 2 says openMSX does NOT stop channels;
the *real chip DOES* stop channels during memory access. So the FPGA is closer to
real HW than openMSX here, but it DIVERGES from the openMSX spec. Crucially the
FPGA only halts during an *actual transfer* (not the whole time the mode bit is
set) — `engine:140-144` notes that halting for the full mode-bit duration silenced
voices, so it was narrowed to in-flight only. Net audible effect vs openMSX: a
brief (sub-frame) gap in all voices during each CPU mem byte transfer, typically
inaudible. **Severity: LOW** (benign, intended, arguably more accurate).

The `getSample()`-during-mem-access ambiguity (Ref flag 1) does not arise because
dispatch is halted during the transfer.

**Verdict: EQUIVALENT** (with one intended LOW divergence).

---

## Unit 10.1 — LFO counter — MATCH

Ref §10.1: `if (lfo_active) lfo_cnt = (lfo_cnt + lfo_period[lfo]) & (LFO_PERIOD-1)`,
once per sample; reset to 0 when inactive (field-4 bit5).

FPGA D1b `engine:1072-1077`: `nd.lfo_cnt = lfo_active ? ((lfo_cnt +
lfo_period_rom(lfo_speed)) & 0x3FFFF) : 0`. LFO_PERIOD-1 = 0x3FFFF (18-bit).
Per-slot `lfo_cnt` is 18-bit (`engine:239`). When inactive forces 0 — matches the
field-4 bit5 reset (`lfo_active=~data[5]`, `engine:1364`). MATCH.

---

## Unit 10.2 — compute_vib (magnitude/12 reciprocal) — MATCH (verified exact)

Ref §10.2: `lfo_fm = lfo_cnt/(LFO_PERIOD/0x40)` = `lfo_cnt>>12` → 0..0x3F;
fold `if (lfo_fm&0x10) ^=0x1F`; sign `if (lfo_fm&0x20) lfo_fm = -(lfo_fm&0x0F)`;
return `(lfo_fm * vib_depth[vib]) / 12` (C++ truncate-toward-zero).

FPGA `alu:compute_vib` (72-91):
- `fm6 = lfo_cnt[17:12]` = `>>12` → 0..63. MATCH.
- fold `if (fm6[4]) fm6 ^= 0x1F`. MATCH.
- `neg = fm6[5]`; `mag_fm = neg ? (fm6&0x0F) : fm6[3:0]` = |lfo_fm|. MATCH.
- `mag = mag_fm * vib_depth_rom(vib)` (0..720, since max 15*48=720).
- `scaled = mag * 43691`; `q = scaled[25:16] >> 3` = `(mag*43691)>>19`.
- return `neg ? -q : q`.

**Reciprocal exactness check:** the claim is `floor(mag*43691/2^19) == floor(mag/12)`
for all mag in [0..720]. `43691/2^19 = 43691/524288 = 0.0833340…`; `1/12 =
0.0833333…`. Error per unit = +1.27e-6. Worst-case mag=720 →
`720*43691 = 31,457,520`; `>>19 = floor(31457520/524288) = floor(60.00018) = 60`
and `floor(720/12)=60`. The positive bias is `mag*(43691/524288 - 1/12) =
mag*1.27e-6`; at mag=720 that's 9.1e-4, far below the 1.0 needed to cross an
integer boundary at any exact multiple of 12 (the only dangerous points). Checked
the multiples-of-12 boundaries: for mag=12k, `12k*43691>>19`: the bias 12k*1.27e-6
≤ 720*1.27e-6 = 9.1e-4 < 1, so it never rounds up past the true quotient. Since
both Ref and FPGA truncate toward zero on the magnitude then re-apply sign, they
are **identical for the entire input range**. MATCH (verified exact).

`vib_depth_rom` (`alu:34-42`) = `{0,2,3,4,6,12,24,48}` — matches Ref §10.2 table.

**Verdict: MATCH.**

---

## Unit 10.3 — compute_am — MATCH

Ref §10.3: `lfo_am = lfo_cnt/(LFO_PERIOD/0x100)` = `lfo_cnt>>10` → 0..0xFF; fold
`if (>=0x80) ^=0xFF`; return `(lfo_am * am_depth[AM]) >> 7`.

FPGA `alu:compute_am` (94-105): `lfo_am = lfo_cnt[17:10]` = `>>10`;
`if (lfo_am[7]) lfo_am ^= 0xFF`; `return (lfo_am * am_depth_rom(am)) >> 7`.
MATCH. `am_depth_rom` (`alu:44-52`) = `{0x00,0x14,0x20,0x28,0x30,0x40,0x50,0x80}`
— matches Ref §10.3 table. Result is added to env_vol at D2a (Unit 8.1). MATCH.

**Verdict: MATCH.**

---

## Unit 11.1 — dl_tab — MATCH

Ref §11.1: `dl_tab[0..14] = idx*0x20`; `dl_tab[15] = SC(93) = 0x3E0`.
FPGA `eg:dl_tab_rom` (106-110): `idx==15 ? 0x3E0 : idx<<5`. `idx<<5 == idx*0x20`.
MATCH entry-for-entry, including the out-of-range 0x3E0 for index 15.

---

## Unit 11.2 — eg_inc — MATCH

Ref §11.2 15-row × 8-cycle table vs FPGA `eg:eg_inc_rom` (21-55), indexed
`row=idx[6:3], ph=idx[2:0]`. Verified each row's 8-phase pattern:

| row | Ref pattern | FPGA decode | ok |
|-----|-------------|-------------|----|
| 0 | 0 1 0 1 0 1 0 1 | `ph[0]?1:0` | ✓ |
| 1 | 0 1 0 1 1 1 0 1 | ph4,5→1 else ph[0] | ✓ |
| 2 | 0 1 1 1 0 1 1 1 | ph0,4→0 else 1 | ✓ |
| 3 | 0 1 1 1 1 1 1 1 | ph0→0 else 1 | ✓ |
| 4 | 1×8 | 1 | ✓ |
| 5 | 1 1 1 2 1 1 1 2 | ph[1:0]==11→2 else 1 | ✓ |
| 6 | 1 2 1 2 1 2 1 2 | ph[0]?2:1 | ✓ |
| 7 | 1 2 2 2 1 2 2 2 | ph0,4→1 else 2 | ✓ |
| 8 | 2×8 | 2 | ✓ |
| 9 | 2 2 2 4 2 2 2 4 | ph[1:0]==11→4 else 2 | ✓ |
| 10 | 2 4 2 4 2 4 2 4 | ph[0]?4:2 | ✓ |
| 11 | 2 4 4 4 2 4 4 4 | ph0,4→2 else 4 | ✓ |
| 12 | 4×8 | 4 | ✓ |
| 13 | 8×8 | 8 | ✓ |
| 14 | 0×8 | 0 (default) | ✓ |

MATCH.

---

## Unit 11.3 — eg_rate_select — **DISCREPANCY (med)**

Ref §11.3 (`YMF278.cc:107-125`), exact 64-entry table, `O(a)=a*8`:
```
idx  0..3  : O(14)=112
idx  4..47 : repeating O(0),O(1),O(2),O(3) = 0,8,16,24
idx 48..51 : O(4),O(5),O(6),O(7)   = 32,40,48,56
idx 52..55 : O(8),O(9),O(10),O(11) = 64,72,80,88
idx 56..63 : O(12)=96  (eight entries)
```

FPGA `eg:eg_rate_select_rom` (57-85) decodes `row=idx[5:2], ph=idx[1:0]`:
```
row 0  (idx 0..3)   -> 112                         ✓ (== O(14))
row 13 (idx 52..55) -> 32,40,48,56                 -- value of O(4..7)
row 14 (idx 56..59) -> 64,72,80,88                 -- value of O(8..11)
row 15 (idx 60..63) -> 96                           ✓ (== O(12))
default (rows 1..12, idx 4..51) -> 0,8,16,24       -- O(0..3)
```

Map FPGA vs Ref per internal rate:

| rate idx | Ref select | FPGA select | match |
|----------|-----------|-------------|-------|
| 4..47   | O(0..3) = 0,8,16,24 | default 0,8,16,24 | ✓ |
| **48..51** | **O(4..7) = 32,40,48,56** | default = **0,8,16,24** | ✗ |
| **52..55** | **O(8..11) = 64,72,80,88** | row13 = **32,40,48,56** | ✗ |
| **56..59** | **O(12) = 96** | row14 = **64,72,80,88** | ✗ |
| 60..63  | O(12) = 96 | row15 = 96 | ✓ |

The FPGA table is **row-shifted by one group of 4 for internal rates 48..59**:
rates 48..51 use the rate-≤47 increment rows (eg_inc rows 0..3, max +1) instead of
rows 4..7 (rate-13 increments, up to +2); rates 52..55 use rows 4..7 instead of
8..11 (rate-14, up to +4); rates 56..59 use rows 8..11 instead of row 12
(constant +4). Only rates 0..47 and 60..63 are correct.

(Note: `eg_rate_shift` for all of 48..63 is 0, so `eg_do_update` is always true at
these rates and the select value directly sets the per-sample increment.)

Exposing condition: any envelope segment (DEC/SUS/REL, and attack via
`eg_rate_select` too) whose computed internal rate lands in **48..59**. That
happens with high rate registers (D1R/D2R/RR/AR around 12..14) plus octave/RC
rate-correction, OR AR/rates that compute to those values. Internal rate 63 is
special-cased (val==15 or clamp), and 60..62 are correct, but 48..59 are common
for "fast but not instant" decays/releases.

Effect: those envelope phases advance with a **smaller increment than the chip**,
so fast decays/releases are **too slow** (notes sustain/release longer than they
should; percussive PCM decays sound less snappy). Attack at internal rate 48..59
similarly under-increments (the attack uses `(~env*inc)>>4`, smaller inc → slower
attack). Audible on instruments tuned for sharp envelopes.

Fix: re-derive `eg_rate_select_rom` so rows map as Ref — e.g. add explicit cases
for `idx[5:2]==12 → O(4..7)`, `==13 → O(8..11)`, `==14 → O(12)`, `==15 → O(12)`,
keeping default `0,8,16,24` only for rows 1..11.

**Verdict: DISCREPANCY, severity MEDIUM.**

---

## Unit 11.4 — eg_rate_shift — MATCH

Ref §11.4: shift = 12,11,10,9,8,7,6,5,4,3,2,1,0 for rate groups 0..12, then 0 for
13..15 (each value ×4). FPGA `eg:eg_rate_shift_rom` (87-104) decodes `idx[5:2]`:
rows 0..11 → 12..1 decreasing, default (rows 12..15) → 0. So idx 0..3→12,
4..7→11, …, 44..47→1, 48..63→0. Exactly the Ref (4-entry groups). MATCH.

`eg_do_update` (`eg:113-117`) = `(cnt & ((1<<sh)-1))==0` — the Ref gate
`!(eg_cnt & ((1<<shift)-1))`. `eg_phase` = `(cnt>>sh)&7` — the Ref index
`(eg_cnt>>shift)&7`. MATCH.

---

## Unit 11.5 — lfo_period / vib_depth / am_depth / pan — MATCH

- `lfo_period_rom` (`alu:54-63`) = `{1,12,19,25,31,35,37,42}` — matches Ref §10.1
  L() table exactly.
- `vib_depth_rom`, `am_depth_rom`, `pan_left/right_rom` — verified in Units 10.2,
  10.3, 8.5. All MATCH.

---

## Unit 12 — Status / IRQ / busy / load — EQUIVALENT

Ref §12: combined status = OPL3 status | YMF278 status; bit0 BUSY (time<busyTime),
bit1 LOAD (time<loadTime); WAVE select/write = 88 master cycles, regs 3-6 = 28
(MEM_WRITE), mem read = 38, FM = 56, LOAD = 10000.

FPGA `regs`: busy/load are down-counters (`regs:96-128`) loaded with the same
constants: `WAVE_REG_SELECT/WRITE_DELAY=88` (`regs:49-50`), `MEM_WRITE_DELAY=28`
(`regs:52`, used for regs 3-6 `regs:145-146`), `MEM_READ_DELAY=38` (`regs:51`),
`FM_*=56` (`regs:47-48`), `LOAD_DELAY=10000` (`regs:53`, armed for regs 0x08..0x1F
`regs:143-144`). Combined status `opl3_status | {load_busy, busy}` at
`regs:211/214`. MATCH on all delay constants and the status bit layout.

EQUIVALENT (not MATCH) because: the FPGA models BUSY/LOAD as a *cycle countdown*
on the 33.8688 MHz domain rather than openMSX's absolute-time comparison, and OR's
in `pcm_cpu_mem_busy` so a long SDRAM-windowed CPU transfer keeps BUSY asserted
past the fixed 28-cycle delay (`regs:92`) — a deliberate correctness improvement
over the fixed delay (prevents the CPU overwriting `cpu_wr_data_latch` mid-write).
The IRQ path comes straight from the OPL3 core's `irq_n` (`top:116`); FM
status/timers are the gtaylormb core's, synchronized across clock domains
(`top:124-129`). Structurally consistent with Ref §12/§13.

**Verdict: EQUIVALENT.**

---

## Unit 13 — FM core — OUT OF SCOPE

The FM/OPL3 is the gtaylormb core (`rtl/opl3/`), instantiated at `top:98-118`.
Per task scope, only its existence is noted. The OPL4-specific glue (NEW2 gating,
FM register shadow for chip-detect readback, mix into the PCM stream) lives in
`regs`/`top` and was checked under Units 2 and 12.

---

## Discrepancies ranked by severity

1. **MEDIUM — Unit 11.3 `eg_rate_select_rom` row-shifted for internal rates
   48..59** (`eg:57-85`). Fast decay/sustain/release (and attack) at those rates
   under-increment → envelopes too slow / notes not snappy. Reachable with high
   rate registers + rate correction. Fix: remap rows 12/13/14 to O(4..7)/O(8..11)/
   O(12).
2. **MEDIUM — Unit 8.4 TL interpolation/ramp not implemented** (`engine:1352-1356`).
   field-3 always loads TL instantly, no `eg_cnt%9` ramp, no `TLdest`. Smooth
   TL fades become volume steps / zipper noise.
3. **MEDIUM — Unit 8.6 PCM/FM mix level (reg 0xF9 / 0xF8) not implemented.**
   `setMixLevel` table absent; software FM/PCM balance and master fades ignored.
4. **LOW — Unit 9 channel-halt during CPU mem access** (`engine:204`,
   `cpu_mem_active`). Diverges from openMSX (which never halts) but matches real
   HW; sub-frame gap, typically inaudible. Intended.
5. **LOW — Unit 2 0xF8/0xF9 not specially decoded on the WAVE port** (subset of
   8.6).

Documentation/dead-code traps (NOT live bugs, but should be cleaned to avoid
future regressions):
- `eg:process_eg` task still gates key-on restart on `cur_state==EG_OFF`
  (`eg:161`) — contradicts the live [07] behavior. The task is unused; do not wire
  it back without fixing.
- `alu:calc_vol` (128-148) implements the OLD single-clip-on-summed-index volume —
  contradicts the live [09] two-stage split. Unused.
- Stale "TODO ... Skipped for v2 MVP" comment at `engine:1546-1548`; the backfill
  IS implemented at `engine:1400-1421`.

---

## Verified-equivalent (non-obvious) — do not re-flag

1. **calc_interp** (`alu:111-121`): `a + (b-a)*f >> 16` is algebraically identical
   to the Ref's `(a*(0x10000-f) + b*f) >> 16`. Equal for all inputs.
2. **compute_vib reciprocal** (`alu:88-89`): `(mag*43691)>>19 == floor(mag/12)`
   proven exact for mag∈[0..720] (the full reachable range); sign re-applied =
   C++ truncate-toward-zero. Verified at all multiples-of-12 boundaries.
3. **Two-stage env/TL volume** (`engine:1116-1175`): D2a/D2b/D2c cascade reproduces
   `vol_factor(vol_factor(sample,env),TL<<2)` with independent 0x280 clips. The
   pipelining (gains computed off the sample path) does not change the result.
4. **Per-dispatch step recompute** instead of cached `slot.step`
   (`engine:408-410`): same value as the Ref's cached `calcStep(OCT,FN)`; caching
   was only an openMSX micro-optimization.
5. **Address committed directly into cpu_mem_adr** (vs Ref's regs[]+commit)
   (`engine:1645-1647`): the committed 24-bit address after a 3/4/5 sequence is
   identical; reg 3/4 having no separate shadow is irrelevant because they are not
   read back independently.
6. **lfo_cnt forced to 0 while inactive** (`engine:1073-1077`) reproduces the
   field-4 bit5 LFO reset without a second writer; equivalent to Ref's
   `lfo_active=false; lfo_cnt=0`.
7. **vib_off_r 1-cycle delay** into calc_step (`engine:410`): lfo_cnt only changes
   once per frame, so the delayed value equals the current sample's LFO phase. No
   functional error.
8. **EG_REL exclusion in the key-off branch** (`engine:1011-1012`): prevents
   re-asserting EG_REL every frame; matches the Ref's edge-triggered single
   `state=EG_REL` assignment + per-frame EG_REL advance.
