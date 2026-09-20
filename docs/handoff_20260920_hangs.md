# Handoff 20260920 (evening) — the turbo R hangs, and the instrument built to read them

Branch `nextz80` in `.claude/worktrees/readcache`, ahead of origin and **not pushed**.
Predecessor: `handoff_20260920_turbor.md` (morning: CPU Auto, VDP spacing, SD pacing,
printer 90h).  This one covers the hang hunt that followed, the pack defects it
exposed, and the JTAG event recorder that made any of it readable.

The machine packs are the **peer session's** work (`msx1-mister-sonydos2-55`, branch
`sony-dos2-3-3`, pushed).  Everything under `rtl/` and `tools/` here is this session's.

## 0. RBFs deployed today (all on the board, md5 verified by deploy.sh)

| RBF | md5 | Adds |
|---|---|---|
| `20260920d_cpuauto` | b7e29a63cb4e | CPU Auto, `I` popup, forensics follow the live core |
| `20260920e_asospr` | ad97578ba234 | ASO overscan sprites, `I` token moved to the tail, overlay CDC false path |
| `20260920f_icprobe` | 29086d3a32c8 | 0038h write PC + DI-honoured counters on panel rows 7/10 |
| `20260920g_rstsync` | f22409d54e2d | `reset` through two flops into clk21m + 63-cycle stretch |
| `20260920h_evtrace` | 0f0896106611 | **JTAG event recorder** (rtl/evt_trace.sv) |
| `20260920i_uplfix` | 43fc88d75bb5 | memory_upload restart race fixed |
| `20260920j_brtrace` | d246fd2b3c05 | branch tracing, FDC/mapper ports, read-port latch fix |
| `20260920k_stormtrig` | d2d0dc9a2bbd | trigger on 8 RST 38 in a row |
| `20260920l_a7fix` | 9d75effe9e43 | A7h decoded with the features off |
| `20260920n_midi` | dae6123ef33d | **MSX-MIDI status stub** (dev_midi) |
| `20260920o_blockfix` | 0b508b333255 | block-instruction exclusion by opcode byte, **does not work**, see §4 |
| `20260920p_blkaddr` | 9b9587489183 | same by ADDRESS — works for LDIR, then froze on the RAM search |
| `20260920q_loopfold` | (see §2) | loops folded to one word, wedge trigger by TIME |

## 1. Fixed and confirmed

1. **ASO: sprites missing in the top band.**  The game switches R#9 212 -> 192 while
   YP is between the two end lines, so neither window-close compare fires and the
   display window stays open into the next frame: the top 26 lines (YP -26..-1,
   nominally border) are real display.  afde2e4's sprite window allowed negative YP
   only at -2/-1.  Fix: `W_ACTIVE` also accepts `YP<0 AND PREWINDOW_Y='1'`
   (vdp_sprite.vhd, new port).  Normal frames are pixel-identical before/after in
   GHDL; `tb_05` shows all 16 rows of a 16x16 sprite after the fix, 4 before.
   **Hardware-confirmed.**  Commit 47ca807.
2. **OSD rows shifted by one.**  `I,...` in the middle of CONF_STR: menu.cpp draws
   with a loop that has no `I` branch but selects with one that counts every token
   >= 'A'.  Enter on "Reset" toggled the overlay.  Moved to just before `V`.
3. **memory_upload restart race.**  The restart block sat above the FSM, so a second
   `load` (FW pack after machine pack, or an OSD config change) lost the race: the
   case reassigned `state` in the same clock while the counters were already back at
   0, the next header read missed "MSX", and the upload ENDED — machine released on
   half-written SDRAM, which no reset repairs.  Bench with the real FS-A1GT pack,
   second load injected at 300 points: **36 corrupt products before, 0 after**.
   Commit e23e531.
