# Handoff 20260918 — user's machine: cpuswap imported, reviewed, hardware-confirmed

Companion to `handoff_20260918_cpuswap.md` (the peer's, whose §12 and §13 this
session wrote).  This one is the view from the user's machine.

## 0. Where things are

| | |
|---|---|
| Branch `cpuswap` | `.claude/worktrees/cpuswap`, **pushed to origin**.  Peer patches `f30ef60..7a07534` + this session's doc commits |
| Branch `rz80` | `.claude/worktrees/rz80`, **local only — RZ80 has no licence, never push**.  Tip `6218ca2` |
| Branch `T80s_turbo` | `.claude/worktrees/t80s_turbo`, clean, never built.  **Superseded** — peer patch 0004 does the same thing (A-Z80 out, T80s on every speed) from a 64-commit-newer base.  Kept, not deleted |
| Branch `nextz80` = `az80_nextz80` | `0e04047`, both on origin.  The A-Z80 line, archived |
| RBF ledger | `rz80` branch, `docs/rbf_catalog_20260918.md` |
| Running RBF | `~/Downloads/MSX1_20260918b_cpuswap.rbf`, md5 `f2d13c7a…`, RTL = `cpuswap` `74e90be` |

Quartus here is 17.1 (fit 60-70 min); the peer's is 17.0 on 16 cores (21 min).
**Division of labour that worked today: the peer builds and runs the games, this
machine reviews the RTL/SDC and the software side.**  Do not repeat a fit here
just to confirm one the peer already ran.

## 1. Hardware status of 20260918b — all confirmed by the user

- Z80BENCH: `Machine: MSX TurbR`, **49.46 MHz equivalent, 1382 %**.  The clock is
  still 21.477 MHz; 1382/600 (T80s at the same clock, 20260913b) = **2.30x more
  work per clock**.  `CPU Type: Z80` is expected — R800 detection needs
  `MULUB`/`MULUW`, which NextZ80 does not have.
- OSD rows `TURBO R FEATURES: ON` and `CPU (TURBO R): R800 (NEXTZ80)` render and
  act.  **Status bits 117/118 are now proven** — the "116 is the ceiling" worry
  from 20260904 is retired.
- FDD works; **Akumajou Dracula played through in R800 mode**; **Hi no Tori
  playable in R800 mode**; **no SCC regression**.
- Therefore closed: the full-rate `ce_cpu` question (PSG strobe / M1 wait / FDC all
  hang off it), and the peer's leftover post-map negative `T80s -> SCC falling edge
  -18.7 ns`, which hardware says was post-map pessimism.

## 2. Two defects found here

*(Resolution 2026-09-19 in §7: (b) is closed as "do not use those packs with
the option On", no RTL change; (a) is still to be applied.)*

**(a) `002Dh` = 03h is forced whenever the feature block is On, even with the Z80
selected.**  This is the whole of the SCMD symptom, proven from the binary:

```
SC.COM  0108h  LD A,(FCC1h) / LD HL,002Dh / CALL RDSLT     ; MSX version
        0114h  JP C,0216h   -> "Do not operate in MSX1."
        0117h  JP Z,0160h   -> CORE2.SYS   (MSX2)
        011Ch  CP 3 : JP Z,0208h ---------> LD HL,025Ch = "CORER   SYS"
        011Fh  OUT(40h)/IN(40h)=F7h? -> OUT(41h) -> CORET.SYS (Panasonic x1.5)
