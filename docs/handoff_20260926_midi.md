# Handoff 2026-09-26 — MSX-MIDI, the OSD, and the gates that should have caught this week

Branch `nextz80`, worktree `.claude/worktrees/readcache`.  Predecessor:
`docs/handoff_20260923_turbor.md`.  Written in the reporting frame adopted today
(below): what is confirmed and by what, what is not known and the measurement that
would settle it, and what the user has to decide.

## 0. Read first

* **Board**: `MSX1_20260926b_midiosd.rbf` (md5 b100db6c…) deployed, **not yet run on
  hardware**.  The one before it, `20260926a_midifix`, was confirmed by the user: the
  GT boots again.  Never delete an RBF.
* **Nothing unbuilt except this document's own commit** (tools and docs only, no RTL).
* **Session name**: the user asked for this handoff to carry the name
  `stable_Turbo-R`.  The session that wrote it held that name; rename or close it.

## 1. What 26b should do on the board (the test, step by step)

It copies the flow the user captured from the X68000 core:
1. MSX1 main menu, above JoyMega Pad: **`MIDI: On`** (the GT's built-in MIDI needs
   none of this; it is declared by its pack).
2. F12 → System page: a **`UART MODE (NONE)`** row must now exist.  It did not on 26a.
3. UART MODE → **MIDI**.
4. `MIDILINK: LOCAL` → `FSYNTH`, `BAUD (31250)` shown.  (UDP etc. also offered.)
5. Run MIDI software on the MSX and listen.

Step 2 is the one that proves the declaration.  The synthesized CONF_STR already reads
`MSX1;UART31250,MIDI;FC1,…` in `output_files/MSX1.map.rpt` — that is the build
containing it, not yet the firmware accepting it.

## 2. Confirmed (and by what)

| what | commit | evidence |
|---|---|---|
| kanji ROM reads on the R800 | d031a4c | hardware: Japanese and Korean-patch fonts (23d) |
| PCM engine RMW muxes removed, −1,351 ALM | b59327d | golden 8/8 bit-exact under Verilator (checked against the unchanged engine first); hardware sound OK (24a) |
| save auto-load lost inside the stretched reset | 410d33f, 1ff7821 | benches fail on the old RTL; hardware ASCII16X + plain SRAM (24b) |
| MSX-MIDI device (8251 + 8254) | e6e7e1c … 3b13ef9 | `sim/run_midi.sh` 19 checks, negative controls for the cascade (T12) and the interrupt gating (T3/T4/T10) |
| **GT boot hang on 24c = `midi_int_n` never connected at the msx_slots instance** | 4590b37 | hardware (24c hung, 26a boots); Quartus `10030` named the net on every build before it (msx1-audit's logs); msx1-audit's fullsys B: INT_n low 100% from release |
| MIDI On/Off OSD, `status[24]` | 26e72e3 | `tools/check_pins.sh` no new pins; no `midi_io_en` row in the Quartus connectivity report |
| UART/MIDI declared in CONF_STR entry 1 | 087182c | firmware source: menu draws from entry 2, `uart_mode = UIO_GETUARTFLG \|\| uart_speeds[0]`; official NES core uses the same `UART31250,MIDI`; string present in the synthesized CONF_STR |

## 3. Not known — and what would settle it

* **26b on hardware** — the five steps in §1.
* **The MIDI On/Off enable path** (`msx_slots`: `cs`/`external` from `midi_io_en`) was
  never simulated end to end; the benches drive `dev_midi` directly.  Settled by the
  board (a non-GT machine with MIDI On, software that finds the device) or a fullsys run
  with `msxConfig.midi_io_en = 1`.
* **`tools/buildgate/quartus_warnings.py` inside `build.sh`** (runs right after map) has
  not been exercised by a real build.  The script alone passes five negative controls.
  The next build is its first real run.
* **msx1-audit A/B/C** (fullsys, re-run with a72ed9e applied and the VRAM stub fixed):
  B is the negative control on a correctly loaded machine; A gives the interval from
  command 03h to the first timer IRQ.  Their first run was invalid — see §5.

## 4. Decided, or waiting on the user

* **Next task agreed: μ·PACK in the Slot B list** (index 5; indices 0-4 keep their
  meaning so saved configs are safe; Slot A is 8/8 full).  Real product: expanded slot,
  sub-slot 1 = 256 KB mapper, sub-slot 2 = `mu-pack.rom` (16 KB at 4000h, in
  `tools/CreateMSXpack/ROM/extensions/`, sha1 e88ca790… matches openMSX), MIDI in the
  E2h-controlled (`external`) variant.  Choosing it takes the whole of Slot B.
* **Deferred by the user**: MIDI loopback; `uart_mode` gating of `UART_TXD` (the NES core
  does not gate either); USER-port output / MT32-pi audio return.
* **GT MSX-View is not supported** and needs three things: a pack declaring 3-3
  (`PANASONIC32`), a firmware-switch toggle (port 41h bit 7 is fixed OFF in
  `matsushita.sv`), and the Panasonic mapper's main-RAM banks ≥ 0x180 (unimplemented,
  read as unmapped; MSX-View uses 0x1A0-0x1DC per openMSX).  Pairs naturally with μ·PACK.