4. **A7h left a turbo R firmware hung.**  The GT/ST firmware polls A7h in its ISR
   (`1A0F in a,(#a7) / rrca / jr nc`); bit 0 set drops it into `1A1F ... jr c,#1a1f`,
   a wait nothing ends.  With "Turbo R features" off the port was undecoded and read
   **3F** on hardware (JTAG capture: the board sat in that loop, VDP never written,
   no interrupt ever accepted), so the toggle silently made every turbo R pack
   unbootable.  A7h is now decoded either way and reads 00.  Commit 8a885b9.
5. **MSX-MIDI status (E9h).**  The GT BIOS services MIDI from inside its ISR —
   `1A74 in a,(#e9) / and #02 / call nz,#ff75`, same for bit 7 at #ff93.  A real GT
   reads 05h there, so neither hook is ever called; undecoded it reads FF and the
   handler calls both RAM hooks every interrupt.  Any fetch that comes back FF then
   becomes RST 38h **inside** the handler, which nests: the board's stack walked down
   10h per turn.  `rtl/peripheral/slots/midi.sv` answers only the status read, only
   when the pack declares `DEV_MIDI` (id 5, added to createMSXpack).  The FS-A1ST has
   no MIDI and no such code — GT packs only.  Commit 53a1c64.
6. **Global reset synchronised.**  `RESET` and `status[64]` are asynchronous to
   clk21m and fed the reset tree combinationally, so the width and the release edge
   depended on placement (SEED 6 missed recovery by -0.255 ns).  Two flops + a
   63-cycle stretch; recovery 2.20 -> 3.74 ns.  Commit 8d1d8bf.  **No hardware
   evidence that it fixed anything** — it is a defect in its own right.

### Pack defects found by these captures (peer's fixes, branch `sony-dos2-3-3`)

- **Opening ROM missing** from every GT/ST pack.  16 KB at slot 0-3; its first
  0x3900 bytes are FF, which is why the pack builder judged it empty — but the turbo
  R BIOS calls **7900h** in it directly.  Pack 443,120 -> 459,520 bytes.  openMSX
  shows the reference survives the missing ROM: ~2.44 s of RST 38 storm, then it
  climbs out into workspace and boots to BASIC anyway.
- **ST had MSX-MUSIC at slot 0-1**; correct is 0-2.  The same routine lives in the
  Opening ROM on GT (0-3) and in the MSX-MUSIC ROM on ST (0-2), and the BIOS picks
  the subslot by a hardcoded constant (GT: FFFF<-0C, ST: FFFF<-08).
- GT packs gained `<device typ="MIDI">` (459,536 bytes).  ST deliberately did not.

Board now: GT stock b3d1e178…, ST stock 7c0be268….  A backup of the previous GT packs
(Opening-ROM-only build) is in `~/msxpack_bak_20260920/`.

## 2. Still open

**Illusion City hangs on GT and ST**, reproducible.  Not yet located.  Three
captures, three false freezes, each one a lesson about the instrument rather than
the bug:

1. the BIOS workspace LDIR at 7B78 (opcode-byte exclusion, §4);
2. the same LDIR again (the byte test does not work on hardware: ED B0 is two M1
   fetches, so the byte sampled at the repeat is B0);
3. (ST 1 MB pack, Illusion City disk 1) the turbo R BIOS **RAM-size search at
   7D60** — `LD A,(HL)/CPL/LD (HL),A/CP (HL)/CPL/LD (HL),A/JR NZ/INC L/JR NZ`,
   68 T-states = 19.0 us, matching the dump's 18.6/19.4 exactly, walking EF00
   down to 8000: **one address fetched 28672 times over 545 ms while making
   perfect progress**.  Everything before it in that ring was a healthy boot
   (7B78 LDIR, the A8 = 00/40/80/C0/F0 slot scan with FFFF read back
   complemented, a second LDIR at 7C84) and the screen showed the machine had
   run on well past it.

So a repeat count cannot find a wedge at all, and the ring was being spent on
loops.  Both are fixed in `20260920q_loopfold`: loops are folded to one word with
a count, and the wedge trigger is TIME — one branch target held unbroken for ~2 s
(the 545 ms search is the longest legal run known; a 64 KB LDIR is 440 ms).
Verified in `tools/evtrace/tb_evt.sv`, six cases including the RAM search, which
must not trigger.

