# Handoff 20260918 — cpuswap: T80s ⇄ NextZ80 hand-over, turbo R block, core rework started

## 0. Where everything is

| What | Location | State |
|---|---|---|
| Branch `cpuswap` (from `nextz80` 0e04047) | `/home/sysop/data/MiSTer_build/cpuswap` | **committed 564901c**: hand-over (sim only) + turbo R block wired into msx.sv on the A-Z80/T80s cores |
| Build of 564901c | same tree, `tools/buildgate/build.sh --stages fit,asm --expect turbor`, log `/tmp/buildgate_cpuswap.out`, stage logs `/tmp/buildgate_cpuswap/` | **BUILDGATE PASS** (fit 21:20, slow setup +0.600 / hold +0.206, fast setup +3.891 / hold +0.094, 12/12 relations, 78 % ALM).  `output_files/MSX1_20260918a_turbor.rbf` md5 b3caeae4155c83a060c91dc1af4ca33f, sent to the user (A-Z80 3.58–10.7 + T80s 21.5 as in `nextz80`, turbo R features behind OSD, no CPU switching yet).  Hardware untested |
| Branch `cpuswap-cores` (from 564901c) | `/home/sysop/data/MiSTer_build/cpuswap-cores` | the core rework, **just started**: `rtl/cpu/cpuswap/nz_bus.sv` written; everything else in §4 not done.  Uncommitted: `nz_bus.sv`, this doc, the local Quartus-path edit in `tools/buildgate/build.sh` (line 20 → 17.0; do not commit) |
| `rz80` / `rz80-eval` | `MSX1_MiSTer` (branch rz80), `rz80-eval` (detached ae3294e) | untouched today; see `docs/handoff_20260917_rz80.md` in rz80-eval.  RZ80 has no licence: never push |
| Bench tools (not in repo) | scratchpad `/tmp/claude-1000/-home-sysop-data-MiSTer-build-MSX1-MiSTer/f91b9f1c-.../scratchpad/tools/` | GHDL 4.1.0 (`ghdl-gha-ubuntu-22.04-mcode` release — 5.x/6.x need glibc 2.38), sjasmplus 1.20.3 built with `make USE_LUA=0`.  Verilator 4.038 is system-wide.  ModelSim ASE 17.0 is installed but `vsim` lacks 32-bit X11 libs.  Rebuild the two if the scratchpad is gone |

## 1. Decisions taken (user, 2026-09-17/18)

1. Seamless run-time switch between the Z80 (T80s) and NextZ80, triggered by **both** the OSD and a software port.
2. Undocumented flag bits 3/5 are abandoned across a swap (WZ/MEMPTR and Q are not transferred).
3. NextZ80 stays on clk21m for now.
4. The branch carries **T80s + NextZ80 only** — A-Z80 comes out.
5. The software switch **mimics the turbo R**: S1990 at E4h/E5h; NextZ80 stands in for the R800.
6. Turbo R extras: OSD menu item; BIOS entries 0180h–018Bh and 002Dh **forced** (overlay); PCM, E6h timer, pause key implemented; no firmware ROM; LEDs not on the board yet ("OSD overlay LED later"); PCMPLY/PCMREC as a **hardware player** (design only so far, see `rtl/peripheral/turbor/README.md`).

## 2. What is done and verified (commit 564901c)

