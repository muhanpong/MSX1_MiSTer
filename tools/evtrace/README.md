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
    LOOP  a folded loop, ending here: its address and its repeat count

Every word carries PC, SP, the running core, IFF1 and both interrupt lines.

## Loops are folded

After 8 fetches of one branch target the recorder stops storing that loop — the
repeats AND the port traffic inside it — and only counts.  When another branch
target or an interrupt breaks it, one `LOOP` word goes in with the address and the
count.  2000 LDIR iterations cost 11 ring words instead of 2000, so the ring spans
seconds of control flow instead of milliseconds.

The cost: inside a folded loop, `IOR`/`IOW`/`SUB` are not stored.  A sector
transfer or a VRAM fill shows as one `LOOP` word, not as its bytes.

## Triggers

The ring freezes and writes a marker, so the dump keeps the ~2000 events BEFORE the
event rather than the flood after it:

  * eight RST 38h executions in a row with no acceptance between — a runaway
  * one branch target held, unbroken, for ~2 seconds — a wedge

The wedge trigger is TIME, never a repeat count: see the traps below.  Once it
fires the loop unfolds, so the last 64 words of the dump are the wedge itself.

Without a trigger the ring still wraps, but folding makes that far less likely to
matter — dumping a hung board without a trigger is now usually worth doing.

## Traps that have already cost a day

  * **A repeat count cannot find a wedge.**  Two builds died on this.  A block
    instruction is not a wedge: LDIR re-fetches its own ED prefix once per byte, so
    on the address bus it is `jr $`, and an opcode-byte test fails too (ED B0 is
    two M1 fetches — the byte sampled at the repeat is B0).  Excluding by ADDRESS
    fixed that, and the next capture froze on the turbo R BIOS **RAM-size search at
    7D60** — one address fetched **28672 times in a row over 545 ms**, making
    perfect progress (`LD A,(HL)/CPL/LD (HL),A/CP (HL)/CPL/LD (HL),A/JR NZ/INC L/
    JR NZ`, 68 T-states = 19.0 us, which is what the dump measured).  The only
    test that works is TIME: no legal loop holds one target for seconds (that
    search is the longest known at 545 ms; a full 64 KB LDIR is 440 ms), a wedge
    holds it forever.  `halt` with interrupts off is caught by the same rule.
  * **The IOW/IOR event PC is one instruction ahead** of a disassembly: it is the
    PC after the instruction (042B reads as 042D).
  * **Count kinds by token, not column.**  Lines with a trailing note shift the
    columns; counting by column once reported "INTA 0" on a capture with 40.
  * **Sort by time before reading.**  A dump can span several boots; `RST` re-arms.
  * **A RAM value means nothing without A8** — the hook area reads FF whenever
    page 3 is not on RAM.

## Bench

    verilator --binary -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
      -Wno-UNDRIVEN --top-module tb -o tbevt tools/evtrace/tb_evt.sv rtl/evt_trace.sv
    ./obj_dir/tbevt          # ~20 s, the wedge case really waits out its 2 s

`tools/evtrace/tb_evt.sv` carries its own altsyncram stub, which prints every ring
write in order — so the transcript IS the dump.  Six cases:
distinct branches, an RST 38 storm and its re-arm on reset, a 2000-iteration LDIR,
the 30000-repeat RAM search (must NOT trigger), a polling loop whose INs must fold,
and a `jr $` wedge (must trigger at ~2 s, +64 words, marker).  Run it before
believing any change to the trigger — both wrong triggers would have been caught
here in 20 seconds instead of two board sessions.

## Cost

~16 M10K and a few hundred ALMs (M10K 371 -> 387).  It is diagnostic only; take it
out of a release build.