**SC.COM stops after `MAPPER SEGMENT`** with a self-loop at 2D30 (1.5 us per fetch,
interrupts off, VDP IRQ pending, SP 2762 fixed).  2D30 is in DOS RAM, so the opcode
cannot be read out of the pack — needs the opcode logged (§4).

**Intermittent boot failures** — whether any remain after the pack fixes is untested.

**MIDI stage 2** (a real i8251 + i8254 so MIDI output works over MiSTer's UART in
MIDI mode) is feasible and scoped in §5; nothing written yet.

## 3. The instrument: JTAG event recorder

`rtl/evt_trace.sv` — 2048 x 80-bit ring, read over JTAG with the In-System Memory
Content Editor, the same mechanism as `vdp_regprobe`/`az80_trace`.

    quartus_stp -t tools/dump_evtrace.tcl      # writes /tmp/evtrace_dump.txt
    python3 tools/parse_evtrace.py             # renders it oldest -> newest

One word per EVENT, not per clock, each with PC, SP, CPU (t80/nz), IFF1 and the two
interrupt lines:

| kind | when |
|---|---|
| `INTA` | an interrupt acceptance (M1 + IORQ) |
| `IOR`/`IOW` | 98h-9Bh, A5h/A7h, C4h, D0h-D7h (FDC), E4h/E5h, A8h, FCh-FFh |
| `SUB`/`SUBR` | write/read of FFFFh, the secondary slot register |
| `BR` | an opcode fetch whose address is not 1..4 past the previous one — every jump, call, return, loop-back |
| `R38` | an M1 fetch of 0038h, carrying the address fetched just before it |
| `SWAP` | `use_nz` changed (Z80 <-> R800) |
| `IFF` | IFF1 changed |
| `RST` | machine reset (re-arms the triggers, keeps the ring) |
| `LOOP` | a folded loop ending here: its address and its repeat count |

Loops are folded: after 8 fetches of one branch target the recorder stops storing
that loop — repeats and the port traffic inside it — and writes a single `LOOP`
word with the count when something else breaks it.  2000 LDIR iterations cost 11
ring words instead of 2000, so the ring spans seconds rather than milliseconds.

Triggers freeze the ring and write a marker so the dump keeps the ~2000 events
BEFORE the event: 8 RST 38 in a row (storm), or one branch target held unbroken
for ~2 s (wedge).  The wedge unfolds on firing, so the last 64 words are the wedge
itself.

## 4. Read this before trusting a capture

- **A repeat count cannot find a wedge — only time can.**  Three builds died on
  this.  `LDIR` re-fetches its own ED prefix once per byte, so on the address bus it
  is indistinguishable from `jr $`; the first trigger froze on the BIOS clearing
  3191 bytes at 7B78 (20.6 ms; hardware 6.7 us per iteration, openMSX 6.45 — the
  board was perfectly healthy).  **Excluding by opcode byte does not work**: ED B0
  is TWO M1 fetches, so at the repeat the last byte sampled is B0.  Excluding by
  ADDRESS (a two-byte opcode fetches addr+1 between repeats) does work for block
  instructions — and then froze on the **RAM-size search at 7D60**, a single
  address repeated 28672 times while making progress.  The test that survives is
  TIME: no legal loop holds one branch target for seconds.  HALT with interrupts
  off still trips it, which is right.
- **The IOW/IOR event PC is the PC after the instruction**, one instruction ahead of
  a disassembly.  042B reads as 042D, 7B66 as 7B68.  Subtract before comparing.
- **Count event kinds by token, not by column** — a `BR`/`INTA` line has a trailing
  note, so `$4` is the kind on some lines and `$3` on others.  Counting by column
  once reported "INTA 0" on a capture with 40 acceptances and sent the whole
  diagnosis down the wrong path.