```

SCMD picks its player core from the version byte.  With the option On it always
loads `CORER.SYS`, the R800 core — and `CORER.SYS` is the only one of the three
that uses `IN A,(E6h)`.  This is why the CPU setting makes no difference: **the
core is chosen by 002Dh, not by which CPU owns the bus.**  Side effect: the
Panasonic 40h/41h path is now unreachable, so `CORET.SYS` is never selected.

Fix: gate the `002Dh` overlay on `r800` (i.e. `O[118]`), so the machine only claims
to be a turbo R when it is actually running NextZ80.  Then SC picks `CORE2`/`CORET`
in Z80 mode and `CORER` in R800 mode — software's choice matches the hardware's.

**(b) The `0180h-018Bh` overlay lands on live BIOS on five ROMs.**  Checked every
main BIOS in `releases/CreateMSXpack/ROM`:

| 0180h | ROMs |
|---|---|
| `FF`/`00` padding — harmless | Panasonic (all), Sony, Sanyo, Mitsubishi, Philips, Canon V-20, all C-BIOS |
| real jump entries `C3 69 14 / C3 06 10 / C3 12 10` | Daewoo `cpc-300`, `330kbios`, `400sbios` |
| real code `01 C2 E1 01 D1 E5 CD 99 01 …` | Canon `v-8`, Sanyo `cf-2700` (German) |

Affected packs: **Daewoo CPC-300 / CPC-300E / CPC-400S** (400S already
`_notwork_`), **Canon V-8**, **Sanyo CF-2700 (DE)** — the Korean machines lose
their Hangul entries at 0183h/0186h/0189h.  None of them are turbo R machines, so
gate the overlay (MSX2+ only, or "only where those bytes are FF/00") rather than
moving the stubs.

Both fixes are small and belong in one commit.  Neither was applied — the user has
not decided yet.

## 3. What "Turbo R features: On" changes (full list)

Nothing decodes, overlays or mutes while it is Off.  On:
1. Four port groups appear: E4h/E5h, E6h/E7h, A4h/A5h, A7h (all unused on MSX2+).
2. `002Dh` = 03h on every machine, MSX1 packs included — see 2(a).
3. `0180h-018Bh` overlay — see 2(b).
4. `A5h` bit 1 = 0 silences the **whole machine** (`mute_all` zeroes `audio_l/r`,
   msx.sv:249).  openMSX-accurate, needs a deliberate write, but it is a
   silent-failure surface that does not exist with the option Off.
5. The Pause key becomes a hardware pause (A7h bit 1 + key state).

## 4. What was checked and found SAFE (do not re-investigate)

- **No DOS2-return failure in the SC path.**  SC.COM's two error exits are
  `JP 0000h` (warm boot); the normal path is `JP 0300h` into the loaded core and
  never returns, so returning to DOS was always the core's job.
- The only unbounded loop is `CORER.SYS:1E04h`
  (`IN A,(E6h) / CP n / RET NC / JP 1E04h`, n = 1 or 7 self-modified at 1E07h — it
  is the OPLL 7Ch/7Dh write-gap timer).  It terminates in **both** states: with the
  option On the E6h counter advances on `ce_3m58`, which free-runs independently of
  CPU speed (msx.sv:469); with it Off nothing decodes E6h, `d_to_cpu` falls through
  to `d_from_slots`, and that is an AND bus reading **FFh**
  (msx_slots.sv:147), so `FF >= n` exits at once.  **Turning the option off during
  playback does not hang the machine.**
- `nz_bus` provably advances at most every second clk21m (`adv` needs `ph`, and
  `adv` clears `ph`), which is the sole justification for the broad `-end 2`.
- Address-sampling audit complete: `a_q` (cheat, already a single-cycle exception),
  `fadr_p1`, `addr_d` (both forensics-only).
- Every multicycle has its hold counterpart, and node exceptions are written after
  the clock-based rule so they outrank it.  No `set_max_delay` near the CPU.

Latent, harmless: SC.COM double-pops AF (pushed 0111h, popped 01C2h, popped again
at 0177h reached from 01E9h).  Only on a failed `.SY2` open, and `JP 0000h` resets
SP anyway.

## 5. Still open

*(Items 1-4 were closed or decided on 2026-09-19 — see §7.)*

1. ~~Apply the two fixes in §2.~~  **Decided:** 2(a) `002Dh` gating still to do;
   2(b) the `0180h` overlay will **not** be gated — the affected packs are simply
   not to be used with Turbo R features On (§7).
2. ~~`CPU Type: Z80`~~ — **answered, no defect.**  Z80BENCH 1.4.2 probes with
   `MULUB`, not the S1990 register: at `1E26h` it does
   `LD L,0 / XOR A / LD C,A / INC A / ED C9 (MULUB A,C) / RET NZ / INC L`.
   `INC A` leaves NZ, so a Z80 (which runs `ED C9` as a NOP) returns L=0; only a
   core whose MULUB sets Z on a zero result reaches `INC L`.  Reporting `Z80`
   before MULUB existed was correct behaviour, not an inverted bit.
3. ~~SCMD's wrong sound is R800 cycle counts, no patch fixes that.~~
   **Partly retracted, and still open (§7).**  The cycle-timing explanation was
   wrong and `MULUB` was a real cause, but SCMD did not stay fixed: with the
   feature block On it fails INTERMITTENTLY, on 20260918c too.
4. ~~`MULUB`/`MULUW`: recommended to hold off.~~  **Superseded (§7):** real
   software already on our NextZ80 was executing them and silently getting
   garbage, which outranks the detection argument.  Implemented in `abec124`.
5. PCMPLY (0186h) is still a stub, but its prerequisite — CPU state export via
   `SWAPPT`/`REG`/`XREG` — now exists.  Design is in `rtl/peripheral/turbor/README.md`.
   PCMREC has no audio input and is not worth building.
6. `rtl/peripheral/turbor/README.md` is stale: it still says "nothing switches the
   CPU yet".  Software CHGCPU does switch now (`msx.sv:360 .want_nz(tr_r800)`).
7. **`tools/buildgate/triage.tcl` (rz80 `6218ca2`) has never been validated.**
   It judges the SDC by requirement vs the CPU's enable grid instead of by post-map
   slack.  Before trusting it: run it against a fresh map, then negative-control it
   by temporarily restoring the two `set_max_delay … 23.283` lines — it must report
   TRIAGE-FAIL on that group.  The allow-list and threshold are guesses.
8. Not received: `MSX1_20260917a_rz80boot.rbf` (md5 `b3558a96…`).  RZ80 at 10.74 is
   still unproven on hardware — and is not a shipping target anyway (T80s already
   does 21.5, and RZ80's ~31 ns critical path cannot close a 23.28 ns phase).

## 6. Pitfalls worth carrying forward

- `pgrep -f quartus_` / `pkill -f` match the searching shell itself.  Use
  `ps -eo pid,args | grep '[b]uildgate/build'` or `pgrep -x quartus_map`.
- A bare `quartus_map` needs `build_id.v`, which is gitignored and only created by
  the full flow's pre-flow script.  Its absence looks like a design error.
- `tools/buildgate/build.sh` line 20 is this machine's Quartus volume; sandboxes
  edit it locally to 17.0.  Never commit that edit.
- Post-map delays are 1.5-2x inflated, so post-map **slack** proves nothing.  Judge
  the **requirement**.
- RBFs are never deleted, on the board or in the repo.

---

## 7. 2026-09-19 — SCMD: MULUB was one of the causes, NOT all of them

**Symptom.**  With Turbo R features On, `sc` printed its banner as far as
`Master SCC CARTRIDGE SLOT1` and the machine stopped dead, not even the CRLF.
Read out of one screenshot, so the method is worth keeping:

- The coloured strip down the left is `debug_overlay.sv` under `MOONSOUND_DIAG`
  (66 x 236 px, `status[48]`).  Sampling the centre of each cell in the PNG
  recovers all 39 rows.  Anchors that prove the decode is aligned: `ab_pc=042A`
  (BIOS init) and `ppi_ctl=8102` (MS=1, RV=0, ctrl=02h) — both the documented
  healthy-boot values.
- The signature was **noM1 latched, WAIT-stuck dim**: the CPU had stopped
  fetching for >760 us without the bus ever holding WAIT.  That rules out a bus
  or WAIT deadlock and rules out a runaway (which keeps M1 cycling).
- The pause symbol top right is **not evidence**.  Taking a screenshot pauses
  the core, so every screenshot the user has ever taken carries it at the same
  coordinates; a control set from another day showed it on healthy gameplay.

**Root cause, from the binaries.**
1. The forced `002Dh = 03h` makes `SC.COM` (`0108h`: RDSLT 002Dh, `CP 3`,
   `JP Z,0208h`) always load `CORER.SYS`, the R800 core.
2. `CORER.SYS` alone — `CORE2.SYS`/`CORET.SYS` have neither — contains
   `ED D9` (`MULUB A,E`) at 1538h, 1CFAh and 23D9h, inside a table-interpolation
   routine (`SUB C / NEG / PUSH BC / MULUB A,E / LD C,H / LD B,0 / SBC HL,BC`).
   It also wraps **every** BDOS call in CHGCPU: `2D1Dh` calls `0180h` through
   CALSLT with A=80h (Z80) before `CALL 0005` and A=81h (R800) after — five
   `LD IX,0180h` sites.
3. NextZ80 decoded the whole `ED C0..FF` range as NOP (`nextz80cpu.v`
   "ED + 2'b11 = NOP"), so MULUB was swallowed: HL kept its previous value and
   the caller used the result as a pointer.

**`abec124` (MULUB/MULUW) fixed the MULUB half.**  On build `20260918c_mulubw`
`sc` was seen running to completion with the music playing correctly, and the
§5.3 claim that the wrong sound was R800 cycle timing and unfixable is retracted
— that part was a missing instruction, not timing.

**But SCMD is NOT closed (corrected 2026-09-19, same day).**  Re-tested, it fails
with the feature block On **intermittently** — sometimes it runs, sometimes it
does not — and that includes 20260918c, so the first "it works" reading was a
lucky run, not a fix.  PCMPLY and the R800 speed ladder are both ruled out: the
failure predates them and happens at 7.16 MHz and 21.5 MHz alike.

What that intermittency means for the diagnosis above: the freeze in the
screenshot stopped at an ARBITRARY point in the banner, which a deterministic
missing instruction cannot do — that is a race, and the MULUB routine at 1538h
may not even have run by then (flagged as unverified when it was written, and it
is still unverified).  So MULUB was a real defect found along the way, not the
whole story.

**Prime suspect, not yet tested:** NextZ80 losing the odd bus cycle.  On the same
hardware Z80BENCH drops 2-3% of its characters in R800 mode with no CPU swap
anywhere near it (§7.1), so the loss is in the NextZ80 bus path itself; the same
thing happening to a memory write during CORER.SYS's load would produce exactly
this "works some runs, not others".  The cheap decisive test is an MSX-side
integrity program (OTIR a pattern to VRAM and read it back; LDIR one through RAM
and verify; report counts through a port, not the screen) run at Z80 21.5 MHz,
R800 7.16 and R800 21.5.  VRAM only -> the VDP interface; RAM too -> nz_bus in
general, which would put every R800 run in doubt.  Parked at the user's request
on 2026-09-19.

Lesson, the same one as the SCC ch4 episode, and this time it caught me from the
other side: an intermittent fault will hand you a passing run and let you close
it.  One good run is not a fix.

**Three decisions taken with the user (2026-09-19).**

1. **The `0180h-018Bh` overlay stays as it is.**  It does land on live BIOS code
   in Daewoo CPC-300 / CPC-300E / CPC-400S, Canon V-8 and Sanyo CF-2700 (DE)
   (§2b).  Rather than gate it, **those packs are not to be used with Turbo R
   features On** — the option is an MSX2+/turbo R feature and none of them is
   such a machine.  Nothing in the RTL changes; this note is the fix.
2. `002Dh = 03h` gating (§2a) is still open and still wanted: in Z80 mode the
   byte is a lie, the `CORET.SYS` (Panasonic) path is unreachable, and MSX1
   packs get 03h where `SC.COM` would otherwise say "Do not operate in MSX1."
3. PCMPLY parks the CPU with WAIT for the length of a run, so on any build that
   contains it **`dbg_wait_stuck` latches whenever PCMPLY is used**.  The
   diagnostic that cleared the bus in this very investigation is therefore no
   longer trustworthy on those builds unless it is gated on the player's busy.

### 7.1 R800 VDP write loss (open)

Z80BENCH 1.4.2, same board, same disk, three runs: stock T80s 3.57 MHz and turbo
T80s 21.48 MHz (600%) render every character correctly; NextZ80 drops ~2-3% of
them (`computer` -> `coputr`, `V9958` -> `V958`, `50MHz` -> `0MHz`).  The dropped
unit is a whole `OUT (98h)`: VRAM auto-increment does not advance, so the rest of
the string shifts left.  `rtl/msx.sv:709-726` already documents the mechanism —
the V9938 is driven by `.REQ(req & vdp_en & vdp)` with `.ACK()` unconnected, so a
request arriving before the previous VRAM slot finished is silently lost.

It is NOT simply "the CPU is faster": `vdp_gap` enforces 32 clk21m between VDP
accesses regardless of CPU rate, and T80s at 21.48 MHz issues them closer than
that and loses none.  Pacing NextZ80 down to the R800's real 7.159 MHz clock
(build 20260919a) did not fix it either.  So the pacer is not taking effect on
the NextZ80 path.  Two candidates: the strobe/`req` pulse is too short for the
V9938 to sample (the minimum-width term in `vdp_pace_n` covers only the vdp18
path), or a bus cycle is lost before it reaches the fabric.  NextZ80 honouring
WAIT was checked and is not the fault: `nextz80cpu.v:201` gates the entire state
update on `!WAIT`, block instructions included.

Reference numbers for what R800 mode should look like, from openMSX
`Panasonic_FS-A1ST` (system ROMs present on the user's machine, boots in R800
DRAM mode): **575%, "20.59 MHz", no dropped characters.**  Ours: 1382% unpaced,
921% at the 7.16 MHz rung.  Z80BENCH's "CPU Speed" is Z80-equivalent throughput,
not a clock.

**Still unverified:** PCMPLY itself.  `20260918d_pcmply` showed no regression,
but nothing calls PCMPLY yet — a test program still has to be written.
