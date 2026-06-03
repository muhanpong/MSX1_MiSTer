# openMSX MoonSound (Yamaha YMF278B / OPL4) — Sound Generation Mechanism

Implementation-grade reference, derived strictly from openMSX C++ source. Every
non-trivial claim cites `file:LINE`. Base dir: `/home/muhanpong/Documents/github/openMSX/`.

Files analyzed:
- `src/sound/YMF278.cc` (PCM wavetable engine — primary focus)
- `src/sound/YMF278.hh` (PCM slot state / member widths)
- `src/sound/YMF278B.cc` / `.hh` (OPL4 wrapper: YMF262 FM + YMF278 PCM, port routing, latches, status/IRQ, busy/load timing)
- `src/sound/MSXMoonSound.cc` / `.hh` (cartridge: I/O ports, RAM sizing, memory-pointer setup)
- `src/sound/YMF262.cc` / `.hh` (OPL3 FM core — documented structurally only)

Throughout, "slot" = one of the 24 PCM voices. References to the FM part are
structural; the PCM part is documented exhaustively.

---

## 0. Conventions and global constants

Source: `YMF278.cc:49-66`.

```
MAX_ATT_INDEX = 0x280   // = 640. envelope full attenuation; "-60dB" silence point
MIN_ATT_INDEX = 0       // 0 = max volume
TL_SHIFT      = 2       // envelope values are 4x as fine as TL levels
LFO_SHIFT     = 18
LFO_PERIOD    = 1 << 18 = 0x40000
```

Envelope generator phase constants (`YMF278.cc:58-66`):
```
EG_ATT = 4   EG_DEC = 3   EG_SUS = 2   EG_REL = 1   EG_OFF = 0
EG_REV = 5   EG_DMP = 6   // ONLY appear in old savestates; converted to EG_REL on load
```
Note: EG_REV/EG_DMP are NOT live states. Pseudo-reverb and damping are handled
inside the decay-rate computation while the slot remains in EG_DEC/EG_SUS/EG_REL
(see Unit 7). The live state machine has exactly 5 states.

`env_vol` is `int16_t` (`YMF278.hh:79`); it ranges 0..0x280. `TL`/`TLdest` are
`uint8_t` 0..0xFF (`YMF278.hh:88-89`). `pos` is `uint16_t` (`YMF278.hh:77`),
`stepPtr`/`step` are `uint32_t` 16.16 fixed point (`YMF278.hh:74-76`).

---

## Functional Unit 1 — Architecture & top-level dataflow

**Purpose:** combine the OPL3 FM core (YMF262) and the PCM wavetable engine
(YMF278) into one OPL4 chip, exposed to the MSX as the MoonSound cartridge.

- The OPL4 = YMF262 (FM, "almost 100% OPL3 compatible") + YMF278 (PCM/wave).
  `YMF278.cc:26-30`, `YMF278B.hh:13`. The `YMF278` class models ONLY the wave
  part; the status register and NEW2-bit interaction live in `YMF278B`
  (`YMF278.cc:26-30`).
- Composition: `YMF278B` owns `YMF262 ymf262` and `YMF278 ymf278`
  (`YMF278B.hh:37-38`). `MSXMoonSound` owns one `YMF278B`
  (`MSXMoonSound.hh:25`).
- Both FM and PCM are independent `ResampledSoundDevice`s and are mixed by the
  openMSX sound mixer, not by summing inside the chip. FM registers as
  `"OPL4 FM"` and PCM as `"OPL4 wave-part"` with 24 channels
  (`YMF278.cc:797-798`). Each device produces its own stereo stream; the mixer
  combines them.

**Clocking / sample rate:**
- PCM internal rate `INPUT_RATE = 44100` Hz (`YMF278.cc:793`), passed to the
  `ResampledSoundDevice` base (`YMF278.cc:797-798`). The base class resamples
  44100 Hz to the host rate.
- Master clock is 33.8688 MHz (`YMF278B.cc:10-11`) but this is used ONLY for
  register/memory/busy timing, NOT for audio sample stepping.
- FM master clock relationship: OPL4 timer1 ≈ 80.8us, timer2 ≈ 323.1us
  (`YMF262.hh:199-200`).

**Per-sample driving (PCM):** the mixer calls
`YMF278::generateChannels(bufs, num)` (`YMF278.cc:506`). It loops `num` output
samples (`for j in xrange(num)`, `YMF278.cc:515`); inside each sample it loops
all 24 slots (`for i in xrange(24)`, `YMF278.cc:516`) producing one stereo
sample per active slot, then calls `advance()` exactly once per output sample
(`YMF278.cc:560`). So `advance()` (EG + LFO + TL interpolation) ticks at 44100 Hz.

**Output buffers:** `bufs[i]` is the per-channel stereo buffer for slot `i`;
interleaved as `bufs[i][2*j+0]` (left) and `bufs[i][2*j+1]` (right)
(`YMF278.cc:547-548`). Each of the 24 PCM channels has its own buffer (24
channels registered, `YMF278.cc:798`).

---

## Functional Unit 2 — I/O port decode (MSX cartridge level)

**Purpose:** decode MSX I/O ports to FM-vs-WAVE and select/data.

Ports (extension config `share/extensions/moonsound.xml:14-15`):
```
io base 0x7E num 2   -> 0x7E, 0x7F  (WAVE part)
io base 0xC4 num 4   -> 0xC4..0xC7  (FM part)
```

Decode in `YMF278B::writeIO` / `readIO` (`YMF278B.cc:69-199`). The discriminator
is `(port & 0xFF) < 0xC0` → WAVE part, else FM part (`YMF278B.cc:71,96,113,140`).

WAVE part (`port & 0x01`):
- write port 0 (0x7E): select register — `opl4latch = value`
  (`YMF278B.cc:144-147`). Sets busy until `time + WAVE_REG_SELECT_DELAY`.
- write port 1 (0x7F): write register — `ymf278.writeReg(opl4latch, value, time)`
  (`YMF278B.cc:169`).
- read port 0 (0x7E): "read latch, not supported" → returns 255
  (`YMF278B.cc:74-75`, `readIO`).
- read port 1 (0x7F): `ymf278.readReg(opl4latch)` (`YMF278B.cc:92`).

FM part (`port & 0x03`):
- write 0 (0xC4): select bank-0 reg, `opl3latch = value` (`YMF278B.cc:182-183`).
- write 2 (0xC6): select bank-1 reg, `opl3latch = value | 0x100`
  (`YMF278B.cc:186-187`).
- write 1/3 (0xC5/0xC7): `ymf262.writeReg(opl3latch, value, time)`
  (`YMF278B.cc:190-193`).
- read 0/2 (0xC4/0xC6): status = `ymf262.readStatus() | readYMF278Status(time)`
  (`YMF278B.cc:99-101`).
- read 1/3 (0xC5/0xC7): `ymf262.readReg(opl3latch)` (`YMF278B.cc:103-104`).

