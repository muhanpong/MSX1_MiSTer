# turbo R features (branch `cpuswap`)

OSD `Turbo R features` (status bit 117, default Off; the bit was never assigned, so
old `.CFG` files read Off).  With it Off nothing here decodes, overlays or mutes.

Requested 2026-09-18: force the turbo R BIOS entries 0180h–018Bh and the version
byte 002Dh, add the PCM, the E6h timer and the pause key; no firmware ROM; LEDs not
shown on the board for now (an OSD overlay LED comes later); PCMPLY/PCMREC as a
hardware player.

Register behaviour follows openMSX (`MSXS1990.cc`, `MSXE6Timer.cc`,
`sound/MSXTurboRPCM.cc`, `MSXTurboRPause.cc`); BIOS entry definitions follow the
MSX BIOS reference (map.grauw.nl `msxbios.php`).

## What is in `turbor.sv`

| port / address | |
|---|---|
| E4h / E5h | S1990 register select / data.  Reg 6: bit 5 = 1 Z80, 0 R800; bit 6 = 1 ROM, 0 DRAM mode.  60h after reset.  Reg 5 reads 00h, 13/14/15 read 03h/2Fh/8Bh, others FFh. |
| E6h / E7h | 16-bit up-counter at 3.579545 MHz / 14; any write clears it without moving the tick grid |
| A4h | read: 2-bit counter at 3.579545 MHz / 228 (15.7 kHz); write: D/A value, clears the counter |
| A5h | BUFF / MUTE / FILT / SEL / SMPL; read bit 7 = comparator.  MUTE=0 silences **all** sound, but only after A5h has been written (an MSX2+ BIOS never does) |
| A7h | read bit 0 = pause key state (each Pause press toggles); write bit 0 pause LED, bit 1 hardware pause enable, bit 7 turbo LED.  Hardware pause = bit 1 and key → `msx_pause` |
| 002Dh (slot 0-0) | 03h |
| 0180h CHGCPU | `D3 E5 C9` — the fetch arms a one-shot so this `OUT (E5h),A` takes the BIOS format (A = LED 0 0 0 0 0 m m) |
| 0183h GETCPU | `DB E5 C9` — the fetch arms a one-shot so this `IN A,(E5h)` returns 0/1/2 |
| 0186h PCMPLY | `B7 C9 00` — **stub**: returns, carry clear |
| 0189h PCMREC | `B7 C9 00` — **stub**: returns, carry clear |

The overlay applies only while the access decodes to slot 0-0 page 0
(`msx_slots.main_rom0`), where every MSX keeps its main BIOS.  The stub bytes are
always there, so an interrupt between `OUT` and `RET` returns into the stub.

Pause key: `hps_io` reports it as `ps2_key[9:0] = 377h`, press only (no release).

The CPU selection is stored and read back; on this tree nothing switches the CPU
yet — that is the T80s ⇄ NextZ80 hand-over (`rtl/cpu/cpuswap`).  Consequence: after
`CHGCPU` to R800 the machine keeps running on the current core while `GETCPU` says R800.

## Verified in simulation

`rtl/cpu/cpuswap/sim/run.sh` runs the block against both CPUs (T80s alone, NextZ80
alone, random and every-point hand-overs, software switching).  The program checks,
through RAM writes compared across all runs: 002Dh = 03h; GETCPU = 2/0/1 after a bare
`OUT (E5h)` and `CHGCPU` 0 and 81h; register 6 = 00h/60h/40h; A7h reads the key, not
the LEDs; timer cleared by a write (E7h = 00h) and counting; PCM comparator
82h/82h/02h against 80h/7Fh/81h, counter cleared by the write, BUFF value landing on a
tick (`D 55`) and immediately when BUFF drops (`D 66`), hold (92h), the all-sound mute
(`M 1` / `M 0`); and a hardware pause held 3000 clocks with the bus frozen, the key
pressed twice (A7h = 00h after).

## Hardware PCMPLY player — design, not built

PCMPLY: A = v 0 0 0 0 0 q q (v: VRAM; q: rate 15.75 / 7.875 / 5.25 / 3.9375 kHz),
HL = start, BC = length, D/E bit 0 = bit 17 of length/start for VRAM; carry out =
aborted by CTRL+STOP; all registers destroyed.

1. **Parameters from the CPU state.**  The fetch of 0186h is an instruction boundary:
   T80s `SWAPPT` / NextZ80 `SWAPPT` with PC = 0186h, and `REG` / `XREG` hold A, HL,
   BC, D, E exactly (the machinery the hand-over already uses).  A-Z80 has no such
   export, so **the player needs T80s + NextZ80 owning the bus** — it comes after
   the core rework.
2. **CPU parked.**  The stub becomes `IN A,(port) / RET`; WAIT is held on that I/O
   cycle for the whole playback (a real turbo R plays with interrupts off too).
3. **Bus master.**  While the CPU is parked, the player drives address/MREQ/RD into
   the slot system in place of the CPU (a third input to the bus mux in `msx.sv`),
   one read per sample, paced like a slow CPU read so the SDRAM request/ready
   handshake is unchanged; the byte goes to the D/A on the PCM tick grid divided by
   q+1.  VRAM (v = 1): read the VDP's VRAM directly, not through ports 98h/99h (that
   would move the VDP address register the program owns).
4. **Abort and carry.**  CTRL (row 6 bit 1) + STOP (row 7 bit 4) from the keyboard
   matrix stop playback.  After the `IN` completes, the next boundary (fetch of the
   `RET`) reloads the same core with F's carry set or cleared — a self-transfer
   through `DIRSet` / `LOAD`.
5. PCMREC: there is no audio input.  Proposed: same bus master writing 80h
   (silence), or the tape ADC if one is wanted.