- **T80** (`rtl/cpu/T80.vhd`, `T80_Pack.vhd`, `T80s.vhd`): `SwapPt`/`SWAPPT` output = M1 T2 after the previous instruction's deferred write landed; `DIRSet` also clears `Alternate` (register bank) and the NMI latch.
- **NextZ80** (`rtl/cpu/nextz80/patched/`, originals untouched, `patches/check.sh` proves patched = originals + `patches/000{1,2}`): `LOAD`/`LDIR`/`XREG`/`SWAPPT` (PC−1/R−1 export, bank bits resolved, INT resampled on load); patch 0002 fixes R lagging by one after `LD R,A` (a NextZ80 bug).
- **`rtl/cpu/cpuswap/cpuswap_ctl.sv`**: RUN → XFER → FLIP → SETTLE.  SETTLE (one extra frozen clock after the bus flips) was added after the bench caught NextZ80 latching a byte read at the previous owner's address.
- **`rtl/peripheral/turbor/turbor.sv`** wired into `msx.sv` behind OSD `O[117]` "Turbo R features" (default Off, bit never used before): S1990, BIOS overlay (002Dh=03h, CHGCPU/GETCPU stubs with one-shot format translation, PCMPLY/PCMREC return-only stubs), E6h/E7h timer, A4h/A5h PCM into the audio mix (+ all-sound mute), A7h pause key → `msx_pause`.  `msx_slots` gained `main_rom0` (slot 0-0 page 0).  Details in `rtl/peripheral/turbor/README.md`.
- **Bench** `rtl/cpu/cpuswap/sim/run.sh` (GHDL=… SJASMPLUS=… env): RESULT PASS on T80s-only (reference), NextZ80-only, 8 random seeds, CEN/3, swap at every point (~111k swaps), every point + INT, five EI rhythms, software S1990 switching (24 switches incl. CHGCPU/GETCPU through the overlay, timer/PCM/pause checks), negative control.  10 mutations each turn it to FAIL (`rtl/cpu/cpuswap/README.md`).
- **Not** in 564901c: any CPU switching on hardware.  `CHGCPU` to R800 stores the selection; the machine keeps running on the current core (`GETCPU` reports R800).

## 3. Design of the core rework (worked out, mostly not yet coded)

**Bus contract for NextZ80** — `rtl/cpu/cpuswap/nz_bus.sv` (written): NextZ80 advances on clk21m edges where `adv = en & ~hold & ~pause & ph & wait_n`; `ph` = 0 for the first clock after an advance (strobes **masked**), 1 after.  So every stage = 1 idle clock + ≥1 clock of visible strobes, extended by WAIT.  Strobes fall between stages, which edge-detected SDRAM requests / `req` one-shots require (consecutive PUSH writes would otherwise merge).  Z80 levels: `rd = (MREQ|IORQ)&~WR` except IACK (`IORQ&M1` → RD high so the read mux gives FFh), `rfsh_n = 1`.  BRAM's registered read fits: address at clock 0, registered at clock 1, sampled at edge 2.