## 5. Other sessions' work that is not on origin yet

* **065ae7f (msx1-audit)**: PCM engine to real MLAB — whole design 76 % → 71 %.  Built on
  b59327d.  When it lands: the two `10999` entries (`ram_header_m`, `ram_dyn_m`) leave
  the Quartus baseline — re-bless it.  It makes **reset width load-bearing both ways**:
  its MLAB zero-sweep needs `rst_n` ≥ 24 clk (currently 260), while widening the reset
  is what swallowed the save pulse on 24b.
* **a72ed9e**: a MoonSound device record with no inline ROM, with no FW pack loaded,
  dropped every later record (CONFIG, MIDI, slots).  Every fullsys GT run without a FW
  pack is invalid until it lands: `MSX_typ = 0`, 12/64 slot entries, TMS9918 instead of
  V9958.  The hardware is not affected (the user loads a FW pack).
* **fullsys `stubs.sv`** lacks `bram.vhd`'s port defaults, so VRAM `cs`/`enable` read 0 in
  simulation (msx1-audit).  Fixed only in their worktrees.

## 6. Loose ends found, not done

* `emu|rst_hold[0]` clocks a latch in vdp18 (`hor_vert|cnt_vert_q[2]`, Quartus 332060).
* `MSX1.sdc` 75-80: multicycles on PCM v2 registers that no longer exist (silently
  ignored; timing passes without them).
* Comment errors: `rtl/msx.sv` at the msx_slots instance says `-Wno-UNDRIVEN` hid the
  missing pins — it was `-Wno-PINMISSING` (and the lint stopping early on MODMISSING);
  `tools/check_pins.sh` header says 25 deliberate pins, the baseline has 23.
* `tools/check_pins.sh` keys its baseline by (file, pin), so one line covers several
  instances.  `quartus_warnings.py` keys by full hierarchy path and does not have this
  hole; decide whether to rekey or retire check_pins.

## 7. Build times this session

| RBF | map | fit | asm | wall | benches | ALM | slow setup |
|---|---|---|---|---|---|---|---|
| 20260923d_kanjifix | 310 s | 1053 s | 24 s | 24m38s | 91 s | 32,893 | 0.591 |
| 20260924a_pcmslim | 288 s | 959 s | 24 s | 24m16s | 186 s | 31,658 | 0.410 |
| 20260924b_saveload | 292 s | 986 s | 25 s | 22m13s | 30 s | 31,724 | 0.187 |
| 20260924c_midi | 239 s | 911 s | 23 s | 19m50s | 17 s | 31,956 | 0.469 |
| 20260926a_midifix | 301 s | 1016 s | 24 s | 24m57s | 156 s | 31,946 | 0.174 |
| 20260926b_midiosd | 297 s | 1005 s | 27 s | 22m57s | 49 s | 31,945 | 0.379 |

Fit is ~70 % of a build and did not shrink when ALM did (6 builds — an observation, not
a law).  The worst setup path is always ascal (HDMI scaler), seed-sensitive, unrelated.

## 8. How to work here (adopted today, in memory)

The user retired the brevity rule and asked for msx1-audit's discipline instead
(`feedback_msx1_audit_reasoning_discipline.md`, `feedback_terse_workflow.md`):
report *confirmed + evidence / unknown + the measurement that settles it / user
decisions*; write "conclusion" only with discriminating evidence, a harness proven to
have run, and a stated scope; declare what would invalidate a measurement **before**
looking at it; comments, names and your own tools' output are claims; read the tool's
warnings; a lesson counts only once it is a check that fails.  This week's three misses
were all Quartus warnings nobody read, and a truncated `grep | head` read.
