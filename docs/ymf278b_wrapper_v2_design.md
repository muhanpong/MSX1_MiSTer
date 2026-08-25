# YMF278B Wrapper v2 — from-scratch redesign (openMSX-faithful)

Status: DESIGN (2026-06-14). Replaces the accumulated-patch wrapper
(`ymf278b_regs.sv` + the `msx.sv` ch4 bridge + WAIT_n handshake) with a clean
implementation faithful to openMSX `src/sound/YMF278B.cc`.

The PCM **engine** (`ymf278_pcm_engine2.sv`, v3 from-scratch) is already proven
bit-exact to openMSX `YMF278.cc` and is NOT touched here except for one signal
(reg-6 read completion). This redesign targets only the **wrapper**: I/O port
decode, BUSY/LD timing, reg 0x02–0x06 memory access, NEW2 gate, status.

---

## 1. Why redo it

The openMSX-vs-RTL comparison (2 subagents) found the engine + memory layout
match openMSX exactly, but the **wrapper diverges** in ways the real chip never
does, and the divergent code is un-rewritten accumulated patches:

| Divergence | openMSX (real chip) | current RTL | file |
|---|---|---|---|
| reg 3–6 BUSY | 28–38 master cyc, **Z80-invisible, no CPU stall** | `MEM_WRITE_DELAY=1024` + **WAIT_n deferral** | regs.sv:72,217 |
| reg-6 read | always **fresh** `readMem(memAdr)` | `pcm_reg_rd_done=1` ⇒ **stale prefetch** possible | top.sv:246 |
| reg-6 r/w gate | gated on `regs[2]&1`, else 0xFF / no-increment | **ungated**, always r/w + increment | engine:1062 |
| reg 3 readback | masked `&0x3F`, reg 3–5 readable | no reg 3–5 readback (0x00) | top.sv:245 |

The original reason for the `MEM_WRITE_DELAY=1024` + WAIT_n throttle
(regs.sv:66-71): lowering it to 64 let dense ch4 write bursts corrupt **ch2
(CPU)** SDRAM reads → vgmplay crashed. **But that predates the ch2-absolute-
priority SDRAM fix** (sdram.sv, CH4_HOLD retired, ch2 served first). With ch2
now uninterruptible, ch4 write density can no longer starve the CPU — so the
throttle's reason is gone, and we can match openMSX's fast, non-stalling write.

---

## 2. openMSX spec (the exact behaviour to reproduce)

`YMF278B.cc`. Timing in 33.8688 MHz master cycles. Our wrapper clock is
`clk_sdram` = 85.909 MHz, so **scale ×2.536** (= 85.909/33.8688).

```
FM_REG_SELECT/WRITE = 56   → 142 clk
WAVE_REG_SELECT/WRITE = 88  → 223 clk
MEM_READ_DELAY  = 38        → 96  clk
MEM_WRITE_DELAY = 28        → 71  clk     (was 1024 — 14× too long)
LOAD_DELAY      = 10000     → 25360 clk   (~300 µs; the LD bit)
```

### writeIO, WAVE part (port 0x7E sel / 0x7F data) — gated on NEW2
- sel (0x7E): `busyTime = now + WAVE_REG_SELECT_DELAY; opl4latch = value`
- data (0x7F):
  - if `0x08 ≤ latch ≤ 0x1F`: `loadTime = now + LOAD_DELAY`  (tone/header load → LD bit)
  - if `0x03 ≤ latch ≤ 0x06`: `busyTime = now + MEM_WRITE_DELAY`  (short, invisible)
  - else: `busyTime = now + WAVE_REG_WRITE_DELAY`
  - `latch==0xF8 → FM mix; latch==0xF9 → PCM mix`
  - **`ymf278.writeReg(latch, value)` immediately — no stall, no deferral**
- NEW2=0 → writes ignored (both sel and data).

### readIO, WAVE part (port 0x7F) — NOT gated on NEW2
- 0x7E: return 0xFF (latch not readable)
- 0x7F: if `3 ≤ latch ≤ 6`: `busyTime = now + MEM_READ_DELAY`; **return fresh `readReg(latch)`** (reg 6 ⇒ readMem + auto-increment).

### FM part (0xC4–0xC7)
- 0xC4/0xC6 read: `ymf262.readStatus() | YMF278status`
- 0xC4/0xC6 write: bank0/1 select, `busyTime = now + FM_REG_SELECT_DELAY`
- 0xC5/0xC7 write: FM reg write, `busyTime = now + FM_REG_WRITE_DELAY`
- 0xC5/0xC7 read: FM reg read

### Status byte (YMF278status)
`bit0 BUSY = (now < busyTime); bit1 LD = (now < loadTime)`  — OR'd with OPL3 status.

### Memory access (YMF278.cc, the reg 2–6 semantics the wrapper must drive)
- reg 0x02: `mem mode (bit0)`, `mem type (bit1)`, `wavetblhdr (bits4:2)` — engine already handles.
- reg 0x03/0x04/0x05: `memAdr = (r3<<16)|(r4<<8)|r5`. r3 masked `&0x3F` on **readback**. Setting addr does NOT auto-increment.
- reg 0x06 write: if `reg2&1`: `writeMem(memAdr, v); memAdr++`. else: ignored, **no increment**.
- reg 0x06 read: if `reg2&1`: `v = readMem(memAdr); memAdr++; return v`. else: return 0xFF, **no increment**.

---

## 3. Architecture decisions

**A. Keep the engine/​wrapper split.** The engine owns the SDRAM ch4 port and
its arbitration (slot fetches + header fetch + CPU-mem op in the service
window). Moving memory access into the wrapper would force it to re-arbitrate
SDRAM with the engine — messy. So: wrapper does IO/decode/BUSY/LD; engine keeps
`cpu_mem_adr` + the `SV_CPU_RD/WR` SDRAM ops. The wrapper drives them correctly.