**msx.sv** (to do):
- Remove A-Z80 (`az80_wrapper`, `az_rst_sync`, `az_m1w_n`, `az80_trace`, `use_t80`, `az80_clk` port).  T80s owns speeds 0–4 (`ce_cpu` from `clock.sv` already covers all five; T80s on all speeds was the shipped state before the A-Z80 migration, 20260913b).
- Add NextZ80 + `nz_bus` + `cpuswap_ctl`.  `want_nz` = `turbor.r800`.  New OSD `O[118]` R800 select → `turbor.set_stb/set_r800` when the OSD closes (turbor's `set_stb` is not gated by `en`; the port needs Turbo R features On).
- Bus mux: owner's strobes, **forced idle while `ctl.busy`** (so the guard re-arms and SDRAM requests re-edge across a hand-over); address/data muxed by `use_nz`.
- **Keep** the A-Z80 SDRAM machinery for NextZ80, renamed `nz_*`: the two-stage request delay `sdram_ce_sr` in MSX1.sv (`ch2_req_cpu = use_nz ? delayed : raw` — NextZ80 changes the address on the MREQ edge like A-Z80, T80's half-T-state lead is what the generic `-end 6` relies on) and the clk_sdram read pacer `az_rd_win/az_win_s1/s2/az_armed/done/hit/wd` → `az_rd_pace_n` with `nz_rd_win = use_nz & bus_xfer & sdram_ce & ram_rnw`.  Timeline is the A-Z80 10.7 one (NextZ80 samples WAIT 2 clk21m = 8 clk_sdram after the strobe): capture 3, hit 5, registered 6, release before 8.
- M1 wait: `wait_m1_eff_n = use_nz ? exwait_n : wait_m1_n` (R800 has no MSX2 M1 wait; the 74LS74 pair does not fit NextZ80's M1 pattern).
- Bus guard / pacers: everything gated on `cpu_turbo` (`bus_guard_n`, `hs_win`, `vdp_hold`, `vdp_pace_n`, `sd_pace_n`, msx_slots `cpu_turbo` → `opll_pace_n`) must use `cpu_turbo | use_nz | resume_guard`.  `resume_guard` = set on FLIP, cleared when the first bus cycle ends: the resumed T80s sits in T2 and would sample DI one CEN after the flip at stock speed, before an SDRAM read is home.  At stock speed with cpu_turbo=0 the guard is otherwise off.
- `t80_reg = t80_reg_t80` unconditionally (forensics only).
- INT to NextZ80: `~(vdp_int_n & ms_int_n)`; NMI 0.  DI = `d_to_cpu`.

**MSX1.sv**: drop `az80_clkgen`, `use_t80`, `core_switch_cnt/rst` (remove from the `reset` OR — no reset on switch is the point); `cpu_speed` stays 0–4 into `clock.sv`; `O[118]`; `use_nz` comes out of msx.sv for `ch2_req_cpu`.

**files.qip**: drop `cpu/az80/az80.qip`; add a `cpu/cpuswap/cpuswap.qip` with `nextz80/patched/*.v`, `cpuswap_ctl.sv`, `nz_bus.sv`.

**MSX1.sdc**: delete the whole "A-Z80's clock" section (from `create_generated_clock -name az80_clk` to the end).  Keep the generic T80 `*sdram*ch2_* -end 6`.  Add: NextZ80→NextZ80 `-end 2 / hold 1` (enabled edges ≥2 clk21m apart; `LOAD` sources are registered T80 REG, fine); clk21m-sourced `-end 3` to `*msx:MSX|nz_win_s1` and `-end 2` to `*sdram_ce_sr[0]` (the two existing "clk21m slot/mapper state" rules already say this — keep them, rename the register), and clk21m → `*sdram*ch2_*` for NextZ80 sources: `-end 3` from `*NextZ80:NZ|*` overriding the generic 6 (address settles from a clk21m edge, captured on the 3rd clk_sdram edge).  Keep `set_false_path -from status[56..58]`.  No false path between the cores: REG→LDIR and XREG→DIR are real single-cycle paths.
**tools/buildgate/relations.tcl**: replace the 12 A-Z80 pairs with: `NZ_intra` 93.132 (two clk21m, the `-end 2`), `NZ_to_SD_ch2` 34.923, `NZ_to_SD_sync` 34.923, `NZ_to_SD_rqd` 23.282, `C21_to_SD_sync` 34.923, `C21_to_SD_rqd` 23.282.  Delete the az80 entries or `--expect` fails on "no paths".

## 4. Next steps, in order

1. **Bench first** (`cpuswap-cores/rtl/cpu/cpuswap/sim`): rewrite `tb_swap.sv` so BOTH cores drive one Z80-level bus through the mux (busy-masked), NextZ80 through `nz_bus`; memory read **registered** (`mem_q <= mem[a]`), writes/I/O edge-detected as in msx.sv, one `iowr_stb`, plus a WAIT source (e.g. IN 98h takes 3 extra clocks).  Add `nz_bus.sv` to the verilator file list in `run.sh` (line 33).  Expect the existing PASS set; a merged-write bug would show as trace diffs in NextZ80-only.  (The rewrite was fully drafted in the session and refused by the editor only because the file had not been re-read — re-do it.)
2. msx.sv / MSX1.sv / qip / SDC / relations per §3.
3. `quartus_map` alone first (needs `build_id.v`: `printf '`define BUILD_DATE "%s"' $(date +%y%m%d) > build_id.v`; it is gitignored, the pre-flow script only runs under the full flow).  Then post-map STA triage before any fit (`rz80-eval/tools/sta/rz80eval_postmap_triage.tcl` pattern — copy and adapt names).
4. `tools/buildgate/build.sh --expect NextZ80`, hardware: boot at every speed on T80s, Z80BENCH, then OSD R800 switch mid-BASIC, then `OUT (E4h),6 / OUT (E5h),0` from BASIC, then CHGCPU via `CALL 0180h` with Turbo R features On.
5. Later: PCMPLY hardware player (needs T80s/NextZ80 state export = after this rework), OSD overlay LEDs, MULUB/MULUW, deciding whether `002Dh=03h` breaks anything (only with the OSD option On).

## 5. Pitfalls this session

- `pgrep -f quartus_` matches its own shell → false "Quartus running" and a skipped build.  Use `pgrep -x quartus_map` etc.
- Bare `quartus_map` fails on missing `build_id.v` (pre-flow script not run); the failure looks like a design error.
- `tools/buildgate/build.sh` line 20 points at the user's 17.1 volume; each sandbox worktree edits it locally to 17.0 — never commit that.
- GHDL 4.1 emits `u0_\reg` identifiers and `do` ports; `run.sh` already patches/handles both (`+1364-2005ext+v`).
- `$value$plusargs` takes the first match: put per-run plusargs before the common ones.
- NextZ80 `RAM16X8D_regs` starts X in simulation; the bench zeroes it through `LOAD`/reset only because the program never reads an uninitialised register — keep it that way or zero it in the tb.
- Never two Quartus jobs on one project; the cpuswap fit must finish before any map in cpuswap-cores.


---

## 6. Update 2026-09-18 (later session): steps 1–3 done, build running

Commits on `cpuswap-cores`: 4ab4f91 (nz_bus + this doc, committed by the user),
e0f6574 (bench), 0593fd9 (RTL / SDC / qip / triage).

**Step 1, bench (e0f6574).**  `tb_swap.sv` drives both cores through the msx.sv mux
(busy-masked), NextZ80 via `nz_bus`, registered memory read, `req` one-shot for
writes/OUT/IN 99h, `iowr_stb`, WAIT source with junk data until it ends, and
`+sdlat` SDRAM-like latency with a pacer (NextZ80, `+turbo`, resume guard).
RESULT PASS on the whole set plus `sdram stock/every/turbo/nz/soft`; `no resume
grd` must DIFF and does.  Measured: an unpaced T80s at CEN/6 tolerates 4 clocks of
read latency, at CEN/3 only 1.  nz_bus mutations (no masked clock; WAIT ignored)
both FAIL.

**Step 2, RTL (0593fd9) — deviations from §3, with reasons:**
- **No A-Z80 SDRAM request delay or clk_sdram pacer for NextZ80.**  `sdram_ce` is
  gated on MREQ & RD in msx_slots, and nz_bus masks the strobes for the clock after
  every advance, so the address leads the request by a full clk21m — the head
  window the generic `-end 6` was argued for.  NextZ80 reads use the T80s-turbo
  closed loop (`hs_win`, `sdram_hit`) through `cpu_paced`.  `ch2_req_cpu = sdram_ce`.
- **NextZ80 `RESET` tied 0**, and nz_bus hold includes reset: a reset sample taken
  while frozen would survive LOAD and restart NextZ80 at 0000h.  Bench mirrors it.
- **ce_cpu at full rate while NextZ80 owns the bus** (`MSX1.sv`: clock.sv speed =
  `use_nz ? 4 : OSD speed`).  PSG bus strobe, M1 wait pair and FDC run on ce_cpu;
  at stock rate a short NextZ80 I/O cycle could slip past the PSG strobe chain.
- OSD `O[118]` "CPU (turbo R)": set_stb when closed and changed, and again after
  every reset.  **Unverified:** whether the board's saved CFG has bit 118 set.
- **SDC is broader than §3.**  Post-map, NextZ80 → fabric single-cycle was ~9 ns
  deeper than T80s' (combinational ADDR) and would not close.  Rule: NextZ80 → all
  clk21m registers `-end 2` (clock-based), justified by nz_bus's masked clock.
  Single-cycle exceptions (node rules): cheat lookup (`a_q`, cheat RAM address
  registers: feeds d_to_cpu on a first-clock SDRAM cache hit) and `cpuswap_ctl`.
  T80s → NextZ80 and → `nz_bus.ph` `-end 2`.  Core↔core is two-cycle, not
  single-cycle as §3 said (each core frozen while the other owns the bus).
  Address-sampling audit: `grep '<= a;'`/`[a]` — only debug latches besides the
  cheat lookup.  Re-audit if a register samples the bare address every clock.
- relations.tcl: NZ_intra 93.132, NZ_to_SD_ch2 69.846, NZ_to_fabric 93.132,
  NZ_to_SCC_fall 69.849, two exceptions 46.566, T80_to_NZ 93.132 (all measured
  post-map; an optional source filter was added to the script).

**Step 3, map + triage.**  quartus_map 17.0: 0 errors; NextZ80 346 registers.
`tools/sta/cpuswap_postmap_triage.tcl`: every NextZ80-sourced family positive;
remaining negatives are T80s-sourced (T80s → SCC falling edge -18.7 post-map) and
existed in the fitted 564901c.  quartus_sta segfaults at exit after "successful"
(rc 2): harmless.

**Step 4 (running).**  `BUILDGATE_LOG=<scratchpad>/buildgate tools/buildgate/build.sh
--expect NextZ80 --expect cpuswap_ctl --expect nz_bus`.  Then hardware as in §4.

---

## 7. Independent review on the user's machine (2026-09-18, rz80 session)

Patches imported onto branch `cpuswap` (from `nextz80` 0e04047, blob-verified);
all five applied clean.  `MSX1_20260918b_cpuswap.rbf` md5
`f2d13c7aa3d3f80269d8265e9a998866` received; its RTL is `74e90be` here.
No build was run on this machine -- the peer's fit and game test are the result,
and repeating them would only spend 60-70 min of a slower Quartus.  What was done
instead is the part a game test cannot cover:

**Confirmed independently**

1. *`nz_bus` really does advance at most every second clk21m.*  `adv = run & ph &
   wait_n`, and `ph` is cleared by `adv` itself, so `adv` cannot be true on two
   consecutive clocks.  This is the sole justification for the broad `-end 2`, and
   it holds.
2. *The address-sampling audit is complete.*  `grep '<= a;'` over synthesised RTL
   finds exactly three: `a_q` (msx.sv:927, the cheat lookup -- already a
   single-cycle exception), `fadr_p1` (:1990) and `addr_d` (:2119).  The latter two
   are forensics latches feeding `dbg_*` only; they are synthesised (no `ifdef`)
   but a late capture there is cosmetic, and they sample an address that is stable
   for two clk21m anyway.
3. *Every multicycle has its hold counterpart* (`-setup -end 2` / `-hold -end 1`,
   `-end 1` / `-end 0`), and the node-to-node exceptions are written after the
   clock-based rule, so they outrank it.  No `set_max_delay` anywhere near the CPU
   -- which is what cost three non-converging fits on the rz80 branch.

**Answered by the user's hardware test (Z80BENCH v1.4.2 on 20260918b)**

4. **OSD bits 117 and 118 work on this board.**  This was the open risk: 116 was
   the highest bit ever used, and a `status[118]` row silently did nothing here on
   2026-09-04 (never isolated -- reverted together with an 11-entry ladder).  The
   test settles it: Z80BENCH reports `Machine: MSX TurbR`, which requires the S1990
   at E4h/E5h to answer, and that block only exists when `O[117]` is On; and the
   core actually changed, which only `O[118]` can do.  **Both rows render and act.
   Bits 117/118 are now proven, and the "116 is the ceiling" worry is retired.**

5. **NextZ80 is really executing, and it is worth 2.3x.**  Z80BENCH: **49.46 MHz
   equivalent, 1382 %** of a 3.58 MHz Z80.  The clock is unchanged at 21.477 MHz --
   1382 / 600 (T80s at the same 21.5 MHz, measured 20260913b) = **2.30x more work
   per clock**, which is the whole point of putting NextZ80 in as the R800.

6. *Expected, not a defect:* the same screen still reports `CPU Type: Z80`.
   R800 detection needs the R800-only opcodes (`MULUB`/`MULUW`), which are on the
   peer's later-work list and are not in NextZ80.  Worth confirming how Z80BENCH
   probes -- if it reads S1990 register 6 bit 5 instead, the bit is inverted
   somewhere and that IS a defect.

**Also tested on hardware (user, 20260918)**

- **FDD works**: Z80BENCH itself was loaded from floppy.
- **Akumajou Dracula played through to the end, in R800 mode** -- a PSG title, and
  a Konami one, i.e. exactly the class that a changed cycle count would derail first.
- **Hi no Tori is playable in R800 mode.**  Worth more than it looks: its RST 38
  runaway is a race between a long LDIR and the ISR being reinstalled, so it is the
  title most likely to notice that instructions now retire ~2.3x faster.  It did not.
- **No SCC regression.**  This is the one the SDC work most wanted confirmed: the
  SCC wave-RAM write is qualified by a NextZ80 strobe (covered by the broad `-end 2`
  only because nz_bus masks the first clock), and the peer's post-map triage left
  `T80s -> SCC falling edge` at -18.7 ns as a known negative carried over from the
  fitted 564901c.  Hardware says that negative is post-map pessimism, as assumed.
- The OSD screenshot shows both new rows rendered and set: `TURBO R FEATURES: ON`
  and `CPU (TURBO R): R800 (NEXTZ80)`, with `CPU SPEED: 21.5MHZ` -- direct visual
  proof for point 4 rather than inference from the S1990 answering.

**Closed by the same test**

7. `ce_cpu` runs at full rate while NextZ80 owns the bus (`MSX1.sv`: clock.sv speed
   `use_nz ? 4 : OSD speed`), and the PSG bus strobe, the M1-wait pair and the FDC
   all hang off it -- the one thing the bench could not cover.  **Akumajou Dracula
   was played through in R800 mode**, so a PSG title and the FDD both survive the
   full-rate `ce_cpu`.  Nothing left open here.

## 8. What "Turbo R features: On" actually changes (review, 20260918)

`en = status[117]`.  With it Off the block is inert -- no ports decoded, no BIOS
overlay, no mute -- so everything below applies only when the row is On.

**1. Four new I/O port groups appear**: E4h/E5h (S1990), E6h/E7h (timer),
A4h/A5h (PCM), A7h (pause/LEDs).  These are unused on MSX2+, so the collision
risk is low, but they are decoded from then on.

**2. `002Dh` reads back 03h on every machine**, MSX1 packs included.  That byte is
how software picks its generation.  An MSX1 or MSX2 pack claiming to be a turbo R
will be offered turbo-R code paths it cannot serve -- including BIOS entries that
do not exist in that ROM.  This is the widest-reaching effect of the option and it
is not gated by machine type.

**3. The `0180h-018Bh` overlay is NOT free space on every machine.**  Checked all
main BIOS ROMs in `releases/CreateMSXpack/ROM`:

| region at 0180h | ROMs |
|---|---|
| `FF`/`00` padding -- overlay is harmless | Panasonic FS-A1/mk2/F/FM/FX/WX/WSX, Sony, Sanyo, Mitsubishi, Philips, Canon V-20, all C-BIOS |
| **real jump entries** `00 00 00 / C3 69 14 / C3 06 10 / C3 12 10` | Daewoo `cpc-300_basic-bios2`, `330kbios`, `400sbios` |
| **real code** `01 C2 E1 01 D1 E5 CD 99 01 ...` | Canon `v-8_basic-bios1`, Sanyo `cf-2700_basic-bios1_german` |

On those five the overlay replaces live BIOS at 0183h/0186h/0189h (the Korean
machines' Hangul entries) or lands in the middle of code.  Packs affected:
**Daewoo CPC-300 / CPC-300E / CPC-400S** (400S is already marked `_notwork_`),
**Canon V-8**, **Sanyo CF-2700 (German)**.  Nothing breaks while the option is
Off, and none of these are turbo R machines, so the fix is to refuse the option
rather than to move the stubs: gate the overlay (and ideally the whole block) on
the loaded BIOS actually having `FF`/`00` there, or simply on the machine being
MSX2+.

**4. `A5h` bit 1 = 0 mutes the entire machine.**  `mute_all = en & muted_w &
~pcm_st[1]` zeroes `audio_l/r` outright (msx.sv:249).  It is openMSX-accurate and
needs a deliberate write, but with features On a stray write to A5h silences all
sound with no other symptom -- a silent-failure surface that does not exist with
the option Off.

**5. The Pause key becomes hardware pause** (A7h bit 1 + key state), on top of the
existing OSD pause.

Nothing here contradicts the hardware tests: those ran on a Panasonic-class pack,
which is in the harmless row of the table above.
