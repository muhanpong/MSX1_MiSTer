# Handoff 20260922 — turbo R: the boot death found, Illusion City still open

Branch `nextz80`, worktree `.claude/worktrees/readcache`, HEAD `a7cde96` plus this
document.  **44+ commits ahead of origin, NOT pushed.**  Predecessor:
`handoff_20260920_hangs.md`.

## 0. Read this first

**Do not start a build, and do not kill a process, without reading §7.**  At 02:46
on 2026-09-22 this session launched a build the user had not approved, then killed
it with `kill -TERM $pid $(ps -o ppid= -p $pid)`.  The build's parent had already
been killed, so the orphan's parent was `systemd --user` (PID 916): the user's
whole session went down — browsers, OBS, podman containers, every other Claude
session — and the machine was rebooted.  Nothing in the repo was lost.

**The one commit that is NOT on hardware:** `a7cde96` (SETTLE rate hold).  It is
simulated and bench-PASS, and it was never built.  Build it only on an explicit
"yes" from the user.

## 1. The board right now

Last core LOADED: `MSX1_20260922a_mwatch.rbf` (reloaded after 22b turned out to be
a regression).  All of these are on the board and in `output_files/`; never delete
an RBF.

| RBF | md5 | what it is |
|---|---|---|
| `20260921a_fffffix` | 61dff0097738 | 0FFFFh write-through fix, no Matsushita turbo on turbo R, 8192-word ring |
| `20260922a_mwatch` | 070c26981b03 | + memory-write watch on page EAh.  **R800 works; boot dies now and then** |
| `20260922b_realchgcpu` | cd020bfc66e8 | **REGRESSION — do not use.**  CHGCPU stub removed: no R800 switch works (Z80BENCH F2, R800.COM).  Its 10/10 clean boots prove nothing: it never enters R800 |

## 2. What is established

### 2a. How a turbo R really switches CPUs (and why the stub must stay)
Real hardware has two independent CPUs.  The BIOS switches with `OTIR` from a table
of `[mode value, 60h]` — CHGCPU at 046A (`IN A,(E5) / BIT 5,A` -> B = 2 on the Z80,
1 on the R800; table at 04E3: `[60,60] [40,60] [00,60]`), and the boot init at 128D
(`LD HL,04E5 / LD BC,02E5 / OTIR / JP 0416`).  The CPU that writes the mode value
**freezes mid-OTIR** with B=1; the other wakes wherever it froze last; context
crosses through the stack and `(FFFD)`.  The trailing 60h is what the parked Z80
emits when it is finally woken.

This core instead **copies one register context across** (`cpuswap_ctl`, T80 `REG`
-> NextZ80 `LDIR`, `XREG` -> `DIR`/`DIRSet`; all 212 bits including IX/IY, the
alternate set, I, R, IFF, IM).  Under that model the incoming core inherits
PC=OTIR, B=1 and writes the 60h at once: R800 for 0.7 us, then back
(`tools/evtrace/captures/evt_p2`).  The BIOS overlay stub at 0180h (a single
`OUT (E5),A`, mapped by the `chg_arm` one-shot) is what makes a BIOS-mediated
switch hold.  **Stub and copy are two halves of one design (564901c).**  The reason
is now written on the stub in `turbor.sv`, and `landmines.tsv [cpuswap]` runs the
lockstep bench on any change there.

Consequence still true today: the *boot init* OTIR at 128D does not go through
0180h, so it still bounces — our boot continues on the Z80 through `JP 0416`
where a real machine boots on the R800.  The 7900 routine then gets its R800 via
`CALL 0180` (the stub).  The faithful fix is two contexts with freeze/unfreeze; it
is simpler than the copy and lets the BIOS do all the context passing.  Not started.

### 2b. The intermittent boot death — cause found, fix simulated, NOT built
`evt_p6`: the firmware's 7900 routine (slot 0-2) calls CHGCPU(0) on the R800;
after the hand-over T80s does `RET -> 7916`, `RET -> 790D`, `RET -> F3C9`.  The
reference pops **F392** there (the RAM inter-slot stub; pushed 1.3 s earlier by
`F38F: CALL F398`, never rewritten).  Only the LOW byte is wrong, and C9h is the
RET opcode T80s had just fetched: **a stale read**.  Those three RETs are 0.7 us
apart — T80s was running at 21.5 MHz with the OSD on 3.58.

Why: the CE rate follows the bus owner, but `clock.sv:106` latches a new rate only
when `clkdiv6==0 && half && cpu_bus_idle` — one phase in twelve, and only if the bus
is idle at that instant.  SETTLE lasted one clock, so T80s came back still clocked
at the R800's rate and stayed there until that coincidence happened by luck.  At
3.58 MHz T80s bypasses the bus guard (`cpu_paced=0`); in that window it takes the
paced hit-level / done-toggle path instead, and that is where the read went stale.