**B. Clock = clk_sdram**, same as today. Scale the openMSX delays ×2.536.

**C. Writes never stall (match openMSX).** FM, wave-register, AND wave-memory
(reg 6) writes ack within the CDC round-trip. Remove `pcm_wr_wait` /
`MEM_WRITE_DELAY=1024` deferral. BUSY/LD are pure down-counters that decay; they
only affect the *status byte*, never WAIT_n. Rely on ch2-absolute-priority so
ch4 write bursts can't corrupt the CPU. (Risk + mitigation in §5.)

**D. reg-6 READ returns fresh data.** This is the one place WAIT_n is genuinely
needed: hold the CPU until the engine's SDRAM read for `memAdr` completes, then
return it. Replace the hardwired `pcm_reg_rd_done=1` with a real
"engine read done" pulse. Reads are rare (FixUp: 128 bytes, spaced by `cp(ix)`),
so the brief wait is free. This kills the stale-prefetch bug.

**E. reg-6 gated on reg2[0].** Engine: only write/read + increment `cpu_mem_adr`
when `reg02_mem_access_mode==1`; reg-6 read with mode 0 returns 0xFF, no
increment. (Small engine change.)

**F. reg 3 readback masked `&0x3F`; expose reg 3/4/5 readback** (low priority;
vgmplay doesn't read them, but it's free correctness).

**G. Drop the LOAD throttle coupling.** `load_cnt` (LD bit) stays as a pure
status down-counter (LOAD_DELAY scaled). It must NOT gate writes or WAIT_n
(today it doesn't gate, only flags — keep that).

---

## 4. New module interface (`ymf278b_wrap.sv`)

Same external interface as `ymf278b_regs.sv` (drop-in), minus the throttle
plumbing, plus a real read-done input:

```
// unchanged: clk, rst_n, io_port/data/wr/rd/out/ack, new2,
//            opl3_reg_* , pcm_reg_addr/data/wr/rd/dout, status_live, status_rd_notify
input  wire        pcm_mem_rd_done;   // NEW: engine pulses when reg-6 SDRAM read landed (replaces pcm_reg_rd_done=1)
input  wire        pcm_cpu_mem_busy;  // engine: reg-6 op in flight (kept)
// REMOVED: the MEM_WRITE_DELAY deferral path / pcm_wr_wait
output logic       busy, load_busy;   // status bits only
```

Internal state: `opl4latch`, `opl3latch[8:0]`, `busy_cnt`, `load_cnt`,
`new2_prev`, `new2_signature_pending`. No `pcm_rd_wait`/`pcm_wr_wait`,
no `wait_guard`, no `busy_cnt`-as-throttle.

`io_ack` policy:
- FM write / wave-reg write / reg-6 write: ack next cycle (fast).
- reg-6 read: ack when `pcm_mem_rd_done` (fresh) — the only multi-cycle path.
- status / FM-reg / reg-2 read: ack immediately (direct).

---

## 5. Risks & mitigations

1. **Removing the reg-6 write throttle re-exposes ch4-corrupts-ch2?**
   Mitigation: ch2 now has absolute SDRAM priority (sdram.sv) — structurally
   ch4 cannot delay a ch2 read past its deadline. VERIFY in sim with the
   integration TB (drive a dense reg-6 upload while ch2 reads) and on HW
   (the very crash that motivated the throttle: vgmplay "exception" while
   streaming from its ch2 mapper buffer). If it recurs, add a **small write
   FIFO** (accept byte fast, drain to SDRAM) instead of the WAIT_n throttle —
   that preserves openMSX-fast ack without starving ch2.
2. **reg-6 read WAIT_n + engine service-window latency during playback.**
   During playback the CPU-mem op is serviced ≤1 frame (22.7 µs). vgmplay
   doesn't read reg-6 during playback, so acceptable. FixUp runs before
   playback (slots idle → immediate service).
3. **BUSY now Z80-invisible (short).** Any RTL/diag that polled BUSY for
   sequencing must not rely on the old 12 µs window. (Diag is observational.)

---

## 6. Build / test plan

1. Implement `ymf278b_wrap.sv`; wire into `ymf278b_top.sv` (replace `ymf278b_regs`).
2. Engine: drive a real `pcm_mem_rd_done`; gate reg-6 r/w + increment on
   `reg02_mem_access_mode`.
3. Re-run integration TB (`tb_integration_io`) — must keep ≥0.99 corr vs ref278
   (register path stays clean) AND now a reg-6 read test returns fresh bytes.
4. Add an integration-TB scenario: dense reg-6 upload concurrent with ch2-style
   reads → assert no corruption (the §5.1 risk).
5. Diag ON build (MOONSOUND_DIAG=1, re-enabled): deploy, watch freeze detectors
   + ch4-latency probe during ST04O. Confirm no regressions (MBwave, OPL3,
   single-voice TRI16 still perfect).
6. A/B the actual failing song.

---

## 7. Open question this does NOT resolve

Measurements show the *current* wrapper already delivers correct register values
during playback (integration-TB 0.995 corr; HW overlay healthy; single-voice
perfect). So this redesign is **correctness/faithfulness cleanup** — it removes
real divergences from openMSX but is not *proven* to fix the ST04O symptom. The
parallel track (capture the actual HW register stream vgmplay emits, or A/B
upstream-vs-sharksym players) is still needed to nail whether vgmplay emits a
different stream on FPGA. Best done together: a faithful wrapper makes the chip
behave exactly as vgmplay expects, removing it as a variable.
