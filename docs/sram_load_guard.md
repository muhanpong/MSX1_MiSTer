# Letting the machine run before its .sav has arrived

Status: design and verification plan. No code change yet.

## 1. What is established

`nvram_backup` is asked to read the `.sav` as `memory_upload` leaves its FSM, which
is the edge `reset_rq` falls. `MSX1.sv` stretches the machine reset 63 clk21m past
that (`rst_hold`, 6 bits), so the machine is released **2.9 us** later.

The read itself is `lookup_SRAM[num].size << 1` sectors — 32 for an FS-A1ST's 16 kB,
64 for an FS-A1GT's 32 kB — each one a separate SD transaction through the HPS.
That is three to four orders of magnitude longer than 2.9 us.

So the machine runs for the whole of the load. Nothing stops it: `dma_active`, which
feeds `msx_pause` through `nvbak_dma_active` (`MSX1.sv:874`), covers the six
`STATE_FLASH_*` states only. Every non-ASCII16X cart and every machine's battery
SRAM goes through the BRAM path, which asserts nothing.

The BRAM is dual-ported: the machine writes through port A, the loader through
port B. A byte the loader has not reached yet loses to the machine; one it has
already written loses to the machine too, but later.

## 2. What is NOT established, and must be measured first

That the firmware **writes** the battery SRAM during those milliseconds. It is the
obvious reading — a machine that finds its SRAM unreadable initialises it, and the
result is then saved back over the user's data — but this document does not assume
it. Measuring it is step one of the plan below, and the measurement decides whether
the guard is a fix or a precaution.

## 3. The shape of the guard

Not a new reset condition. `msx_pause` already exists, already freezes every CPU
clock enable, and `nvbak_dma_active` is already one of its terms. The BRAM path is
simply missing from the signal behind it.

    dma_active = <the six flash states>            // today
    dma_active = <the six flash states> | <load in progress>

Four things decide whether that is right, and each is a decision rather than a
detail:

1. **The window starts at the REQUEST, not at the first sector.** With the pending
   logic added in 15f31ad, a request whose image is not mounted yet waits instead of
   being discarded. A guard keyed on the FSM being in `STATE_PROCESS` leaves that
   waiting period open, which is exactly the gap the firmware would initialise in.
2. **It must end when the LAST sector has landed**, not when the engine leaves
   `STATE_PROCESS` for an unrelated bank; the engine walks all four.
3. **A boot auto-load and the OSD's SRAM Load are not the same event.**
   `load_req` is `status[39] | load_sram` (`MSX1.sv:1432`), so the engine cannot
   tell them apart. Pausing a running machine because the user pressed SRAM Load is
   defensible; pausing it for up to the three-second pending timeout because no
   image is mounted is not. The guard should key off `load_sram`.
4. **`dma_save` must keep meaning SAVE.** It is `dma_active & wr`, and 9acf005 made
   the icon stop flashing on an auto-load. Widening `dma_active` widens what the
   icon sees; the `wr` term still holds, but this is the line to check.

## 4. Bounds, so the guard cannot become the bug

The pending timeout added in 15f31ad releases a request that can never be served
after about three seconds. The guard inherits that bound: the worst case is a
machine that starts three seconds late, not one that never starts. That bound is
part of the design, not a side effect, and the bench asserts it.

## 5. Verification

Three levels. Each states what it measures, and each has a mutation that must turn
it red — a test that passes against a broken build has already happened once in this
work and cost an afternoon.

**A. Module — `sim/tb_nvram_load_reset.sv`.** The busy signal rises on a boot
request and not on an OSD one; it stays high across the unmounted-image wait; it
falls on the last sector of the last bank; it falls on the timeout when the image
never arrives. Mutations: key it off the FSM state instead of the request, and key
it off `load_req` instead of `load_sram`.

**B. Whole machine — `sim/fullsys/tb_msx.sv`.** This is the measurement that decides
section 2. The bench now carries the save engine and an SD card behind it, so it can
count CPU writes that land in the SRAM window while the load is streaming.

    writes into the SRAM window, load in flight   before: ?   after: 0

A non-zero "before" is the defect, in numbers, on the machine that owns the SRAM.
Zero "before" would mean the firmware does not touch it that early and the guard is
a precaution — still worth having, and the plan does not change, but the commit
message should say so.

**C. The content check already in the bench.** Every byte the engine writes into
SRAM is compared against the byte the image held. With the machine running that
comparison is no longer trivially true: a mismatch is the corruption itself.

## 6. Order of work

1. Add the write counter to `tb_msx.sv` and run an FS-A1ST pack with a `.sav`.
   Record the number. Nothing is committed to RTL before this number exists.
2. Add the busy output to `nvram_backup`, on the request and off on completion.
3. Widen `dma_active`.
4. Re-run B; the counter must be zero. Re-run A with its mutations.
5. Confirm the 86-pack comparison and the whole-machine lint are unchanged.

## 7. Related

- `15f31ad` — a request that cannot be served yet is kept, with the three-second
  bound this design relies on.
- `11fc717` — a device may address only its own SRAM; the bound that keeps a
  mis-allocated pack from corrupting a neighbour.
- `save_guard.sv` — the opposite direction: a reset or a ROM load is deferred so it
  cannot land in the middle of a `.sav` WRITE. Nothing there concerns reads.
