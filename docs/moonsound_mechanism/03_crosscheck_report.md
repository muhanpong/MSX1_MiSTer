# Cross-check / Audit — openMSX spec (doc #1) vs FPGA match analysis (doc #2)

Independent adversarial re-verification against ground-truth source.
Sources re-read:
- openMSX: `openMSX/src/sound/YMF278.cc`
- FPGA: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine.sv`,
  `ymf278_pcm_alu.sv`, `ymf278_pcm_eg_step.sv`.

**Headline:** the single "med" table-bug finding in doc #2 (Unit 11.3
`eg_rate_select_rom` row-shift) is **REFUTED** — the FPGA table is bit-exact to
openMSX. BOTH doc #1 and doc #2 mis-transcribed the openMSX `eg_rate_select`
array (off by one 4-entry group). The other three re-verified findings hold.
A **NEW genuine discrepancy** was found that neither doc caught and that is a
strong candidate for the "decay-too-fast / dead channel" and wave-change
"direction-dependency" symptoms: **the FPGA does not re-trigger the envelope on a
wave-number write while keyon is already high** (openMSX calls `keyOnHelper`
there).

---

## Verdict per re-verified finding (the 4 requested)

| # | Finding (doc #2) | Verdict |
|---|------------------|---------|
| 1 | Unit 11.3 `eg_rate_select_rom` row-shift, rates 48..59 | **REFUTED** |
| 2 | Unit 8.4 TL interpolation/ramp MISSING | **CONFIRMED** |
| 3 | Unit 8.6 mix level 0xF9/0xF8 MISSING | **CONFIRMED** |
| 4a | compute_vib `(mag*43691)>>19 == floor(mag/12)` exact | **CONFIRMED** |
| 4b | 12-bit loop-seam [19] decode correct | **CONFIRMED** |

---

## 1. THE eg_rate_select_rom CLAIM — **REFUTED** (false positive; doc-#1 spec error propagated)

This is doc #2's #1 ranked issue. It is wrong. The error originates in **doc #1
§11.3**, which mis-counts the openMSX `eg_rate_select` array, and doc #2 faithfully
re-applied the wrong reference and then "found" a discrepancy against an FPGA that
is actually correct.

### Ground-truth openMSX table (`YMF278.cc:108-125`), verbatim

```
static constexpr std::array<uint8_t, 64> eg_rate_select = {
    O(14),O(14),O(14),O(14),   // line 109  idx  0.. 3
    O( 0),O( 1),O( 2),O( 3),   // line 110  idx  4.. 7
    O( 0),O( 1),O( 2),O( 3),   // line 111  idx  8..11
    O( 0),O( 1),O( 2),O( 3),   // line 112  idx 12..15
    O( 0),O( 1),O( 2),O( 3),   // line 113  idx 16..19
    O( 0),O( 1),O( 2),O( 3),   // line 114  idx 20..23
    O( 0),O( 1),O( 2),O( 3),   // line 115  idx 24..27
    O( 0),O( 1),O( 2),O( 3),   // line 116  idx 28..31
    O( 0),O( 1),O( 2),O( 3),   // line 117  idx 32..35
    O( 0),O( 1),O( 2),O( 3),   // line 118  idx 36..39
    O( 0),O( 1),O( 2),O( 3),   // line 119  idx 40..43
    O( 0),O( 1),O( 2),O( 3),   // line 120  idx 44..47
    O( 0),O( 1),O( 2),O( 3),   // line 121  idx 48..51   <-- still O(0..3)!
    O( 4),O( 5),O( 6),O( 7),   // line 122  idx 52..55
    O( 8),O( 9),O(10),O(11),   // line 123  idx 56..59
    O(12),O(12),O(12),O(12),   // line 124  idx 60..63
};
```

There are **twelve** `O(0),O(1),O(2),O(3)` rows (lines 110–121), spanning
**idx 4..51**. The "high" rows begin at **idx 52**, not 48. With `O(a)=a*8`:

| internal rate | openMSX select | FPGA `eg_rate_select_rom` | match |
|---|---|---|---|
| 4..47 | O(0..3) = 0,8,16,24 | default rows 1..12 = 0,8,16,24 | ✓ |
| **48..51** | **O(0..3) = 0,8,16,24** | default = **0,8,16,24** | ✓ |
| 52..55 | O(4..7) = 32,40,48,56 | row13 = 32,40,48,56 | ✓ |
| 56..59 | O(8..11) = 64,72,80,88 | row14 = 64,72,80,88 | ✓ |
| 60..63 | O(12) = 96 | row15 = 96 | ✓ |

### FPGA table (`ymf278_pcm_eg_step.sv:57-85`), verbatim decode

```
row = idx[5:2]; ph = idx[1:0];
row 0  (idx  0..3)  -> 112              == O(14)
row 13 (idx 52..55) -> 32,40,48,56      == O(4..7)
row 14 (idx 56..59) -> 64,72,80,88      == O(8..11)
row 15 (idx 60..63) -> 96               == O(12)
default rows 1..12 (idx 4..51) -> 0,8,16,24   == O(0..3)
```

Programmatic check of all 64 entries (openMSX reconstructed from source vs FPGA
function): **0 mismatches.** Rates 48..51 = `{0,8,16,24}` in BOTH; rates 52..55 =
`{32,40,48,56}` in BOTH; rates 56..59 = `{64,72,80,88}` in BOTH; rates 60..63 =
`96` in BOTH.

**Where doc #2 went wrong:** doc #2's table (§11.3) labels the FPGA's `row 13`
(idx 52..55) as if openMSX put `O(8..11)` there and the FPGA put `O(4..7)` — i.e.
it shifted the *openMSX* column up by one group. That shift is exactly the
miscount in doc #1 §11.3. The FPGA `default → 0,8,16,24` extends through idx 51,
which is **correct**, because openMSX's 12th `O(0..3)` row also reaches idx 51.

**Reachability/effect (now moot):** since the tables match, there is no
under-increment of fast decays/releases from this path. The whole "fast decays
too slow / not snappy" effect attributed to this finding does NOT come from
`eg_rate_select`. (The eg_rate_shift table — `YMF278.cc:130-147` vs
`ymf278_pcm_eg_step.sv:87-104` — was also re-checked: shift = 12,11,…,1 for idx
groups 0..11 and 0 for idx 48..63, identical on both sides.)

> **REFUTED.** Remove this from the issue list. Fix doc #1 §11.3 and doc #2 §11.3:
> the O(0..3) run is **12 groups (idx 4..51)**, high rows start at **idx 52**.

---

## 2. TL interpolation / ramp MISSING — **CONFIRMED**

openMSX (`YMF278.cc:335-349`) genuinely ramps TL once per sample in `advance()`:
```
auto tl_int_cnt  =  eg_cnt % 9;       // 0..8
auto tl_int_step = (eg_cnt / 9) % 3;  // 0..2
if (tl_int_cnt == 0) {
    if (tl_int_step == 0) { if (op.TL < op.TLdest) ++op.TL; }   // -vol, 1 step/27 smp
    else                  { if (op.TL > op.TLdest) --op.TL; }   // +vol, 1 step/13.5 smp
}
```
and field-3 (`YMF278.cc:637-646`) sets `TLdest`, only copying to `TL`
*immediately* when bit0=1; otherwise `TL` is left to ramp.

FPGA field-3 (`ymf278_pcm_engine.sv:1351-1356`):
```
// Skip TL ramp logic ... TODO: implement TL ramp.
tl_t = reg_data[7:1];
reg_upd.tl = (tl_t != 7'h7F) ? {1'b0, tl_t} : 8'hFF;
```
`tl` is loaded directly **regardless of bit0**; there is no `TLdest`, no `eg_cnt%9`
counter, no per-sample stepping anywhere in `engine`/`alu` (grep confirms no
`TLdest`/`tl_int` in the RTL). The `0x7F→0xFF` remap IS present and correct.

**Effect:** writes with bit0=0 that the chip would glide over tens of ms become
instantaneous volume steps (zipper noise on fades/expression). Confirmed med.

> **CONFIRMED.** Severity MEDIUM is reasonable. See note in root-cause section on
> why this can *contribute* to "decay too fast" perception on expression-driven
> patches.

---

## 3. Mix level reg 0xF9 / 0xF8 (`setMixLevel`) MISSING — **CONFIRMED**

openMSX `setMixLevel` (`YMF278.cc:491-504`) exists and is wired:
`YMF278B::writeIO` routes `opl4latch==0xf9 → ymf278.setMixLevel`, `0xf8 →
ymf262.setMixLevel` (doc #1 §2, `YMF278B.cc:164-168`). Table
`{1,0.75,0.5,0.375,0.25,0.1875,0.125,0}`, L=bits0..2, R=bits3..5; reset 0xF8=0x1B
(-9 dB), 0xF9=0x00 (`YMF278.cc:842`).

FPGA: grep for `F9|F8|setMixLevel|mix_level` across the engine returns **nothing**
in the PCM data path. Reg 0xF9/0xF8 fall through as ordinary (no-op) writes; the
only PCM-wide gain is `pcm_vol` (`engine:1223`), an OSD master shift (+6..+24 dB),
which is NOT the software-programmable per-side mix level. The FM-side 0xF8 is
likewise unimplemented.

**Effect:** software-programmed FM/PCM balance and master fades via 0xF8/0xF9 are
ignored. Confirmed med.

> **CONFIRMED.** Note: the openMSX reset value 0xF8=0x1B = -9 dB on FM means the
> FPGA, which omits this, runs the FM part ~9 dB hotter than openMSX's default
> unless the gtaylormb core applies its own attenuation — worth a FM/PCM balance
> sanity check, but not a PCM-decay cause.

---

## 4a. compute_vib reciprocal `(mag*43691)>>19 == floor(mag/12)` — **CONFIRMED exact**

Re-derived independently over the full reachable range mag ∈ [0..720]
(max = |lfo_fm|·depth = 15·48). For every mag, `floor(mag*43691/524288)` equals
`floor(mag/12)`; **0 mismatches** across 0..720 (brute-checked). The constant
`43691/2^19 = 0.08333397…` vs `1/12 = 0.08333…`; positive bias ≤ 720·1.27e-6 ≈
9.1e-4 < 1, so it never crosses a multiple-of-12 boundary. FPGA applies it on the
unsigned magnitude then re-signs (`alu:86-90`), matching C++ truncate-toward-zero.
`vib_depth_rom = {0,2,3,4,6,12,24,48}` matches `YMF278.cc:167-176`.

> **CONFIRMED.** doc #2 §10.2 is correct.

---

## 4b. 12-bit loop-seam [19] decode — **CONFIRMED**

openMSX decodes sample B as `getSample(sl, nextPos(sl, sl.pos, 1))`
(`YMF278.cc:524-526`) — B's address/parity derive from the *wrapped* position,
independent of A. FPGA (`engine:678-718`):
- contiguous (no wrap): B uses A's parity to pick same-chunk (A even) or
  next-chunk (A odd) — matches `decode_sample`'s `p[0]` selection;
- **split / loop-seam** (`sb_split`): B is decoded from the separately-fetched
  loop-start chunk bytes `sbb3/sbb4/sbb5` using **`stage_b_reg.next_pos` parity**
  (line 697-698), i.e. B's own parity, exactly as openMSX. The previous bug
  (branch on A's parity assuming B=A+1) is fixed.

`decode_sample` fmt-1 (`alu:222-227`) is bit-exact to `YMF278.cc:440-448`
(even = `{b0,(b1<<4)&0xF0}`, odd = `{b2,b1&0xF0}`, low nibble zero).

> **CONFIRMED.** doc #2 §5.1 is correct.

---

## C. Spot-checks of "MATCH/EQUIVALENT" units (false-negative hunt)

| Unit | Re-check | Result |
|------|----------|--------|
| EG state machine ATT/DEC/SUS/REL/OFF | `YMF278.cc:357-419` vs `engine:1019-1061` / `eg:172-234` | MATCH (live D1a/D1b path) |
| key-on edge guard vs `if(!slot.keyon)` | `YMF278.cc:669-673` vs `engine:1581-1582` (`reg_data[7] && !cur_r.keyon`) | MATCH |
| key-off → EG_REL | `YMF278.cc:674-678` vs `engine:1011-1017` (+EG_REL exclusion) | MATCH; 1-sample-late REL advance, benign |
| DL=0 ATT→SUS path | `YMF278.cc:374` vs `engine:1009,1025,1183` | MATCH (`dl_idx!=0 ? DEC : SUS`) |
| EG_OFF hold | default no-op | MATCH |
| two-stage env/TL 0x280 clip | `YMF278.cc:536` vs `engine:1116-1175` | MATCH (independent clips) |
| nextPos loop-wrap / Lizard overrun | `YMF278.cc:463-472` vs `engine:347-358` | MATCH (bit-identical 16-bit wrap) |
| getSample 8/12/16 | `YMF278.cc:432-460` vs `alu:215-231` | MATCH |
| calcStep oct=-8 / `<<(8+oct)>>3` | `YMF278.cc:215-220` vs `alu:12-23` | MATCH |
| compute_rate RC/OCT/FN9 clamp | `YMF278.cc:246-260` (in source) vs `alu:236-260` | MATCH |
| compute_decay_rate DAMP/PRVB | `YMF278.cc` vs `alu:262-273` (`<0x80?48:63`, `>=0xC0→20`) | MATCH |
| keyOnHelper field-4 path | `YMF278.cc:564-579` vs `engine:998-1010,1247-1250` | MATCH |

No false negatives in the above. **One real false negative found — see D.**

### Header-fetch (HF) latency vs openMSX synchronous load
openMSX loads the 12 header bytes *synchronously* at write time
(`YMF278.cc:600-605`). The FPGA defers to an SDRAM FSM (~1 frame) and gates output
with `vs_gated = hf_pending ? 0 : vol_sample` (`engine:1208`). Doc #2 calls this
"closer to the chip LD-busy behaviour." That is fair for the *header content*, but
it does NOT reproduce the chip's "LD busy → registers locked" semantics in full,
and more importantly it does **not** reproduce the synchronous **keyOnHelper
re-trigger** that openMSX runs at the END of the same header load (see D). So the
HF gate matches openMSX's *data* timing but misses openMSX's *envelope side
effect*.

---

## D. NEW discrepancy neither doc caught — **wave-write re-trigger while keyon=1**

**openMSX `writeRegDirect` case 0 (`YMF278.cc:616-621`):**
```
if (slot.keyon) {
    keyOnHelper(slot);          // env_vol=MAX, state=EG_ATT (or DEC/SUS), pos=0, stepPtr=0
} else {
    slot.stepPtr = 0;
    slot.pos = 0;
}
```
i.e. **any** write to the wave-number low byte (field 0) *unconditionally*
re-triggers the full envelope+position when the slot's keyon is already set. This
is a wave change *without* a keyoff/keyon toggle.

**FPGA:** a field-0/1 write sets only `hf_pending` (`engine:1556,1564`) → header
reload + a ~1-frame output mute. It does **not** set `key_on_edge`/`key_retrig`
(those are driven solely by a field-4 bit7 rising edge, `engine:1581-1582`), and
the pos/env reset at `engine:1247-1250` fires **only** on `key_on_edge`. The HF
backfill (`engine:1400-1421`) rewrites only the timbre fields. **Net: on a bare
wave-number change with keyon held high, the FPGA keeps the old `env_vol`, `state`
and `pos`; openMSX restarts attack from silence at pos 0.**

This is precisely an envelope/position *re-trigger* divergence and is a leading
explanation for the reported wave-change **direction dependency**:
- Sequence with a keyoff→keyon toggle around the wave write → FPGA `key_retrig`
  catches it → re-attack (matches chip).
- Sequence that just rewrites the wave number with keyon staying high (the
  "[124]→[123]" style direct overwrite) → FPGA does NOT re-attack → the new wave
  plays from the *old slot's mid-decayed envelope* (often already near silence) →
  perceived as a "dead"/too-quiet channel that depends on which order/way the
  patch was switched.

The commit log entry "tb: wave-change header-reload test (negative result: HF
reload is correct)" verified the *header bytes* reload but did **not** test the
`keyon==1 → keyOnHelper` re-trigger; that path is unimplemented.

> **NEW — severity MEDIUM-HIGH.** Recommend: in the wave-write decoder, when the
> slot's current `keyon` is set, raise the same re-trigger that `key_on_edge`
> uses (reset env_vol=MAX/state per AR, pos=0, stepPtr=0) after the header
> reload completes; when keyon is clear, reset only pos/stepPtr (already
> effectively the case via the dyn reset). This mirrors `YMF278.cc:616-621`.

### Minor new note (LOW)
EG_DEC `narrow<int16_t>` in openMSX (`YMF278.cc:384`) has no explicit 0x3FF clamp;
the FPGA adds `vol_add>0x3FF→0x3FF` (`engine:1033`). With increments ≤8 and env
capped near 0x280/0x3E0 this never diverges audibly. Not a bug.

---

## E. Spec-fidelity errors found

1. **doc #1 §11.3 (and the inherited doc #2 §11.3): `eg_rate_select` mis-counted.**
   The correct openMSX layout is idx 0..3 = O(14); **idx 4..51 = O(0..3) (12
   groups)**; idx 52..55 = O(4..7); idx 56..59 = O(8..11); idx 60..63 = O(12).
   Doc #1 wrote "rate 4..47 … 48..51 = O(4..7) … 56..63 = O(12)", which shifts the
   high block down by one group of 4. This is the root error that produced doc
   #2's false-positive discrepancy.
2. Everything else in doc #1 that I spot-checked (calcStep, vol_factor two-stage,
   nextPos, getSample, compute_rate/decay, dl_tab, eg_inc, lfo/vib/am tables, pan
   tables, setMixLevel) is accurate.

---

## F. Severity re-ranking + symptom mapping

Re-ranked confirmed issues (most → least likely to explain the user's hardware
symptoms):

1. **NEW: wave-write re-trigger while keyon=1 missing** — **MED-HIGH.**
   Explains (ii) wave-change **direction dependency** directly, and is the
   strongest single candidate for (i) **decay-too-fast / "dead" channels**: a new
   wave inherits the previous note's already-decayed/EG_OFF-bound envelope instead
   of re-attacking, so the channel sounds prematurely dead exactly when the music
   changes waves without a key toggle. Also feeds (iii) timbre-off (attack
   transient missing).
2. **TL ramp missing (Unit 8.4)** — **MED.** Patches that *fade in/out via TL*
   (expression) jump instantly; a patch that ramps TL up at note start will sound
   like it "starts loud then is fine," or a TL-down fade will cut abruptly —
   perceptible as wrong dynamics / mild "decay" feel on sustained voices. Secondary
   contributor to (i) and (iii).
3. **Mix level 0xF9/0xF8 missing (Unit 8.6)** — **MED.** Wrong FM/PCM balance and
   missing master fades; contributes to (iii) overall-balance "위화감" but does not
   make a single channel decay fast.
4. **eg_rate_select row-shift** — **REMOVED (refuted).** Not a real issue.
5. **CPU-mem channel-halt (Unit 9)** — **LOW**, intended, sub-frame, keep as is.

The decay-too-fast / dead-channel symptom is **NOT** caused by an envelope-rate
table error (that finding is refuted). The envelope *rates* are correct on both
sides.

---

## Actionable, confirmed root-cause candidates (ranked)

1. **Implement the wave-write re-trigger (keyon=1 → keyOnHelper).** Mirror
   `YMF278.cc:616-621`. Most likely fix for both the dead-channel and the
   wave-change direction dependency. *(NEW — highest priority.)*
2. **Implement TL ramp** (`TLdest` + `eg_cnt%9` / +27 / -13.5 stepping; bit0=1 =
   instant load). Mirror `YMF278.cc:335-349,637-646`. Fixes expression/fade glides.
3. **Implement `setMixLevel` for reg 0xF9 (PCM) and 0xF8 (FM)** with the 8-entry dB
   table, L=bits0..2 / R=bits3..5; honor reset 0xF8=0x1B. Fixes FM/PCM balance.
4. **Documentation fixes:** correct `eg_rate_select` transcription in docs #1/#2;
   delete the refuted §11.3 discrepancy. Optionally clean the dead `process_eg`
   EG_OFF gate and dead `calc_vol` (doc #2 already flagged these as latent traps —
   that assessment stands and is worth doing).

---

## One-line answers (as requested)

- Report file: `/home/muhanpong/Documents/github/MSX1_MiSTer/docs/moonsound_mechanism/03_crosscheck_report.md`
- eg_rate_select row-shift: **REFUTED**
- TL ramp missing: **CONFIRMED**
- mix level 0xF9/0xF8 missing: **CONFIRMED**
- compute_vib reciprocal exact: **CONFIRMED**
- loop-seam [19] decode: **CONFIRMED**
- New finding: **wave-number write while keyon=1 does not re-trigger the
  envelope/position (openMSX calls keyOnHelper; FPGA does not).**
- Most-likely root cause of "decay-too-fast / dead channel": **the missing
  wave-write re-trigger** — the channel inherits the prior note's decayed envelope
  instead of re-attacking, not an envelope-rate table error.