**NEW2 gating (critical):** all WAVE writes (BOTH register select and data) are
ignored when NEW2 = 0 (`YMF278B.cc:142,174-178`). `getNew2()` reads OPL3 reg
0x105 bit 1: `(ymf262.peekReg(0x105) & 0x02) != 0` (`YMF278B.cc:201-204`). WAVE
*reads* happen normally even when NEW2 = 0, and a read still advances the
internal memory pointer (`YMF278B.cc:76-92`).

**Special FM-side writes 0xF8/0xF9 (mix levels) on the WAVE port:** when
`opl4latch == 0xf8` write FM mix level `ymf262.setMixLevel(value, time)`; when
`opl4latch == 0xf9` write PCM mix level `ymf278.setMixLevel(value, time)`
(`YMF278B.cc:164-168`). The value is *also* passed to `ymf278.writeReg`
(`YMF278B.cc:169`), but inside YMF278 regs 0xF8/0xF9 are no-ops besides being
stored (`YMF278.cc:750-752,756`).

---

## Functional Unit 3 — PCM register map & writeRegDirect

**Purpose:** decode the 0x00..0xFF PCM register space; per-slot register
fan-out; header-load side effects; CPU memory port.

Entry: `writeReg` calls `updateStream(time)` then `writeRegDirect`
(`YMF278.cc:581-585`). `writeRegDirect` (`YMF278.cc:587-757`) stores `regs[reg] =
data` at the end unconditionally (`YMF278.cc:756`).

### 3.1 Slot register block: reg 0x08 .. 0xF7

`if (reg >= 0x08 && reg <= 0xF7)` (`YMF278.cc:590`):
```
sNum  = (reg - 8) % 24;     // which of the 24 slots
field = (reg - 8) / 24;     // which per-slot field (0..9)
```
(`YMF278.cc:591-593`). So each per-slot "field" occupies 24 consecutive
registers, one per slot. There are 10 fields → registers 0x08..0x08+24*10-1 =
0x08..0x157, but the slot block is bounded to 0xF7, i.e. fields 0..9 occupy
0x08..0xF7 (0x08 + 24*10 = 0xF8). The field map:

| field | reg base | meaning |
|-------|----------|---------|
| 0 | 0x08..0x1F | wave number low 8 bits → triggers header load |
| 1 | 0x20..0x37 | wave# bit8, FN low |
| 2 | 0x38..0x4F | FN high, PRVB, OCT |
| 3 | 0x50..0x67 | TL + interpolation-disable (load) bit |
| 4 | 0x68..0x7F | pan / DO1 / LFO-reset / DAMP / key-on |
| 5 | 0x80..0x97 | LFO speed, vibrato depth |
| 6 | 0x98..0xAF | AR, D1R |
| 7 | 0xB0..0xC7 | DL, D2R |
| 8 | 0xC8..0xDF | RC, RR |
| 9 | 0xE0..0xF7 | AM |

**Field 0 — wave number (`YMF278.cc:594-623`):**
```
slot.wave = (slot.wave & 0x100) | data;          // keep bit8, set bits7..0
waveTblHdr = (regs[2] >> 2) & 0x7;                // header base selector
base = (slot.wave < 384 || !waveTblHdr)
     ? (slot.wave * 12)
     : (waveTblHdr * 0x80000 + (slot.wave - 384) * 12);
```
Reads 12 header bytes `buf[0..11]` via `readMem(base+i)` (`YMF278.cc:600-605`),
then:
```
slot.bits      = (buf[0] & 0xC0) >> 6;                          // sample format 0/1/2/3
slot.startAddr = buf[2] | (buf[1] << 8) | ((buf[0] & 0x3F) << 16); // 22-bit start
slot.loopAddr  = buf[4] | (buf[3] << 8);                        // 16-bit
slot.endAddr   = buf[6] | (buf[5] << 8);                        // 16-bit, stored as 2s-complement value
```
(`YMF278.cc:606-609`). Then bytes 7..11 are **written back into the slot's own
registers** via recursive `writeRegDirect`:
```
for i in [7..11]:
    writeRegDirect(8 + sNum + (i-2)*24, buf[i], time);
```
(`YMF278.cc:610-615`). Mapping: i=7→field5 (LFO/VIB), i=8→field6 (AR/D1R),
i=9→field7 (DL/D2R), i=10→field8 (RC/RR), i=11→field9 (AM). HW-verified comment:
"After tone loading, if you read these registers, their value actually has
changed." (`YMF278.cc:611-613`). So loading a wave auto-fills the ADSR/LFO/AM
slot params from the wave header. (Note: it does NOT auto-fill TL, pan, FN, OCT,
PRVB — only the 5 timbre registers 7..11.)

After header load: if `slot.keyon` → `keyOnHelper(slot)`; else reset playback
position `stepPtr = 0; pos = 0` (`YMF278.cc:616-621`).

**Field 1 — wave bit8 + FN low (`YMF278.cc:624-628`):**
```
slot.wave = (slot.wave & 0xFF) | ((data & 0x1) << 8);
slot.FN   = (slot.FN & 0x380) | (data >> 1);   // FN bits 0..6 from data bits 1..7
slot.step = calcStep(slot.OCT, slot.FN);
```

**Field 2 — FN high + PRVB + OCT (`YMF278.cc:630-635`):**
```
slot.FN   = (slot.FN & 0x07F) | ((data & 0x07) << 7);  // FN bits 7..9
slot.PRVB = (data & 0x08) != 0;
slot.OCT  = sign_extend_4((data & 0xF0) >> 4);          // signed -8..+7
slot.step = calcStep(slot.OCT, slot.FN);
```

**Field 3 — TL + load bit (`YMF278.cc:637-646`):**
```
t = data >> 1;                       // 7-bit TL register value
slot.TLdest = (t != 0x7f) ? t : 0xff; // HW-verified: register 0x7F maps to internal level 0xFF
if (data & 1) slot.TL = slot.TLdest;  // bit0=1: load directly
// else: interpolate (handled in advance(), see Unit 8)
```
HW note: the TL register is 7 bits (0..0x7F) but the internal TL level is 8 bits
(0..0xFF); the top register value 0x7F is remapped to 0xFF
(`YMF278.cc:638-639`, also `YMF278.cc:8`, `YMF278.cc:527`).

**Field 4 — pan / DO1 / LFO-reset / DAMP / key-on (`YMF278.cc:648-680`):**
```
if (data & 0x10) slot.pan = 8;        // DO1 pin output -> emulated as full mute (pan=8 both -inf dB)
else             slot.pan = data & 0x0F;

if (data & 0x20) { slot.lfo_active = false; slot.lfo_cnt = 0; } // LFO reset
else             { slot.lfo_active = true; }                    // LFO run

slot.DAMP = (data & 0x40) != 0;

if (data & 0x80) {                     // key-on
    if (!slot.keyon) { slot.keyon = true; keyOnHelper(slot); }
} else {                               // key-off
    if (slot.keyon) { slot.keyon = false; slot.state = EG_REL; }
}
```
Key-on/key-off are edge-triggered (only act when `keyon` actually changes). DO1
pin (bit4) is "not used in MoonSound; we emulate this by muting the sound" by
forcing `pan=8` (`YMF278.cc:648-653`).

