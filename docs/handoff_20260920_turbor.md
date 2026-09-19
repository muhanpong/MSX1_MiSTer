# Handoff 20260920 — turbo R: four hardware fixes, BRAM reclaimed, three open

Branch `nextz80` in `.claude/worktrees/readcache`, **well ahead of origin/nextz80,
not pushed**.  Predecessors: `handoff_20260918_cpuswap.md` (the peer's narrative)
and `handoff_20260918_session.md` (§7 MULUB, §8 VDP spacing and the T80s decision).
Uncommitted files in this worktree that are NOT this session's:
`docs/aso_bgm_opl2_alias_20260915.md`, `holdfast.txt`, `rec.txt`, `research/` —
leave them, and `git add` by path.  Quartus rewrites `LAST_QUARTUS_VERSION` in
MSX1.qsf on every build here (17.1 vs the peer's 17.0): `git checkout -- MSX1.qsf`
after a build, never commit that line.

## 0. RBFs (all on the board, md5 verified by deploy.sh)

| RBF | md5 | Adds |
|---|---|---|
| `20260919a_r800clk` | baaabdc3fc59 | R800 speed ladder 7.16 / 21.5 |
| `20260919b_r800vdp` | 2c3934f5344d | VDP write spacing, fixed 10.1 us |
| `20260920a_sdwrvdp` | b300544613cc | spacing as an OSD dial (default 8.66 us), SD write pacing (first version) |
| `20260920b_prn90` | 482c27b63322 | printer status port 90h; SEED 7 |
| `20260920c_bramrecl` | 2c3ecf4879b6 | IKASCC wavetables to MLAB (**M10K 391 -> 371**), rz80's SD queue, FM 49515 Hz |
| `20260920d` | — | **build was launched from `67a7e1d` and its result was NOT checked** (user's instruction at handoff).  Log: scratchpad `build8.out`; nothing deployed |

`67a7e1d` contents (so whoever picks the build up knows what to verify): CPU Auto
(O[119:118]), the `I`-token settled-CPU popup, forensics following the live core,
the 0038h/CPU-mode watch rows, R#5/R#8 probes, and `syn_ramstyle` -> `ramstyle`.

Board assets: `games/MSX1/DSKS/{PCMTEST,MULUTEST,R800TIME}.dsk`;
`games/MSX1/MSX/Panasonic/Panasonic FS-A1GT*.MSX` and `FS-A1ST*.MSX` (peer's, real
turbo R BIOS so 002Dh really is 03; ST has no MIDI, which makes it the cleaner
test machine).  Test disks go in `DSKS/` only — do not invent directories.

## 1. Fixed and confirmed on hardware

1. **ASO's bands + Z80BENCH's lost characters = one bug, VDP write spacing.**
   Detail in the 0918 session handoff §8.  Board sweep of the dial: 7.5 us fails at
   the bottom, 8.66 us (default, the real machine's value) gives 0-1 bad lines,
   9-10 us also fine, 10.1 us gives 2-3 flashing lines.  Z80BENCH is clean at 8.66.
2. **MFRSD partition loss at speed.**  spi_divmmc drops `tx` exactly as it drops
   `rx`; SD commands are six back-to-back writes (Nextor MMCCMD: 13 clk21m apart
   at 21.5 MHz).  My WAIT-only fix (b34ab34) was hardware-confirmed and then
   REPLACED by rz80's `c49ad5f` (queue in mfrsd + hold for reads and writes; bench
   `sim/sdpace/run.sh`: old design 60 drops, new 0, stock fire train identical —
   reproduced here).  One integration change: `cpu_turbo` -> `cpu_paced`, because
   that commit predates the hand-over and would have left the R800 unpaced.
   **The queue version has not been re-tested on hardware** (it is in 20260920c).
3. **Printer status port 90h.**  Never decoded, so it read FFh = BUSY forever and
   BIOS LPTSTT (08E1: `IN A,(90h) / RRCA / RRCA / CCF / SBC A,A`) callers spun.
   Illusion City hung exactly there (board PC 08E4-08E7).  Now reads 00h, as
   openMSX does.  Rule that came out of the peer's port census: an undecoded port
   is only WRONG when the hardware is on the motherboard (90h, F3h-F7h); optional
   cartridges (C0h MSX-AUDIO, 80h RS-232C, B8h lightpen, E8h MIDI) read FFh on a
   real machine too and must stay that way.  F7h is read once by the turbo R BIOS
   and its real value is unknown (openMSX does not model it).
4. **R800 speed ladder + menumask 13/14** — hide (`H`) confirmed on hardware.

## 2. Open

**ASO shows no sprites at all** — on every CPU, clock and spacing tried, so it is
independent of everything fixed above; the broken band was masking it.  The real
R800 does show them (peer: forcing SPD wiped 26,652 px of enemy craft).  Reference
values at the end of the return block: **R#8 = 28h (2Ah only during the panel),
R#5 alternating BFh / B7h per frame (double-buffered attribute table), R#11 = 0**.
Our attribute-address masking and terminator logic check out in the RTL
(vdp_sprite.vhd:486, :537); SP_OFF is sampled once per line at DOTCOUNTERX=264
(:363).  `67a7e1d` puts R#5/R#8 on the debug panel (rows that used to be R#9/R#19)
— one ASO screenshot with the overlay on decides whether the registers or the
sprite engine is at fault.

**Illusion City.**  Past the 90h gate it still does not start (black screen, no
VDP write for 20 s).  The PC readings I reported after that (0039, spin FFFF) are
NOT trustworthy: every dbg_* PC/SP/spin tap read T80s' register file, which is a
frozen snapshot whenever NextZ80 has the bus, and this game settles in R800-ROM
mode about 12 s in (peer's measured timeline: CHGCPU 01/00/.../81, game ISR
`C3 CD E6` written to 0038h at t~7-12 s).  `67a7e1d` fixes the taps and adds the
0038h bytes + CPU mode to the panel (rows 11/12: `{use_nz,r800,dram,00000,m38}` and
`{m39,m3A}`; 3C0C = BIOS ISR, CDE6 = game ISR).  Also relevant: until `67a7e1d`
the OSD **forced R800 at every boot** because the saved .CFG has bit 118 set;
with a GT/ST pack that pre-empts the BIOS' own sequence.  First test on the new
build: ST pack, CPU = Auto.

**Global reset is combinational out of an hps_io status bit** (MSX1.sv:
`reset = RESET | reset_now | (reset_rq & ~status[64])`), so recovery is timed from
the HPS register through the whole reset tree.  SEED 6 missed by -0.255 ns on
`status[64] -> u_pcm ram_regs[2].d1r[0]`; SEED 7 passes (+1.24 / +2.84).  The real
fix is a synchroniser on `reset`; it touches a global, so it needs the consumer
survey the timing-change protocol asks for.  Not started.

**Not done / parked:** PCMPLY still never called on hardware (PCMTEST.dsk is the
program); `002Dh` gating (GT/ST packs make the forced byte unnecessary — decide
whether to gate or drop); MOONSOUND_DIAG off (`301a68e` on rz80 — wait until the
two investigations above stop needing the overlay); T80s VDP tuning (decided
against, 0918 session §8.1); R800 throughput rung ~575% (superseded — the band
needed spacing, not throughput).

## 3. Block RAM / ALM

M10K 371/553 (67%), ALM 32,688 (78%) on 20260920c — **ALM is now the binding
resource**, the reverse of the June study's premise (ALM 64% / M10K 95%).

- Recovered: IKASCC wavetables, `(* ramstyle = "MLAB" *)`, 20 M10K for 200 ALM.
- `4790c6b` (PCM header/dyn -> MLAB) did NOTHING in 20260920c: the attribute was
  `syn_ramstyle`, Synplify's spelling, which Quartus ignores without a warning
  (u_pcm: 0 ALMs for memory, 7,505 registers).  Fixed in `67a7e1d`; judge it by the
  u_pcm register count and "ALMs used for memory" in that build's fit.rpt.
- Remaining clean candidates: `vdp_regprobe` 10 M10K (debug only), `systemRAM`
  64 -> 32 KB = 32 M10K (gives up the no-SDRAM fallback).  The small OPL3/IKAOPLL
  RAMs (32 M10K, all "Fits in MLABs = Yes") can move with two wildcard
  `RAM_BLOCK_TYPE MLAB` qsf assignments for ~0.8 %p ALM — not applied.
- VRAM (128 M10K) stays in BRAM: the VDP assumes single-cycle VRAM and this year's
  timing work stands on that.
- PCM ALM passes, re-ranked for today's resources (June study §1): 1a header/dyn
  MLAB (in flight), **2** dead `calc_vol` + `byte_addr` x6 -> x2 + `eg_rate_shift_rom`
  x3 CSE (all verified still unapplied; bit-exact, no risk), **1b** cache tags +
  vld/hasb into the existing cache RAM (rated easy: one read site, one write site).
  **1c `ram_regs` stays in flops** — checked in the RTL, not just taken from the
  study: up to four independent read indices in one cycle (`ld_slot`, `hf_pick`,
  `wr_snum`, `hf_cur_slot`), two same-cycle RMW writers with a combinational
  forward between them (`wr_snum == hf_cur_slot`), field-wise partial updates from
  an asynchronous CPU bus, a 24-way simultaneous `keyon` tap, and a broadcast clear.

## 4. Reference numbers

`R800TIME.COM`, us/op — real R800 (openMSX FS-A1GT) / ours 7.16 rung / ours 21.5:
NOP 0.160 / 0.138 / 0.096; `LD A,(BC)` same page 0.660 / 0.279 / 0.191; page cross
(cache thrash) 1.167 / 0.838 / 0.612; `OUT (A0h)` 1.649 / 0.564 / 0.555;
`DJNZ $` 0.441 / 0.240 / 0.163.  Faster on every path but by 1.16x-2.93x, so the
profile is flatter than a real R800's; `OUT` does not follow CPU speed (bus guard).
A real turbo R spends 8.66 us per `LD A,n / OUT (99h),A` — the VDP wait.

Z80BENCH 1.4.2: real R800 575% ("20.59 MHz" is Z80-equivalent throughput, not a
clock); ours 921% / 1381%; T80s 600% at 21.48 MHz.  R800 detection = MULUB flags at
1E26h only.  MULUTEST on the real R800: 9/9, F = 00/01/40/01/00 for the five MULUB
cases (`01*00` must give Z), MULUW DE = high word.  PCMPLY rates 1 : 1.98 : 2.98 :
3.97; the real BIOS plays the VRAM variant, ours returns at once.

MiSTer firmware source is at
`/run/media/muhanpong/0eb4bebc-…/MiSTer_build/Main_MiSTer/` (READ ONLY).  Verified
there: `I,msg1,msg2;` token at CONF_STR index >= 2, core pulses `info_req` with a
1-based `info`, hps_io clears it on the read (`'h36`).

## 5. Pitfalls from this session

- **Search the other branches before building anything.**  I rebuilt the SD write
  pacing from scratch while `c49ad5f` — better, and benched — sat on `rz80`, and
  memory had the pointer.  `rz80` also held the IKASCC and PCM MLAB commits.
- **BDOS destroys HL.**  PCMTEST's `putc` did not save it, `hex16` printed a
  corrupted low byte, and that read as "openMSX's E6h low byte is stuck".  It is
  not; the peer's debugger dump cleared it.  R800TIME was always correct.
- **Forensic taps must follow the running core** (see Illusion City above).
- **`syn_ramstyle` is silently ignored by Quartus.**  Judge RAM inference by the
  fit report, never by the attribute being present.
- **The pause symbol in a screenshot proves nothing** (screenshots pause the core).
- The debug panel decodes from a PNG: 39 rows, anchors `ab_pc=042A`, `ppi_ctl=8102`.
  Run the decoder from a directory that has no `dis.py` in it.
- An intermittent fault hands you a passing run (SCMD, 0918 session §7).