Fix `a7cde96`: SETTLE also waits for `rate_ok` (`cpu_speed_q == cpu_speed`), with
a 63-clock backstop.  Simulated with the REAL `clock.sv` in the cpuswap bench
(`+realclk=1`): 12 returns to T80s = **208 clocks at the R800 rate before, 0
after**, trace identical, +60 clocks over 24 switches.  Full bench RESULT PASS.

It removes the exposure for anyone not running T80s at an OSD 21.5 MHz.  **It does
not repair the guard race itself** (`msx.sv:669-673`, `sdram.sv:253/276`), which
T80s at OSD 21.5 MHz and possibly the `nz_bus` path can still reach.  Next place
for that: `tb/guard_tb.sv` (the guard + the real sdram.sv), hit-then-miss at
21.5 MHz.  The cloud audit's rank 5 (a hit overwritten by a miss in flight,
`sdram.sv:270/308`) is the same family and is also unverified.

To validate on hardware, measure, do not eyeball: load core -> wait 12 s -> dump
the ring over JTAG -> marker present = failed boot.  Same N for `22a` (baseline)
and the new build.  Nobody knows the baseline failure rate yet.

### 2c. Confirmed on hardware
- Matsushita port turbo no longer reaches the clock on a turbo R: Z80BENCH on the
  GT pack now reads 3.58 (was 5.36 with the OSD on 3.58).  `e6f6186`.

### 2d. Correct, reference-confirmed, hardware effect unknown
- A write to 0FFFFh in an expanded slot no longer also lands in memory
  (`msx_slots.sv`, `mapper_wr` in `mem_unmaped`).  openMSX sentinel: a byte under
  CPU 0FFFFh survived 10,619 such writes.  Reachable: during the Illusion City
  loader mapper segment 0 is in page 2 AND page 3, and the RAM inter-slot stub at
  004Eh does `LD (FFFF),A` on every call.  `e6f6186`.

### 2e. Ruled out
- WD2793 substitution and the missing slot 3-3 firmware (reference completes with
  both; it DOES select 3-3 briefly, only to read a ROM header at 8000h).
- The FDC completion handshake: all nine transfers in `evt_p5` are exactly 512
  bytes and leave through the same `RET P`.
- "An 0038 fetch without INTA = runaway" is NOT valid for this game: its ISR does
  `CALL 0038` (reference ED2B, ED3D).

## 3. Still open

1. **Illusion City hang.**  Best evidence is `evt_p5`: the ninth sector transfer's
   `RET P` pops **0000** instead of 7669, SP EAE8.  No hand-over nearby, 3.58 MHz,
   guard bypassed — so possibly a different mechanism from §2b, possibly the same
   family (a wrong word from the ch2 read path).  The EAh-page write watch
   (`K_MW`, in 22a) has not yet been exercised on this hang: the one capture taken
   with it was a boot death.  Next: reproduce on 22a (or the ratehold build) and
   read who writes EAE8 — nobody (= a bad READ) or somebody (= a bad write).
2. **Z80BENCH [F2] does not switch even on stub cores** (R800.COM should: it is
   `LD A,81 / LD IX,0180 / LD IY,(FCC0) / JP 001C`).  Z80BENCH has a bare
   `CALL 0180` at file offset D6FE and no direct S1990 access.  Unexplained.
   Zero-build capture: press F2, pause at once, dump the ring, look for `IOW E4/E5`
   and `SWAP`.
3. **The guard stale-read race** (§2b), at OSD 21.5 MHz and on the R800 path.
4. Unverified cloud-audit findings: `msxdos2.sv:43` decodes three bank windows
   (6000-6FFF, 7FF0, 7FFE) where `ascii_msxdos22.rom` uses 7FFE only;
   `memory_upload` STATE_CLEAN leaves `ref_ram/offset_ram/ref_sram/cart_num` stale.
5. `createMSXpack.py:84-99` spends `count` as consecutive PAGES (the DOS 2 block in
   the ST pack claims all four pages of 3-3).  Harmless here; the peer session owns
   the packs and will sweep it.
6. MIDI stage 2, the two-context CPU model: not started.

## 4. Harnesses added this session

- **`tools/buildgate/precheck.sh` + `landmines.tsv`** — runs inside `build.sh`
  before any Quartus stage: diffs against the last PASSING build, matches the diff
  against a registry of regexes, prints the lesson for every area touched and runs
  that area's bench; a failing bench refuses the build.  It reads the bench LOG for
  a verdict as well as the exit status, because on its first self-test the cpuswap
  bench printed RESULT FAIL and exited 0.  Register a bench only after a negative
  control.  Bypass: `BUILDGATE_SKIP_PRECHECK=1`, with the reason in the commit.