**Field 5 — LFO speed + vibrato (`YMF278.cc:681-684`):**
```
slot.lfo = (data >> 3) & 0x7;   // LFO speed 0..7
slot.vib = data & 0x7;          // vibrato depth 0..7
```

**Field 6 — AR + D1R (`YMF278.cc:685-688`):**
```
slot.AR  = data >> 4;     // attack rate 0..15
slot.D1R = data & 0xF;    // decay-1 rate 0..15
```

**Field 7 — DL + D2R (`YMF278.cc:689-692`):**
```
slot.DL  = dl_tab[data >> 4];  // decay level (via table, Unit 7)
slot.D2R = data & 0xF;         // decay-2 rate 0..15
```

**Field 8 — RC + RR (`YMF278.cc:693-696`):**
```
slot.RC = data >> 4;   // rate correction 0..15
slot.RR = data & 0xF;  // release rate 0..15
```

**Field 9 — AM (`YMF278.cc:697-699`):**
```
slot.AM = data & 0x7;  // AM (tremolo) depth 0..7
```

### 3.2 Non-slot registers (`YMF278.cc:701-754`)

- `0x00`, `0x01` (TEST): ignored (`YMF278.cc:704-706`).
- `0x02` wavetable-header / memory-type / memory-access-mode: `regs[2] = data`
  then `setupMemoryPointers()` (`YMF278.cc:708-714`). Bit layout used elsewhere:
  bit0 = CPU memory access mode (Unit 9), bit1 = memory mapping mode (mode0 when
  0), bits2..4 = wavetable header base selector. On read, top 3 bits are the
  device ID (Unit 9).
- `0x03` memory address high: masked `data &= 0x3F` then stored
  (`YMF278.cc:716-727`). HW-verified: does NOT update `memAdr`; upper 2 bits
  always read back as 0.
- `0x04` memory address mid: stored only, does NOT update `memAdr`
  (`YMF278.cc:729-731`).
- `0x05` memory address low: COMMITS the full address —
  `memAdr = (regs[3] << 16) | (regs[4] << 8) | data` (`YMF278.cc:733-737`).
- `0x06` memory data port (Unit 9): write to wave memory if `regs[2] & 1`
  else ignored (`YMF278.cc:739-748`).
- `0xF8`, `0xF9` (mix levels): no-op here; handled in `YMF278B`/`MSXMoonSound`
  level (`YMF278.cc:750-752`). For PCM, reg 0xF9 → `setMixLevel` (Unit 8.5).

### 3.3 Register read (`YMF278.cc:759-791`)

`readReg` = `peekReg` + side-effect: if `reg==6` and `regs[2]&1`, increment
`memAdr` (`YMF278.cc:759-772`). `peekReg`:
```
reg 2: return (regs[2] & 0x1F) | 0x20;   // top 3 bits = device ID = 0x20 (001b)
reg 6: regs[2]&1 ? readMem(memAdr) : 0xFF;
else : regs[reg];
```
(`YMF278.cc:774-791`).

---

## Functional Unit 4 — Wave memory, mapping & headers

**Purpose:** physical sample memory model and the 12-byte wave header.

### 4.1 Address space and chip-select mapping

- 4 MB address space, wraps at 4 MB: `address &= 0x3FFFFF`
  (`YMF278.cc:874-875`). HW-verified wrap.
- `readMem`: split into 32 chunks of 128 kB; `memPtrs[address >> 17]` selects
  the chunk; `(*chunk)[address & 0x1FFFF]`. Unmapped → returns `0xFF`
  (`YMF278.cc:872-880`).
- `writeMem`: same chunk selection; only writes if the target points into the
  RAM block; writes to ROM/unmapped are ignored (`YMF278.cc:882-894`).

