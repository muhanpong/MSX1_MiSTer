# evt_trace — reading a hang off the board

`rtl/evt_trace.sv` records one 80-bit word per CPU EVENT into a 2048-word ring that
runs from configuration and wraps.  It is read over JTAG with the In-System Memory
Content Editor, the same mechanism as `vdp_regprobe` (MPRB) and `az80_trace` (CPUT).

## Use

    quartus_stp -t tools/dump_evtrace.tcl     # -> /tmp/evtrace_dump.txt (2048 words)
    python3 tools/parse_evtrace.py            # renders oldest -> newest

Do NOT reset the machine first: a reset re-arms the triggers, and while the ring
keeps its contents the marker then belongs to an older epoch.  Dump while it is
still hung.

## What is recorded

    INTA  interrupt acceptance (M1 + IORQ)      data = {ms_int_n, vdp_int_n}
    IOR   IN  from 98h-9Bh, A5h/A7h, C4h, D0h-D7h (FDC), FCh-FFh (mapper)
    IOW   OUT to  the same set plus A8h and E4h/E5h
    SUB   write to FFFFh (secondary slot register), SUBR a read of it
    BR    an opcode fetch whose address is not 1..4 past the previous one
    R38   an M1 fetch of 0038h, carrying the address fetched just before it
    SWAP  use_nz changed (Z80 <-> R800)
    IFF   IFF1 changed
    RST   machine reset

Every word carries PC, SP, the running core, IFF1 and both interrupt lines.

## Triggers

The ring freezes and writes a marker, so the dump keeps the ~2000 events BEFORE the
event rather than the flood after it:

  * eight RST 38h executions in a row with no acceptance between — a runaway
  * the same address fetched 64 times — a wedge

Without a trigger the ring holds only the last few milliseconds; a VRAM fill or a
runaway fills it in under 20 ms.

## Traps that have already cost a day

  * **A block instruction is not a wedge.**  LDIR re-fetches its own ED prefix once
    per byte.  Excluding by opcode byte does NOT work (ED B0 is two M1 fetches, so
    the last byte sampled at the repeat is B0); exclude by ADDRESS — a two-byte
    opcode fetches addr+1 between repeats.  `halt` must stay triggerable.
  * **The IOW/IOR event PC is one instruction ahead** of a disassembly: it is the
    PC after the instruction (042B reads as 042D).
  * **Count kinds by token, not column.**  Lines with a trailing note shift the
    columns; counting by column once reported "INTA 0" on a capture with 40.
  * **Sort by time before reading.**  A dump can span several boots; `RST` re-arms.
  * **A RAM value means nothing without A8** — the hook area reads FF whenever
    page 3 is not on RAM.

## Cost

~16 M10K and a few hundred ALMs (M10K 371 -> 387).  It is diagnostic only; take it
out of a release build.