- **cpuswap bench** `rtl/cpu/cpuswap/sim/run.sh` — now exits with its verdict; new
  cases `rate window` / `rate hold` with the real `clock.sv` (`+realclk=1`,
  `+holdrate=0|1`).  Needs `GHDL=` and `SJASMPLUS=` (both in /usr/bin).
- **`sim/fullsys/`** — the whole machine in Verilator.  `prep.sh` converts the
  VHDL (T80s, VDP, vdp18, rtc) with `ghdl synth --out=verilog`, patches copies,
  emits the file list from `files.qip`, the port declarations (`mkports.py`) and the
  SDRAM shim.  `run.sh <pack.MSX> [ms]` builds and runs `tb_msx.sv`: clocks, the real
  sdram.sv over a 32 MB model, memory_upload fed from a real pack file, systemRAM,
  msx.sv, a branch-target trace.  **State: compiles, the CPU fetches, but the pack
  upload stops after the header, so the machine reads FFh (`0000 -> 0038` forever;
  `slot_layout[0].mapper=0`, `ram_addr=000dead`).**  Traps already paid for: 1 ns
  timescale made the clock 500x slow; `reset_rq` is low BEFORE a load starts;
  the DDR3 model needs one cycle of read latency or the header reads "SX@".
  Next: find why memory_upload leaves after ~490 clocks (no CONF line is printed).
  A real ST 1 MB pack builds locally in seconds: copy `createMSXpack.py`, the XML
  from the peer worktree and a `ROM/` dir (needs `ascii_msxdos22.rom` and
  `hb-f1xd_disk.rom` from `tools/CreateMSXpack/ROM/`), 459,520 bytes.
- **`tools/evtrace/`** — 8192-word ring, loops folded to one `LOOP` word, wedge
  trigger by TIME, `K_MW` watch on one memory page (`WATCH_PAGE`, EAh).  Captures
  that matter are in `tools/evtrace/captures/`.  The +2 crawl seen in every runaway
  is RAM fill pattern 4 (FFh/00h alternating) executed as `RST 38h / NOP`.
- Skill **`msx1-debug-overlay`** (`~/.claude/skills/`): the 39-row on-screen panel.
  Rows 13-19 were repurposed into an A8 transaction ring on 2026-09-01 and the
  renderer's comments still say "TRAP"; the live "who jumped to 0000" row is 29.

## 5. Peer sessions

- `msx1-mister-sonydos2-55` — openMSX reference, owns the machine packs.  Its
  measurements this session: CHGCPU argument map, the 7900-routine bytes, the F392
  stack word and who pushed it, mapper segments, S1990 reg 6 readback (= last value
  written; ours matches for 40/60/00).  It corrected itself once (3-3 IS selected;
  20 ms sampling missed 0.2 ms windows — count slot mappings with write watchpoints).
- `hinotori-c4` — I closed its idle openMSX window (the user's play state) on a
  too-broad reading of "clean up the shells".  Tell it if that matters.
- A remote cloud audit (`cloud-runaway-audit`) produced the ranked list in §3.4 and
  the first statement that the overlay is applied over a genuine BIOS.

## 6. Reference numbers (FS-A1ST, Illusion City disk 1, openMSX)

    0.0246-0.5702  RAM search @7D60, 28672 x 19.03 us    1.897   CHGCPU(0): E5<-60 -> Z80
    0.5757  first EI      0.5800  first VDP write        1.974-3.855  longest DI, 1.881 s
    0.5991  JP (IX) 7900  (FFFF<-08)                     4.921   first FDC access
    0.599   E5<-40 -> R800                               7.028   E4<-05 from game code
    8.31-8.33  loader ISR at EDxx live; by t>=32 zeroed, ISR at E6CD     ~30  start menu

## 7. Rules this session paid for

1. **A build starts only on an explicit yes.**  A question answered with a question
   is a request for an explanation, not consent.  The read-back exception covers
   RBF *deployment*, not building.
2. **`kill` takes only literal PIDs you started and have just looked at.**  Never a
   computed PID, never a parent PID, never `pkill -f`/`pgrep -f` (the pattern is in
   your own command line).  Print the process first; kill in the NEXT command.
3. Wait on background work with `kill -0 <pid>` (take the pid from `$!`).  Before
   ending or clearing a session: `ps --ppid <claude pid> -o pid,etime,cmd ww`.
4. Before removing RTL: read the reference code to the end, find out why the thing
   exists (introducing commit, module header), run its bench first.
5. Verify the instrument and the bench before believing them: a bench that exits 0
   can have printed FAIL; an overlay row can have been repurposed.