Memory map modes (R#2 bit1) — `setupMemoryPointers` calls `setupMemPtrs(mode0,
rom, ram, memPtrs)` with `mode0 = (regs[2] & 2) == 0` (`YMF278.cc:866-870`). The
full /MCS0../MCS9 mode0/mode1 table is documented at `YMF278.cc:850-865`.

MoonSound-specific layout (`MSXMoonSound.cc:30-88`):
- First 2 MB (chunks 0..15) = ROM (yrw801), in BOTH modes (`MSXMoonSound.cc:64-67`).
- mode0: chunks 16..31 = RAM, as much as available up to 2 MB
  (`MSXMoonSound.cc:74-78`).
- mode1: chunks 16..27 unmapped, chunks 28..31 = first 4 RAM blocks
  (`MSXMoonSound.cc:80-87`). "mode1 normally shouldn't be used on MoonSound."
- RAM sizes allowed: 0/128/256/512/640/1024/2048 kB (`MSXMoonSound.cc:11-28`).
  Default extension config: 640 kB (`moonsound.xml:23`).
- ROM must be exactly 2 MB (0x200000) or construction throws
  (`YMF278.cc:806-810`).

### 4.2 12-byte wave header format

Header base addressing (`YMF278.cc:596-599`):
- wave# < 384 OR header-base selector `waveTblHdr == 0`: `base = wave * 12`
  (headers packed from address 0).
- wave# >= 384 AND `waveTblHdr != 0`:
  `base = waveTblHdr * 0x80000 + (wave - 384) * 12`. The selector (R#2 bits 2..4,
  1..7) scales by 0x80000 (512 kB) (`YMF278.cc:597-599`).

Header byte layout (`YMF278.cc:606-609`):
```
byte 0 bits 7..6 = format/bits (0=8bit, 1=12bit, 2=16bit, 3=unspecified)
byte 0 bits 5..0 = startAddr[21:16]
byte 1           = startAddr[15:8]
byte 2           = startAddr[7:0]            // 22-bit start address
byte 3..4        = loopAddr (big-endian: byte3 high, byte4 low), 16-bit
byte 5..6        = endAddr  (big-endian: byte5 high, byte6 low), 16-bit, 2s-complement
byte 7           -> slot field 5 (LFO/VIB)
byte 8           -> slot field 6 (AR/D1R)
byte 9           -> slot field 7 (DL/D2R)
byte 10          -> slot field 8 (RC/RR)
byte 11          -> slot field 9 (AM)
```
`endAddr` semantics: stored as the raw 16-bit value from the header and treated
as the negated end offset in the loop math (`YMF278.hh:73` comment: "stored in 2s
complement (0x0000 = 0, 0x0001 = -65536, 0xffff = -1)"). See Unit 5.3.

`loopAddr`/`endAddr` are 16-bit and `pos` is 16-bit; sample addressing in
`getSample()` adds `startAddr` (22-bit) to a 16-bit-derived offset, so a single
wave can span up to 64 K samples before wrapping at the loop point.

---

## Functional Unit 5 — Per-slot PCM playback datapath

**Purpose:** for each active slot per output sample: fetch + decode sample,
linear-interpolate, advance position by pitch step, handle loop wrap.

### 5.1 Sample decode `getSample(slot, pos)` (`YMF278.cc:427-461`)

`pos` is a 16-bit sample index relative to `startAddr`. Output is `int16_t`.

Format `slot.bits`:
- **0 = 8-bit:** `readMem(startAddr + pos) << 8`. The 8-bit unsigned byte is
  shifted into the high byte → treated as a signed 16-bit value (the ROM stores
  signed 8-bit; the `<<8` then `narrow_cast<int16_t>` sign-handling makes it a
  signed 16-bit sample) (`YMF278.cc:433-436`).
- **1 = 12-bit:** packed 2 samples per 3 bytes.
  `addr = startAddr + (pos/2)*3` (`YMF278.cc:439`).
  ```
  if (pos & 1):  (readMem(addr+2) << 8) | (readMem(addr+1) & 0xF0)
  else:          (readMem(addr+0) << 8) | ((readMem(addr+1) << 4) & 0xF0)
  ```
  (`YMF278.cc:440-448`). Even samples use byte0 (high 8) + low nibble of byte1
  (in bits 7..4); odd samples use byte2 (high 8) + high nibble of byte1. The low
  4 bits are always 0 (12-bit precision in a 16-bit container).
- **2 = 16-bit:** `addr = startAddr + pos*2`;
  `(readMem(addr+0) << 8) | readMem(addr+1)` (big-endian) (`YMF278.cc:450-455`).
- **3 = unspecified:** returns 0 (`YMF278.cc:457-459`).

Open TODO (`YMF278.cc:429`): behavior when R#2 bit0=1 (CPU mem-access mode)
during sample read is unspecified — possibly reads as 0xFF like CPU reads, or
sound generation is blocked higher up. **Flagged ambiguity.**

### 5.2 Pitch step `calcStep(oct, fn, vib)` (`YMF278.cc:215-220`)

```
if (oct == -8) return 0;                       // octave -8 freezes the sample
t = (fn + 1024 + vib) << (8 + oct);            // oct in [-7..+7]
return t >> 3;
```
- `oct == -8` → step 0 (sample frozen) — HW-verified (`YMF278.cc:15,217`).
- `fn | 1024` is implemented as `fn + 1024` ("use '+' iso '|' generates slightly
  better code" — equivalent because fn < 1024) plus the signed `vib` offset.
- Result is a 16.16 fixed-point increment per output sample. The `<< (8+oct)`
  then `>> 3` net-shift is `(8+oct) - 3 = 5+oct`; the comment notes the formula
  is "((fn|1024)+vib) << (5 + oct)" but computed as `<<(8+oct)` then `>>3` to
  keep intermediate precision (`YMF278.cc:209-220`).
- `oct` is signed (`int8_t`), so the shift distance `8+oct` ranges 1..15 for
  oct -7..+7. (At oct=-8 the early-return prevents an invalid shift.)

`step` is cached in the slot and recomputed whenever OCT or FN change
(`YMF278.cc:627,634`); invariant `step == calcStep(OCT, FN)` (`YMF278.hh:75`).

### 5.3 Position advance `nextPos(slot, pos, increment)` (`YMF278.cc:463-472`)

```
pos += increment;                                       // uint16_t wrap
if ((uint32_t(pos) + slot.endAddr) >= 0x10000)          // reached/passed (negated) end
    pos += slot.endAddr + slot.loopAddr;                // loop back (uint16_t)
return pos;
```
Because `endAddr` is the 2s-complement (negated) end offset, the test
`pos + endAddr >= 0x10000` detects when `pos` has reached the end. On wrap,
`pos += endAddr + loopAddr` jumps back to the loop point. Comment: "This is how
the actual chip does it." (`YMF278.cc:470`). The "loop glitch": advancing by more
than the loop length (e.g. 12 samples per step over a 4-sample loop) can overrun
the end — abused by "Lizard Star" to generate noise (`YMF278.cc:11,463-467`).
This out-of-bounds behavior must be reproduced exactly.

### 5.4 Interpolation + advance in `generateChannels` (`YMF278.cc:524-558`)

Per active slot per output sample:
```
sample = ( getSample(sl, sl.pos)                 * (0x10000 - sl.stepPtr)
         + getSample(sl, nextPos(sl, sl.pos, 1)) *  sl.stepPtr ) >> 16;
```
(`YMF278.cc:524-526`). Linear interpolation between `pos` and `pos+1` using the
16-bit fractional `stepPtr` as the weight; result narrowed to `int16_t`.

Pitch step selection (vibrato applied here, `YMF278.cc:550-552`):
```
step = (sl.lfo_active && sl.vib) ? calcStep(sl.OCT, sl.FN, sl.compute_vib())
                                 : sl.step;
