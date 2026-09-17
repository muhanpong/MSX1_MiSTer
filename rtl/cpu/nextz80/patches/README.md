# NextZ80 local patches

The three files in `../` stay byte-identical to the 2011 original (md5 table in
`../README.md`).  `../patched/` is what gets built; `check.sh` proves it equals
the originals plus these patches, in order.

| patch | what |
|---|---|
| `0001-cpuswap-state-load-export-swappt.patch` | runtime hand-over with T80s (`rtl/cpu/cpuswap/`) |
| `0002-ld-r-a-counts-its-own-fetch.patch` | accuracy fix: R lagged by one after `LD R,A` |

## 0001 — state load, state export, swap point

New ports on `NextZ80`:

| port | |
|---|---|
| `LOAD`, `LDIR[211:0]` | load the architectural state (T80 `REG`/`DIR` layout) and resume with an opcode fetch at its PC |
| `XREG[211:0]` | architectural state in the same layout, valid while `SWAPPT` |
| `SWAPPT` | registered: the last enabled edge ended an instruction cleanly |

**Why PC−1 and R−1.**  NextZ80 fetches the next opcode in the last stage of the
current instruction (the stage with `M1=1` that also samples interrupts).  After
that edge `pc` and `r` have already counted the fetch, and `FETCH` holds the new
opcode.  `XREG` winds both back, so the state is "between instructions, next
opcode not fetched" — the same point T80s reports (`T80.vhd`, "Swap point").  The
fetched opcode is simply fetched again by the next owner; a memory read has no
side effect on this bus.

**Swap point** = that fetch edge, and none of:
- a prefix is pending (`next_stage`, `fetch98`, `status[4]` = DD/FD);
- the stage changes IFF (`status[11]`: EI's one-instruction interrupt delay, DI, RETN);
- an NMI or INT is accepted on it;
- reset.

HALT (`M1=0`) and a repeating block instruction (`M1=0` between iterations) never
match, so a swap waits for the interrupt / the last iteration.

**Register file.**  `EXX`, `EX DE,HL` and `EX AF,AF'` do not copy anything here:
they toggle `CPUStatus[3:0]`, which redirects the slot a register name maps to
(slot map in `nextz80reg.v`).  `XREG` resolves the names through those bits; `LOAD`
writes the plain values into the unswapped slots and clears `CPUStatus[5:0]`.
Slots 3/4/11 take only the high byte (A, I, A'); their low byte is scratch.
Slot 13 must read zero and is never loaded.

**Interrupt samples.**  `SINT`/`SNMI`/`FNMI` only update on enabled edges, so they
are stale after a freeze; a stale `SINT` took an interrupt that was no longer
pending (seen in the bench as an ISR entered with INT low).  `LOAD` resamples them.

**Load resumes as a NOP at stage 0** (`FETCH=0`): its single stage is a plain fetch
at `pc` that also samples interrupts, which is exactly the resume point.

**IM encoding.**  NextZ80 `CPUStatus[9:8]`: `0x` IM0, `10` IM1, `11` IM2.
T80 `IStatus`: `00` IM0, `01` IM1, `10` IM2.

Not carried (neither core has a port for them): WZ/MEMPTR and Q.  They only affect
undocumented flag bits 3 and 5, and NextZ80 does not implement those like silicon
anyway (ZEXALL, `../README.md`).

## 0002 — LD R,A

`LD R,A` is one stage that writes R and also fetches the next opcode, so the
fetch's R increment was lost and R stayed one behind a real Z80 from then on
(`LD R,A; NOP; LD B,3; DJNZ $; LD A,R` read 06 instead of 07; T80s gives 07).
The write now adds the fetch (`M1`, which is 0 in the RESET stage that also writes R).
