# 04 — Attack / Note-Onset (초기음 형성) Analysis

Adversarial comparison of the FPGA YMF278B (OPL4/MoonSound) PCM re-implementation
against the openMSX C++ reference, scoped to **key-on → first audible samples**.

- Reference: `/home/muhanpong/Documents/github/openMSX/src/sound/YMF278.cc`
- DUT:
  - `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine.sv`
  - `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_alu.sv`
  - `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_eg_step.sv`

**Important structural fact (verified):** `process_eg()` in `ymf278_pcm_eg_step.sv`
is **dead code** for the onset — it is referenced only in comments
(`grep "process_eg"` → engine.sv comments only). The *live* EG/onset path is the
inline **D1a (engine.sv:909-1007)** + **D1b (1012-1127)** pipeline. The
`process_eg` task still carries the **old buggy gate** `if (key_on_edge &&
cur_state == EG_OFF)` (eg_step.sv:161) — but since it is never instantiated, it
does not affect behavior. The live D1a/D1b path correctly restarts on **any**
key-on edge (engine.sv:1034 comment explicitly documents removing the EG_OFF
gate). Flagged below as a latent-trap note, not an active bug.

---

## Verdict table

| # | Onset aspect | Verdict |
|---|--------------|---------|
| 1 | keyOnHelper equivalence (env reset + EG_ATT / AR=15 instant + pos/stepPtr reset) | **EQUIVALENT** (timing-shifted, see #4/#5) |
| 2 | Attack-shape formula `~env_vol*inc>>4` (width/sign/shift/clamp) | **MATCH** (bit-exact) |
| 3 | Attack rate gating `!(eg_cnt&((1<<shift)-1))` + shift/sel/inc ROMs | **MATCH** (bit-exact) |
| 4 | First-sample formation (pos=0/stepPtr=0/interp at onset) | **DISCREPANCY (low)** — env-vs-sample 1-frame lead |
| 5 | Onset timing/ordering (header → backfill regs → keyOnHelper) | **EQUIVALENT** — deferral uses NEW wave AR/DL/RC |
| 6 | Interaction of deferred re-trigger + EG_OFF read-skip + interp-clear + stale-gate | **EQUIVALENT** — one extra silent frame, no wrong sample |
| 7 | DAMP / DL=0 / env resolution / attack→decay handoff | **MATCH** |

No high/critical onset discrepancy found. One low-severity systemic offset (#4).

---

## Detailed findings

### 1. keyOnHelper equivalence — EQUIVALENT

openMSX (YMF278.cc:564-579):
```cpp
slot.env_vol = MAX_ATT_INDEX;
if (slot.compute_rate(slot.AR) < 63) { slot.state = EG_ATT; }
else { slot.env_vol = MIN_ATT_INDEX; slot.state = slot.DL ? EG_DEC : EG_SUS; }
slot.stepPtr = 0; slot.pos = 0;
```
Called on EVERY key-on edge: case-4 `if(!keyon){keyon=true; keyOnHelper();}`
(669-673) and case-0 wave-write `if(keyon) keyOnHelper()` (616-617).

FPGA D1b (engine.sv:1034-1046), reached whenever `key_on_edge` is set:
```systemverilog
new_vol = MAX_ATT_INDEX;
if (d1a_pkt.rate < 6'd63) new_state = EG_ATT;
else begin new_vol = MIN_ATT_INDEX;
           new_state = (d1a_pkt.regs.dl_idx != 4'h0) ? EG_DEC : EG_SUS; end
```
and the pos/stepPtr reset in D3 (engine.sv:1283-1286):
```systemverilog
if (d2c_pkt.key_on_edge) begin dyn_upd.pos = 16'd0; dyn_upd.stepPtr = 16'd0; end
```

- env reset to MAX: ✔
- EG_ATT when rate<63: ✔ (`d1a_pkt.rate` = `calc_eg_rate(ar,rc,oct,fn)` taken on the
  edge, engine.sv:955-959 — same as `compute_rate(AR)`).
- **AR=15 instant path:** `calc_eg_rate` returns 63 when `val==15` (alu.sv:243),
  so `rate < 63` is false → `new_vol = MIN_ATT_INDEX (0)`, `new_state = dl_idx?EG_DEC:EG_SUS`.
  The FPGA jumps **straight past EG_ATT** to DEC/SUS with env_vol = MIN — exactly
  like keyOnHelper (567-575). It does **not** run an EG_ATT step. ✔
- The `(dl_idx != 0)` test matches openMSX `slot.DL ?` because `DL = dl_tab[idx]`
  and `dl_tab[0]=0`, all others ≠0 (`dl_tab_rom`, eg_step.sv:106-110). ✔

Edge source coverage matches both openMSX trigger sites:
- case-4 `if(!keyon)`: `key_retrig` set on `wr_field==4 && reg_data[7] && !cur_r.keyon`
  (engine.sv:1632-1635).
- case-0 wave-write while keyon: `key_retrig` set on `wr_field==0 && cur_r.keyon`
  (engine.sv:1634).

→ **EQUIVALENT.** The amplitude/state produced is identical; only the *frame* at
which it becomes audible is shifted (#4/#5).

### 2. Attack-shape formula — MATCH (bit-exact)

openMSX (YMF278.cc:369):
`env_vol = narrow<int16_t>(env_vol + ((~env_vol * eg_inc[...]) >> 4));` then clamp `<= 0`.

FPGA `calc_attack_step` (alu.sv:278-287):
```systemverilog
inv     = ~{1'b0, ev};                          // 11-bit one's complement
product = inv * $signed({1'b0, inc_val});       // signed × positive
result  = $signed({2'b0, ev}) + (product >>> 4);// arithmetic >> 4
if (result <= 12'sd0) return 10'd0;
return result[9:0];
```
Width/sign verification:
- `~env_vol` (openMSX, int32, env_vol∈[0,0x280]) = `-(env_vol+1)` ∈ [-0x281,-1].
- `~{1'b0,ev}` (11-bit) for ev≤0x280 = `-(ev+1)` as signed-11 (e.g. ev=0x280 →
  11'h57F = -641 = -(0x280+1)). **Same value.** ✔
- product: |inv|≤641, inc≤8 → |product|≤5128 fits signed-21. ✔
- `>>4` arithmetic on the negative product (both sides). ✔
- clamp `<= 0 → 0` == `<= MIN_ATT_INDEX`. ✔

→ **MATCH.** Attack curve is identical sample-for-sample given identical inputs.

### 3. Attack rate gating + ROM tables — MATCH (bit-exact)

- `eg_do_update(eg_cnt, shift)` (eg_step.sv:113-117) = `(eg_cnt & ((1<<sh)-1))==0`
  == openMSX `!(eg_cnt & ((1<<shift)-1))` (YMF278.cc:366). ✔
- `eg_phase` (eg_step.sv:119-121) = `(eg_cnt>>sh)&7` == `(eg_cnt>>shift)&7`. ✔
- `eg_rate_shift_rom` (eg_step.sv:87-104) reproduces the 12→0 table (alu.sv:130-147). ✔
- `eg_rate_select_rom` (eg_step.sv:57-85) — re-derived against `eg_rate_select`
  (alu.sv:108-125), values O(n)=8n: row0→112=O(14), rows1-12→{0,8,16,24}=O(0..3),
  row13→{32,40,48,56}=O(4..7), row14→{64,72,80,88}=O(8..11), row15→96=O(12). ✔
  (The prior FALSE-flag is confirmed false — table is bit-exact.)
- `eg_inc_rom` (eg_step.sv:21-55) matches the 15×8 `eg_inc` table. Attack uses
  the same indexing `sel + ((eg_cnt>>shift)&7)`. ✔
- `eg_cnt` is a single shared 24-bit counter incremented once per 44.1 kHz frame
  (engine.sv:177), like openMSX's single `eg_cnt++` in `advance()`. The do-update
  cadence is therefore identical across slots. ✔

→ **MATCH.**

### 4. First-sample formation — DISCREPANCY (low): 1-frame envelope lead

**pos/stepPtr at onset are correct** (first audible sample is at `pos=0`,
`stepPtr=0`; see timeline). The discrepancy is in **which envelope value
multiplies which sample**.

openMSX `generateChannels` (YMF278.cc:515-561) per sample j:
1. compute `sample` from `pos/stepPtr` **and apply env_vol** (the *pre-advance* value),
2. advance `stepPtr`/`pos`,
3. `advance()` (env step) at end of the loop body.

→ openMSX multiplies `sample[k]` by `env[k]` (the env *before* this frame's EG step).

FPGA: D2a applies `d1_pkt.next_eg_vol` (engine.sv:1152,1164) — the **already
EG-stepped** value — to the same frame's `interp` (decoded from the dispatch-time,
pre-advance pos). Trace for frame k:
- dispatch reads `env_vol = E_k` (engine.sv:325, `ram_dyn`);
- D1b computes `next_eg_vol = advance(E_k) = E_{k+1}` (engine.sv:1058);
- D2a multiplies `interp_k` by `vol_factor(E_{k+1})` (engine.sv:1152,1168);
- D3 writes back `ram_dyn.env_vol = E_{k+1}` (engine.sv:1282).

So the FPGA applies `E_{k+1}` where openMSX applies `E_k` — a **consistent
one-44.1 kHz-sample (~22.7 µs) envelope lead** across the whole envelope, including
the attack ramp. At onset, the attack amplitude rises one sample earlier than the
reference.

- **Exposing condition:** every note, every frame (systemic), most visible during
  a fast attack where one EG step is a large amplitude delta.
- **Audible effect on 초기음:** the attack envelope is advanced by ~23 µs.
  Inaudible in isolation; could in principle cause a sub-sample phase difference
  vs a reference capture but not a perceptible onset artifact.
- **Severity: LOW** (systemic but sub-perceptual; not onset-specific).
- Note: the *very first* sample after a non-instant key-on is **silent on both
  sides** — env starts at `MAX_ATT_INDEX (0x280)` and `vol_factor`/`calc_vol`
  return 0 at `>= 0x280` (YMF278.cc:485 vs engine.sv:1168 `gain_e = (env_idx>=0x280)?0:…`).
  So the lead does not un-silence a sample that openMSX keeps silent; it only
  shifts the *rising* portion by one frame.

### 5. Onset ordering (header → backfill AR/DL/RC → keyOnHelper) — EQUIVALENT

openMSX case-0 wave-write loads the 12-byte header, **backfills** regs 7..11
(LFO/AR/D1R/DL/D2R/RC/RR/AM) via the `writeRegDirect(...buf[i])` loop
(YMF278.cc:610-615), **then** calls `keyOnHelper` (616-617) — so the re-attack
uses the NEW wave's AR/DL/RC.

FPGA defers the re-trigger until the header fetch (HF FSM) has reloaded the regs:
- `edge_now = (… | key_retrig) & ~hf_pending` (engine.sv:944-946) — the edge cannot
  fire while `hf_pending` is set;
- `hf_pending` is set on field-0/1 wave write (engine.sv:1592,1600) and cleared
  only when the HF FSM picks the slot (engine.sv:1599);
- the HF backfill writes AR/D1R/DL/D2R/RC/RR/AM into `ram_regs` at `HF_STORE`
  (engine.sv:1447-1456) **before** `hf_pending` clears;
- `key_retrig` persists (its consume is also `!hf_pending`-gated, engine.sv:1614-1615).

When `edge_now` finally fires, `stage_c_reg.regs.ar/dl_idx/rc` are the NEW wave's
backfilled values, and `calc_eg_rate` (engine.sv:955-959) uses them. env/state/pos
are all set consistently in the same edge frame (D1b env+state, D3 pos/stepPtr).

→ **EQUIVALENT.** For a **pure field-4 key-on with no wave change**, `hf_pending`
stays 0, so there is no deferral and the edge fires the next frame normally.

### 6. Interaction of deferred re-trigger + EG_OFF read-skip + interp-clear + stale-gate — EQUIVALENT

Walked across two onset scenarios; both avoid any wrong-first-sample window:

- **EG_OFF read-skip does not starve the new note.** Stage B issues reads when
  `env_state != EG_OFF` **OR** `key_retrig[slot]` (engine.sv:558-559). Since a
  key-on always sets `key_retrig`, the new wave's bytes are fetched on the edge
  frame even though `env_state` is still EG_OFF at dispatch. ✔
- **No stale sample leaks.** During `key_retrig | hf_pending`, Stage-C `interp`
  is forced to `16'sd0` (engine.sv:767-770), `last_interp` is held at 0
  (engine.sv:793-794), and D3a output is gated to 0 (`vs_gated`, engine.sv:1244).
  So the edge frame emits **silence**, never the old wave's sample. ✔
- **pos is 0 before the first audible sample.** pos reset is written at D3 of the
  edge frame and read at the *next* dispatch, so the first non-gated sample uses
  `pos=0`. There is no frame where env is attacking AND a non-zero/old pos is read
  out as audio. ✔

Net cost: **one extra silent frame** at onset (the edge frame), see timeline.
This is sub-perceptual and partially mirrors openMSX's own silent first sample.

### 7. DAMP / DL=0 / env resolution / attack→decay handoff — MATCH

- DL=0 path: `new_state = (dl_idx!=0)?EG_DEC:EG_SUS` on both the instant-attack
  branch (engine.sv:1045) and the attack→handoff (engine.sv:1061-1062), matching
  `slot.DL ? EG_DEC : EG_SUS` (YMF278.cc:374,575). ✔
- env resolution 0..0x280: `env_vol`/`eg_vol` are 10-bit, clamp at `0x280`
  (engine.sv:1153), `MIN_ATT_INDEX=0`. ✔
- attack→decay handoff sample: at `env_vol <= MIN_ATT_INDEX` set env=0 and switch
  state (engine.sv:1059-1063) == YMF278.cc:370-374. ✔
- DAMP at onset: `calc_decay_rate` honours DAMP/PRVB (alu.sv:262-273) for the
  DEC/SUS/REL rates the same way as `compute_decay_rate`; DAMP does not alter the
  attack branch on either side. ✔

---

## Timeline of a key-on (plain field-4 key-on, slot was EG_OFF, no wave change)

Pipeline: dispatch(StageA) → StageB → StageC → D1a → D1b → D2a/b/c → D3a → D3.
Each slot is processed once per 1948-cycle frame (= one 44.1 kHz sample).

**Frame N — the key-on edge frame**
- CPU field-4 write landed: `ram_regs[slot].keyon=1`, `key_retrig[slot]=1`, `hf_pending=0`.
- dispatch: `ram_dyn` = {state=EG_OFF, env_vol=0x280, pos=old}.
- StageB: `key_retrig` set → reads ISSUED for the (new) wave. ✔
- StageC: `key_retrig` set → `interp = 0` (silenced).
- D1a: `edge_now = (keyon&~prev | key_retrig) & ~hf_pending = 1`; `rate = attack rate`.
- D1b: env restart → env_vol=MAX (or MIN if AR=15), state=EG_ATT (or DEC/SUS).
- D3: writeback `pos=0, stepPtr=0`, env_state/env_vol = restarted value;
  `retrig_consume` clears `key_retrig`.
- **Output this frame: SILENCE** (interp gated to 0).
  *(openMSX's first generated sample here is also ≈silent: env=0x280→vol_factor=0.)*

**Frame N+1 — first audible frame**
- dispatch: `ram_dyn` = {state=EG_ATT, env_vol=E1=advance(MAX), pos=0, stepPtr=0};
  `key_retrig=0`, `hf_pending=0`.
- StageB: state=EG_ATT → reads issued at **pos=0**. ✔
- StageC: not gated → `interp = getSample(pos=0)` interpolated with stepPtr=0.
- D1b: env steps E1→E2.
- D2a applies `vol_factor(E2)` to `interp(pos=0)`.
- **Output: first audible sample at pos=0**, multiplied by E2 (the 1-frame-lead env, #4).

**Frame N+2 …** normal attack ramp; pos advances by `step`.

**Wave-change re-key (field-0 while keyon, or field-4 with a fresh wave):** identical
except `hf_pending` is set, so the edge is **deferred** until HF reloads the header
+ AR/DL/RC (frames N..N+m all output silence via the stale-header gate). The edge
then fires with the NEW wave's envelope on the frame `hf_pending` clears. No stale
sample is ever emitted.

---

## Ranked list of confirmed onset discrepancies

1. **(LOW) Envelope-vs-sample 1-frame lead** — FPGA multiplies `sample[k]` by the
   *post-EG-step* env `E_{k+1}`; openMSX uses the *pre-step* env `E_k`
   (engine.sv:1152 vs YMF278.cc:524-560). Systemic ~23 µs envelope advance,
   sub-perceptual. *Not onset-specific — affects the whole envelope.*

2. **(INFO / latent trap, inactive)** — the dead `process_eg` task still has the old
   `key_on_edge && cur_state==EG_OFF` gate (eg_step.sv:161) that would suppress a
   re-key of a non-EG_OFF slot. **Not in the synthesized path** (D1a/D1b is used),
   so it has no audible effect — but it is a re-introduction hazard if anyone wires
   `process_eg` back in. Recommend deleting the dead task or fixing its gate to match.

3. **(INFO) One extra silent frame at onset** — the FPGA emits silence on the
   key-on edge frame itself (interp gated by `key_retrig`), with the first audible
   sample one frame later at pos=0. openMSX's edge-frame sample is also ≈silent
   (env=0x280), so the net perceptual delta is ≤1 sample. Not a defect.

---

## Conclusion

**Is the attack/onset logic correct? — Yes, functionally correct and bit-exact
where it matters.** The attack-shape math (`~env*inc>>4`), the rate-gating cadence,
the AR=15 instant-attack jump (straight to EG_DEC/EG_SUS at env=MIN, no spurious
EG_ATT step), the DL=0 routing, the pos=0/stepPtr=0 onset, and the use of the NEW
wave's AR/DL/RC on a deferred re-key all match openMSX. The only real divergence is
a sub-perceptual **one-sample envelope lead** (#4) that is systemic rather than
onset-specific. No high/critical onset discrepancy was found; the prior
`eg_rate_select` concern is re-confirmed as a false alarm.