sl.stepPtr += step;
if (sl.stepPtr >= 0x10000) {
    sl.pos = nextPos(sl, sl.pos, sl.stepPtr >> 16);
    sl.stepPtr &= 0xffff;
}
```
(`YMF278.cc:550-558`). The integer part of `stepPtr` advances `pos` (possibly by
>1 sample); the fractional part is retained. Vibrato is recomputed every sample
when active.

---

## Functional Unit 6 — Envelope Generator (ADSR + reverb/damp)

**Purpose:** generate per-slot attenuation `env_vol` (0=loud .. 0x280=silent)
via a 5-state machine, ticked once per output sample in `advance()`.

### 6.1 State machine (`advance()`, `YMF278.cc:355-423`)

States: EG_ATT → EG_DEC → EG_SUS → (EG_OFF); EG_REL on key-off; EG_OFF idle.

Common stepping pattern (DEC/SUS/REL identical form):
```
rate  = compute_rate or compute_decay_rate(<phase rate reg>);
shift = eg_rate_shift[rate];
if (!(eg_cnt & ((1 << shift) - 1))) {            // gate by counter
    select = eg_rate_select[rate];
    env_vol += eg_inc[select + ((eg_cnt >> shift) & 7)];
    ... phase transition checks ...
}
```

**EG_ATT (attack, `YMF278.cc:357-378`):**
```
rate = compute_rate(AR);
if (rate >= 63) break;          // AR=15 attack freezes if set mid-attack (HW-verified)
shift = eg_rate_shift[rate];
if (!(eg_cnt & ((1<<shift)-1))) {
    select = eg_rate_select[rate];
    env_vol += (~env_vol * eg_inc[select + ((eg_cnt>>shift)&7)]) >> 4;  // attack shape
    if (env_vol <= MIN_ATT_INDEX) {
        env_vol = MIN_ATT_INDEX;
        state = DL ? EG_DEC : EG_SUS;
    }
}
```
Attack uses the multiplicative shape `env_vol += (~env_vol * inc) >> 4`. The
`>>4` "makes the attack phase's shape match the actual chip -Valley Bell"
(`YMF278.cc:368`). `~env_vol` (bitwise NOT) drives an exponential-approach curve.
A mid-attack AR=15 (rate>=63) freezes the envelope (`break`), matching YM2612
behavior (`YMF278.cc:359-363`).

**EG_DEC (decay-1, `YMF278.cc:379-389`):**
```
rate = compute_decay_rate(D1R);
... env_vol += eg_inc[...];
if (env_vol >= DL) state = (env_vol < MAX_ATT_INDEX) ? EG_SUS : EG_OFF;
```

**EG_SUS (decay-2/sustain, `YMF278.cc:391-403`):**
```
rate = compute_decay_rate(D2R);
... env_vol += eg_inc[...];
if (env_vol >= MAX_ATT_INDEX) { env_vol = MAX_ATT_INDEX; state = EG_OFF; }
```

**EG_REL (release, `YMF278.cc:404-416`):**
```
rate = compute_decay_rate(RR);
... env_vol += eg_inc[...];
if (env_vol >= MAX_ATT_INDEX) { env_vol = MAX_ATT_INDEX; state = EG_OFF; }
```

**EG_OFF:** nothing (`YMF278.cc:417-419`).

Note that all of DEC/SUS/REL go through `compute_decay_rate`, which folds in
DAMP and pseudo-reverb (Unit 7). EG_DEC can skip straight to EG_OFF if DL itself
is at/over MAX (`YMF278.cc:386`). **Open TODO:** whether EG_DEC is active for 1
sample when DL=0 at attack completion (`YMF278.cc:372-374`). **Flagged.**

### 6.2 Key-on `keyOnHelper(slot)` (`YMF278.cc:564-579`)

```
slot.env_vol = MAX_ATT_INDEX;                 // reset to silent (unlike FM!)
if (compute_rate(AR) < 63) state = EG_ATT;
else { env_vol = MIN_ATT_INDEX; state = DL ? EG_DEC : EG_SUS; } // AR=15 instant attack
slot.stepPtr = 0;
slot.pos = 0;
```
Key-on resets the envelope to MAX_ATT (silent) then attacks — "it makes sense
because you restart the sample" (`YMF278.cc:566`). AR=15 → instant attack
(env_vol jumps to 0, skips to DEC or SUS) (`YMF278.cc:570-576`). Playback
position is reset to the start (`stepPtr=0, pos=0`). Called on key-on edge
(field 4 bit7) and on wave-load if keyon was already set (Unit 3.1).

### 6.3 `eg_cnt` global counter

`unsigned eg_cnt` incremented once at the top of `advance()` (`YMF278.cc:333`),
i.e. once per output sample (44100 Hz). Used both as the EG rate gate and the TL
interpolation timebase.

---

## Functional Unit 7 — Rate computation (RC, DAMP, pseudo-reverb)

**Purpose:** convert 4-bit rate registers to the 6-bit internal rate (0..63) used
to index `eg_rate_shift`/`eg_rate_select`, with octave/FN rate-correction, plus
the DAMP and pseudo-reverb overrides.

### 7.1 `compute_rate(val)` (`YMF278.cc:246-260`)

```
if (val == 0)  return 0;
if (val == 15) return 63;
res = val * 4;
if (RC != 15) {
    res += 2 * clamp(OCT + RC, 0, 15);   // HW-verified clamping
    res += (FN & 0x200) ? 1 : 0;         // FN bit9 adds 1
}
return clamp(res, 0, 63);
```
Rate correction = `2 * clamp(OCT + RC, 0, 15) + (FN_bit9)`; disabled when RC=15.
`OCT` is signed so OCT+RC clamps at 0 at the low end. The intermediate clamp of
`OCT+RC` to [0,15] is explicitly HW-verified (`YMF278.cc:255-256`).

### 7.2 `compute_decay_rate(val)` (`YMF278.cc:262-298`) — DAMP + PRVB

Applied for DEC/SUS/REL phases (NOT attack).

**DAMP (highest priority, `YMF278.cc:263-282`):**
```
if (DAMP) {
    if (env_vol < dl_tab[4]) return 48;   //   0dB .. -12dB
    else                     return 63;   // -12dB .. -96dB
}
```
DAMP ignores rate correction. The two-segment behavior (rate 48 then 63) is
calibrated to the manual's damping timings (`YMF278.cc:265-281`). `dl_tab[4]` =
SC(12) (see table below).

**Pseudo-reverb (PRVB, `YMF278.cc:283-296`):**
```
if (PRVB) {
    if (env_vol >= dl_tab[6]) return 20;  // activated at -18dB; overrides D1R/D2R/RR
}
```
PRVB sets internal rate to 4*5 = 20 once attenuation reaches -18dB
(`dl_tab[6]` = SC(18)), ignoring rate correction (HW-verified, `YMF278.cc:283-295`).

Else: `return compute_rate(val)` (`YMF278.cc:297`).

---

## Functional Unit 8 — Volume, TL interpolation, panning, mixing

### 8.1 Envelope+AM combine (`YMF278.cc:533-535`)

```
envVol = min(sl.env_vol + ((sl.lfo_active && sl.AM) ? sl.compute_am() : 0),
             MAX_ATT_INDEX);   // uint16_t