- **A single lookback tap cannot test "was IFF1 set"** — sample close and the core
  has already cleared it for this acceptance, sample far and a legal acceptance just
  after EI reads the pre-EI 0.  Both happen; measured in `rtl/cpu/cpuswap/sim`.  The
  test is "IFF1 never 1 anywhere in the last 8 clocks".
- **Peeking at a RAM address means nothing without A8.**  The hook area reads FF
  whenever page 3 is not on RAM.
- **The ring is per-reset**: `RST` re-arms the triggers, so a dump can hold several
  boots.  Sort by time before reading it; the unrolled order is only valid for the
  epoch the marker belongs to.

## 5. MIDI stage 2, if it is ever wanted

Feasible; the path exists end to end.  `sys_top` already wires `UART_TXD`/`UART_RXD`
to the core (we tie them to 0 today), the firmware has a MIDI UART mode at 31250
baud (`config_uart_msg` in menu.cpp, `/tmp/ML_USBMIDI`), and a core declares it in
**CONF_STR index 1** — which for MSX1 is currently just `-;`, so it is free.

Work: i8251 (mode/command registers, TxRDY/RxRDY/TxEMPTY, 31250 baud TX, RX) and
i8254 (baud + the interrupt counter), ~400-700 lines, plus the CONF_STR declaration
and pin wiring.  Verification: peer captures E8h-EFh accesses and the emitted bytes
from openMSX, the RTL replays them in a bench (the pattern already used for the VDP
and memory_upload), then a USB-MIDI device on the board.  Risk: MSX-MIDI raises
interrupts, so it touches the ISR path that only just became stable — needs the
multi-game regression.

Note the side effect of stage 1: a GT now looks to software as if MIDI exists, so a
MIDI-aware program may route music to MIDI and be silent.  That is what a real GT
does, but on our machine the bytes go nowhere until stage 2.

## 6. Other harnesses used today

- `$CLAUDE_JOB_DIR/tmp/upl/` — memory_upload bench: the real GT pack, a second
  `load` injected at 300 points, compares the final SDRAM image and the slot tables
  against an undisturbed run.  Rebuild with `verilator --binary` over
  `rtl/package.sv`, the tb, `memory_upload.sv`, `mapper_detect.sv`.
  **Its own trap**: the first version hashed unused slot_layout entries, so leftovers
  from an aborted upload made every later trial "differ" (376/400 -> the real number
  is 36/300).  Hash only what the machine can reach.
- `$CLAUDE_JOB_DIR/tmp/tb/` — VDP replay bench: an openMSX capture (VRAM + registers
  + cycle-stamped port I/O) replayed into the VDP RTL, rendering to a PNG.  This is
  what proved the ASO sprite fix and that normal frames are untouched.
- `rtl/cpu/cpuswap/sim/run.sh` — now also counts interrupt acceptances inside a DI
  region (`VIOL-DI`): 0 violations, RESULT PASS.

## 7. Working with the peer session

openMSX work goes to `msx1-mister-sonydos2-55` (see the memory note).  It produced
the ASO savestates, the GT/ST boot traces, the ISR disassembly and the pack fixes.
Cross-check what comes back — it has corrected itself twice (an adjacent-frame
sprite table, and "the Opening ROM omission bricks the machine", which openMSX then
showed it does not).  Equally, its reading of our own captures caught two of my
errors.  Reference milestones for a GT boot, from that session:

    0.0209 ms  SLTTBL filled            0.5800 ms  first VDP write (R#18 <- 00)
    0.0241 ms  hooks filled with C9     0.5991 ms  JP (IX) 7900   <- first gate
    0.5757 ms  first EI                 1.9025 ms  first interrupt accepted
    4.921  ms  first FDC command (SPECIFY)

A healthy machine executes 0038h **twice per interrupt** (RAM stub `08 D9 F5`, then
the ROM vector `C3 3C 0C`).  0038h executions with no INTA at all means RST 38h is
being executed as an opcode — a runaway, not an interrupt.
