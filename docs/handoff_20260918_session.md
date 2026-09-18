# Handoff 20260918 — user's machine: cpuswap imported, reviewed, hardware-confirmed

Companion to `handoff_20260918_cpuswap.md` (the peer's, whose §7 and §8 this
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

## 2. Two defects found here, neither fixed yet

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

1. Apply the two fixes in §2.
2. `CPU Type: Z80` — confirm how Z80BENCH probes.  If it reads S1990 register 6
   bit 5 rather than needing `MULUB`, a bit is inverted and that IS a defect.
3. SCMD's wrong sound is **not** explained by the E6h timer (§4) and not by PCM
   (no core writes A4h/A5h).  What is left is that `CORER.SYS` is written for R800
   cycle counts, and **NextZ80 is not cycle-compatible with the R800** — no patch
   fixes that.  To confirm, record the same song on openMSX's real turbo R and on
   our core and compare.
4. `MULUB`/`MULUW`: **recommended to hold off.**  Making detection succeed only
   routes more software onto R800 paths we cannot time correctly (see 3).
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