```
AM (tremolo) is added to env_vol as additional attenuation, clamped to MAX.

### 8.2 `vol_factor(x, envVol)` (`YMF278.cc:483-489`)

```
if (envVol >= MAX_ATT_INDEX) return 0;          // -60dB+ -> silence
vol_mul   = 0x80 - (envVol & 0x3F);             // 0x40 mantissa steps per 6dB
vol_shift = 7 + (envVol >> 6);                  // 6dB per shift
return (x * ((0x8000 * vol_mul) >> vol_shift)) >> 15;
```
Logarithmic attenuation: each 6dB (0x40 in env units) is a power-of-two shift;
the low 6 bits are a linear mantissa multiplier. Below -60dB → 0 (hard clip).
Each `envVol` step = -3/32 dB = -0.09375 dB (`YMF278.cc:479-480`).

### 8.3 Two-stage volume (env and TL applied SEPARATELY) (`YMF278.cc:536`)

```
smplOut = vol_factor( vol_factor(sample, envVol), sl.TL << TL_SHIFT );
```
The envelope attenuation and the TL attenuation are applied as **two independent
`vol_factor` calls**, each independently clipped to silence at -60dB
(`YMF278.cc:527-536`). `TL << TL_SHIFT` = `TL << 2` scales the 8-bit TL level
into the same 0..0x3FF resolution as env (`TL_SHIFT=2`). HW-verified separate
application (`YMF278.cc:16,531-532`).

### 8.4 TL interpolation/ramp in `advance()` (`YMF278.cc:335-349`)

```
tl_int_cnt  = eg_cnt % 9;        // 0..8
tl_int_step = (eg_cnt / 9) % 3;  // 0..2
...
if (tl_int_cnt == 0) {
    if (tl_int_step == 0) { if (TL < TLdest) ++TL; }   // -volume: +1 step every 27 samples
    else                  { if (TL > TLdest) --TL; }   // +volume: -1 step every 13.5 samples
}
```
TL ramps toward TLdest: volume DECREASE (TL increasing) at one step per 27
samples; volume INCREASE (TL decreasing) at one step per 13.5 samples (two of the
three `tl_int_step` slots decrement) (`YMF278.cc:341-348`). Direct loads
(field-3 bit0) set TL=TLdest immediately, bypassing the ramp (Unit 3.1).

### 8.5 Panning (`YMF278.cc:541-548`)

Pan tables (`YMF278.cc:69-74`), units -3dB (= 8):
```
pan_left  = {0, 8, 16, 24, 32, 40, 48, 255, 255,   0,  0,  0,  0,  0,  0, 0}
pan_right = {0, 0,  0,  0,  0,  0,  0,   0, 255, 255, 48, 40, 32, 24, 16, 8}
```
Per slot:
```
volLeft  = pan_left [sl.pan];
volRight = pan_right[sl.pan];
volLeft  = (0x20 - (volLeft  & 0x0f)) >> (volLeft  >> 4);   // 0->0x20, 8->0x18, 16->0x10, 24->0x0C...
volRight = (0x20 - (volRight & 0x0f)) >> (volRight >> 4);
bufs[i][2*j+0] += (smplOut * volLeft ) >> 5;               // left
bufs[i][2*j+1] += (smplOut * volRight) >> 5;               // right
```
(`YMF278.cc:541-548`). Pan value 255 (`pan` 7→right-mute-left, 8→both-mute,
9→left-mute-right) produces `(0x20-15)>>15 = 0` (full mute) — pan=8 mutes both
(used for DO1, Unit 3.1). The `>>5` is the final per-slot output normalization.
Each slot accumulates (`+=`) into its own channel buffer. Note pan is applied
AFTER the two `vol_factor` stages, so it's a third independent attenuation
("low-volume TL + low-volume panning goes below -60dB", `YMF278.cc:538-540`).

### 8.6 PCM mix level (reg 0xF9) `setMixLevel(x, time)` (`YMF278.cc:491-504`)

```
level = {1.00, 0.75, 0.50, 0.375, 0.25, 0.1875, 0.125, 0.0}  // 0,-3,-6,-9,-12,-15,-18,-inf dB
setSoftwareVolume(level[x & 7], level[(x >> 3) & 7], time);   // L = bits0..2, R = bits3..5
```
This sets the software stereo volume of the WHOLE PCM device (not per-slot). -3dB
approximated as 0.75. The same table form is used by FM reg 0xF8
(`YMF262.cc:1502-1517`).

### 8.7 anyActive / muting (`YMF278.cc:474-477,506-513`)

`generateChannels` returns all-null buffers if no slot is active
(`anyActive()` = any slot `state != EG_OFF`). TODO: internal state not updated
while fully muted (`YMF278.cc:509`). Individual EG_OFF slots are skipped in the
per-sample loop (`YMF278.cc:518-522`).

---

## Functional Unit 9 — CPU wave-memory access

**Purpose:** let the host CPU read/write the external sample memory through
registers 0x02..0x06.

- **Access mode:** R#2 bit0 (`regs[2] & 1`). When 1, memory read/write through
  reg 6 is enabled (`YMF278.cc:740,765,781`).
- **Address registers:** 24-bit `memAdr`. Writes to reg 3 (masked `&0x3F`) and
  reg 4 only store into `regs[]`; they do NOT update `memAdr`
  (`YMF278.cc:716-731`). Only a write to reg 5 commits the full address:
  `memAdr = (regs[3]<<16) | (regs[4]<<8) | data` (`YMF278.cc:733-737`).
  HW-verified (`YMF278.cc:717-737`).
- **Data port reg 6 write:** if `regs[2]&1`, `writeMem(memAdr, data); ++memAdr;`
  else writes ignored and `memAdr` NOT incremented (`YMF278.cc:739-748`).
- **Data port reg 6 read:** `peekReg(6)` returns `readMem(memAdr)` if `regs[2]&1`
  else `0xFF` (`YMF278.cc:780-786`); `readReg(6)` additionally increments
  `memAdr` when `regs[2]&1` (`YMF278.cc:763-770`).
- **Auto-increment:** present on both read and write of reg 6, gated by
  `regs[2]&1`; never masked after the initial commit (`YMF278.cc:742,768`).
- **Device ID:** `peekReg(2)` returns `(regs[2] & 0x1F) | 0x20` — the top 3 bits
  read back as device ID `001b` (`YMF278.cc:777-778`).
- **"Channels stop during mem access":** openMSX does NOT explicitly halt PCM
  channels during CPU memory access. The interaction is flagged as an open TODO
  in `getSample()` and in the header-load read: "How does this behave when R#2
  bit 0 = 1?" (`YMF278.cc:429-431,602-603`). **Flagged ambiguity:** the
  documented real-HW behavior (channels stop during memory access) is NOT
  modeled here.

---

## Functional Unit 10 — LFO (vibrato + tremolo)

**Purpose:** generate per-slot pitch modulation (vibrato) and amplitude
modulation (tremolo) from a free-running LFO counter.

### 10.1 LFO counter (`advance()`, `YMF278.cc:351-353`)

```
if (op.lfo_active)
    op.lfo_cnt = (op.lfo_cnt + lfo_period[op.lfo]) & (LFO_PERIOD - 1);
```
`lfo_cnt` is `uint32_t`, masked to LFO_PERIOD = 0x40000 (`YMF278.hh:81`). Stepped
once per output sample. Reset (`lfo_active=false, lfo_cnt=0`) by field-4 bit5
(Unit 3.1).

`lfo_period` table (`YMF278.cc:150-162`), `L(a) = round(LFO_PERIOD * a / 44100)`:
```
index: 0   1    2    3    4    5    6    7
Hz:   0.168 2.019 3.196 4.206 5.215 5.888 6.224 7.066
step:   1    12   19   25   31   35   37   42      (counter steps per sample)
period(samples): 262144 21845 13797 10486 8456 7490 7085 6242
```

### 10.2 Vibrato `compute_vib()` (`YMF278.cc:300-315`)

```
lfo_fm = lfo_cnt / (LFO_PERIOD / 0x40);          // 0..0x3F triangle index
if (lfo_fm & 0x10) lfo_fm ^= 0x1F;               // fold to triangle
if (lfo_fm & 0x20) lfo_fm = -(lfo_fm & 0x0F);    // negative half
return (lfo_fm * vib_depth[vib]) / 12;
```
Produces a triangle in F-num units: `+0x00..+0x0F, +0x0F..+0x00, -0x00..-0x0F,
-0x0F..-0x00`. At LFO speed 0 each vibrato step takes 4096 samples → 64 steps
(HW-verified `YMF278.cc:300-308`). The result `vib` offset feeds `calcStep` (Unit
5.2/5.4). `vib_depth` (`YMF278.cc:165-176`):
```
vib_depth = {0, 2, 3, 4, 6, 12, 24, 48}   // F-num offsets; cents: 0,3.378,5.065,6.75,10.114,20.17,40.106,79.307
```
Formula: `vib_depth_cents(x) = (log2(0x400 + x) - 10) * 1200` (`YMF278.cc:166`).

### 10.3 Tremolo `compute_am()` (`YMF278.cc:317-328`)

```
lfo_am = lfo_cnt / (LFO_PERIOD / 0x100);   // 0..0xFF triangle index
if (lfo_am >= 0x80) lfo_am ^= 0xFF;        // fold: 0x00..0x7F, 0x7F..0x00
return (lfo_am * am_depth[AM]) >> 7;
```
Produces 0..0x7F triangle. At LFO speed 0 each tremolo step takes 1024 samples →
256 steps (HW-verified `YMF278.cc:317-323`). The result is ADDED to env_vol as
attenuation (Unit 8.1). `am_depth` (`YMF278.cc:178-194`):
```
am_depth = {0x00, 0x14, 0x20, 0x28, 0x30, 0x40, 0x50, 0x80}
           // dB: 0, 1.781, 2.906, 3.656, 4.406, 5.906, 7.406, 11.910
```
Formula: `am_depth_db(x) = (x-1)/0x40 * 6.0`; max attenuation with x=0x80 is
`(0x7F * 0x80) >> 7 = 0x7F` (`YMF278.cc:179-194`).

**Vibrato/tremolo gating:** vibrato applies only when `lfo_active && vib`
(`YMF278.cc:550`); tremolo only when `lfo_active && AM` (`YMF278.cc:534`).

---

## Functional Unit 11 — Exact lookup tables

### 11.1 `dl_tab` (decay level, 3dB/step) (`YMF278.cc:76-82`)

`SC(dB) = int16_t(dB / 3 * 0x20)` (note integer `dB/3` then `*0x20`):
```
index: 0    1    2    3    4    5     6     7     8     9    10   11   12   13   14    15
dB:    0    3    6    9   12   15    18    21    24    27   30   33   36   39   42    93
value: 0  0x20 0x40 0x60 0x80 0xA0 0xC0  0xE0 0x100 0x120 0x140 0x160 0x180 0x1A0 0x1C0 0x620
```
(Last entry SC(93) = 93/3*0x20 = 31*0x20 = 0x3E0... wait: 93/3=31, 31*0x20=0x3E0.
Stored as `int16_t`: 0x3E0 = 992. NOTE: this exceeds MAX_ATT_INDEX 0x280, used as
"effectively never reach DL" for entry 15.) `DL` is stored as this `int16_t`
(`YMF278.cc:690`, `YMF278.hh:83`).

### 11.2 `eg_inc` (8 cycles × 15 rows) (`YMF278.cc:84-105`)

```
row  cycle: 0 1  2 3  4 5  6 7   (description)
 0:        0 1  0 1  0 1  0 1    rates 00..12 step 0
 1:        0 1  0 1  1 1  0 1    rates 00..12 step 1
 2:        0 1  1 1  0 1  1 1    rates 00..12 step 2
 3:        0 1  1 1  1 1  1 1    rates 00..12 step 3
 4:        1 1  1 1  1 1  1 1    rate 13 step 0
 5:        1 1  1 2  1 1  1 2    rate 13 step 1
 6:        1 2  1 2  1 2  1 2    rate 13 step 2
 7:        1 2  2 2  1 2  2 2    rate 13 step 3
 8:        2 2  2 2  2 2  2 2    rate 14 step 0
 9:        2 2  2 4  2 2  2 4    rate 14 step 1
10:        2 4  2 4  2 4  2 4    rate 14 step 2
11:        2 4  4 4  2 4  4 4    rate 14 step 3
12:        4 4  4 4  4 4  4 4    rate 15 (decay)
13:        8 8  8 8  8 8  8 8    rate 15 (attack, zero time)
14:        0 0  0 0  0 0  0 0    infinity (no change)
```
Indexed `eg_inc[select + ((eg_cnt >> shift) & 7)]` where `select` is a row base
(see 11.3). RATE_STEPS = 8 (`YMF278.cc:84`).

### 11.3 `eg_rate_select` (64 entries, `O(a)=a*8`) (`YMF278.cc:107-125`)

```
rate  0..3 : O(14) O(14) O(14) O(14)        (inf rate row 14)
rate  4..47: repeating O(0) O(1) O(2) O(3)  (rows 0..3, 11 groups of 4)
rate 48..51: O(4) O(5) O(6) O(7)            (rows 4..7, rate 13)
rate 52..55: O(8) O(9) O(10) O(11)          (rows 8..11, rate 14)
rate 56..63: O(12) O(12) O(12) O(12) ...    (row 12, rate 15)
```
Exact: indices 0-3 = O(14); 4-47 = cycling O(0),O(1),O(2),O(3); 48-51 =
O(4..7); 52-55 = O(8..11); 56-63 = O(12) (eight entries). Values are the row base
into `eg_inc` (row × 8).

### 11.4 `eg_rate_shift` (64 entries) (`YMF278.cc:127-147`)

```
rate:  0-3   4-7  8-11 12-15 16-19 20-23 24-27 28-31 32-35 36-39 40-43 44-47 48-63
shift:  12   11   10    9     8     7     6     5     4     3     2     1     0
```
(Each value repeated 4×; rates 48..63 all shift 0.) Gate mask = `(1<<shift)-1`;
the EG only steps when `(eg_cnt & mask) == 0`. Companion comment table
(`YMF278.cc:127-129`):
```
rate  0  1  2  3  4  5  6  7  8 9 10 11 12 13 14 15 (register-rate, x4 in table)
shift 12 11 10 9  8  7  6  5  4 3  2  1  0  0  0  0
mask  4095 2047 1023 511 255 127 63 31 15 7 3 1 0 0 0 0
```

### 11.5 LFO / vibrato / tremolo / pan tables

Already given in Units 10 and 8 (`lfo_period` `YMF278.cc:153-162`, `vib_depth`
`YMF278.cc:167-176`, `am_depth` `YMF278.cc:185-194`, `pan_left`/`pan_right`
`YMF278.cc:69-74`).

---

## Functional Unit 12 — Status, IRQ, busy/load timing (YMF278B)

**Purpose:** combined OPL4 status byte, playback/load detection, busy flags.

- Combined status read = `ymf262.readStatus() | readYMF278Status(time)`
  (`YMF278B.cc:99-101`).
- `readYMF278Status(time)` (`YMF278B.cc:206-212`):
  ```
  bit0 (0x01) = BUSY  : time < ymf278BusyTime
  bit1 (0x02) = LOAD  : time < ymf278LoadTime
  ```
- **Busy timing:** set on every WAVE register select/write
  (`WAVE_REG_SELECT_DELAY`/`WAVE_REG_WRITE_DELAY` = 88 master cycles), except
  regs 3-6 use the shorter `MEM_WRITE_DELAY` = 28 (`YMF278B.cc:145,152-163`,
  constants `YMF278B.cc:22-32`). FM select/write = 56 cycles
  (`YMF278B.cc:14-16,184-192`). Memory read busy = `MEM_READ_DELAY` = 38
  (`YMF278B.cc:30,90`).
- **Load timing:** writing any WAVE register in 0x08..0x1F sets
  `ymf278LoadTime = time + LOAD_DELAY` (10000 master cycles ≈ 300us)
  (`YMF278B.cc:39,149-151`). This models the instrument-load busy used by
  software to detect when a wave-header load completes.
- These BUSY/LOAD times are master-clock (33.8688 MHz) based, independent of the
  44100 Hz audio path.

---

## Functional Unit 13 — FM core (YMF262 / OPL3) — STRUCTURAL ONLY

Documented at a structural level per the task scope. The PCM engine above is the
verification target; the FM part is "almost 100% OPL3-compatible"
(`YMF278.cc:27`).

- 18 two-operator channels, each `Channel` has 2 `Slot`s (`YMF262.hh:126-152`,
  `chanOut[18]`, `YMF262.hh:204`). 36 operators total.
- 4-op mode: channel pairs (0,3)(1,4)(2,5)(9,12)(10,13)(11,14) combine into six
  4-op channels via the `extended` flag (`YMF262.hh:141-151`, set from reg 0x104
  `YMF262.cc:1090-1095`). 2-op vs 4-op handled in `generateChannels` via
  `chan_calc` / `chan_calc_ext` (`YMF262.cc:1553-1567`).
- Rhythm mode: channels 6,7,8 become 5 rhythm instruments when `rhythm & 0x20`
  (reg 0xBD); `chan_calc_rhythm` (`YMF262.cc:830-867,1158-1160,1570-1577`).
- Per-operator EG: ATTACK/DECAY/SUSTAIN/RELEASE/OFF (`YMF262.hh:54-56`); phase
  generator `Cnt`/`Incr` 16.16 fixed point (`YMF262.hh:83-84`); sine wavetables
  SIN_LEN=1024 (`YMF262.hh:28-30,94`).
- LFO: AM (tremolo) + PM (vibrato) counters (`YMF262.hh:215-220`,
  `YMF262.cc:1540-1546`).
- Output: each channel's `chanOut[i]` is masked by 4 `pan[]` entries
  (L/R/CL/CR; only L/R used) and accumulated into the stereo buffer
  (`YMF262.cc:1584-1589`). Amplification factor 1/4096 (`YMF262.cc:1519-1522`).
- **Status / IRQ / timers** (`YMF262.cc:498-537`):
  - Two EmuTimers (timer1 ≈ 80.8us, timer2 ≈ 323.1us on OPL4)
    (`YMF262.hh:199-200`); started/stopped via reg 0x04 bits ST1/ST2
    (`YMF262.cc:1075-1076`).
  - `setStatus(flag)`: `status |= flag`; if `status & statusMask` then set bit7
    and assert IRQ (`YMF262.cc:504-512`).
  - `resetStatus(flag)`: clear flag; if no masked bits remain, clear bit7 and
    deassert IRQ (`YMF262.cc:515-523`).
  - reg 0x04 bit7 (IRQ_RESET) resets status 0x60 (`YMF262.cc:1072`).
  - Status bits: T1 = 0x40, T2 = 0x20 (`YMF262.hh:189-197`).
- **FM register readback** is allowed even when NEW2=0
  (`YMF278B.cc:17-19,103-104`).
- **NEW2 bit** lives in OPL3 reg 0x105 bit1 and gates the entire WAVE part
  (Unit 2). It is the only OPL3 feature whose behavior depends on `isYMF278`
  (`YMF262.hh:230-232`).
- **Mix level reg 0xF8** → `ymf262.setMixLevel` using the same 8-entry dB table
  as PCM (`YMF262.cc:1502-1517`, `YMF278B.cc:164-165`); reset value 0x1B = -9dB
  L/R (`YMF262.cc:1431`, `YMF278.cc:842`).

---

## Reset behavior (cross-cutting)

`YMF278::reset` (`YMF278.cc:829-848`): `eg_cnt=0`; all slots `reset()`; rewrite
regs 0xF7..0x00 to 0 in reverse order; `regs[0xf8]=0x1b`, `regs[0xf9]=0x00`;
`memAdr=0`; `setMixLevel(0)`; `setupMemoryPointers()`. `Slot::reset`
(`YMF278.cc:222-244`) zeroes all fields, sets `env_vol=MAX_ATT_INDEX`,
`state=EG_OFF`, `step=calcStep(0,0)`, `lfo_active=false`.

`YMF278B::reset` (`YMF278B.cc:57-67`): resets both ymf262 and ymf278, clears
both latches, resets busy/load times.

---

## Flagged source ambiguities / open questions

1. **`getSample()` during CPU mem-access mode (R#2 bit0=1):** unspecified —
   maybe reads return 0xFF, maybe sound is blocked higher up (`YMF278.cc:429`).
   The header-load read has the same open question (`YMF278.cc:602-603`).
2. **"Channels stop during memory access":** NOT modeled in openMSX; the real-HW
   behavior is only noted as a TODO (Unit 9). An FPGA may need to add this; openMSX
   does not.
3. **EG_DEC for 1 sample when DL=0:** unclear whether real HW skips EG_DEC
   entirely or runs it for one sample at attack completion (`YMF278.cc:372-374`).
   openMSX transitions ATT→(DL?DEC:SUS) directly.
4. **Octave -8 with non-zero fnum:** only tested with fnum=0; other fnum values
   "might behave differently" (`YMF278.cc:23-24`). openMSX freezes (step=0)
   regardless of fnum.
5. **`bits == 3` (format 3):** unspecified; openMSX returns sample 0
   (`YMF278.cc:457-459`).
6. **TL ramp "13.5 samples":** the increase path fires on 2 of 3 `tl_int_step`
   phases, averaging one step per 13.5 samples (`YMF278.cc:345-348`) — note this
   is an average, not a uniform period, so the exact sub-sample timing differs
   from the decrease path (uniform 27 samples).
7. **`dl_tab[15] = SC(93) = 0x3E0`** exceeds MAX_ATT_INDEX (0x280): intentional
   so DL=15 is effectively "never reached as a sustain target" — the slot decays
   to EG_OFF instead (verify the comparison `env_vol >= DL` in EG_DEC handles
   this, `YMF278.cc:385-386`).
