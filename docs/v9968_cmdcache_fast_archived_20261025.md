# V9968 command cache "Fast" — archived, not merged (2026-10-25)

Branch `archive/v9968_cmdcache_fast` (commit 05be115, on top of 937950a). Local only.
Decision (user, 2026-10-25): put on hold; keep the work and this record.

## Why it was tried

Geo3D frame time on this core is ×1.146 of upstream's ideal-memory bench (`sim/geo3d_perf`,
texdemo 130 RUNs, mean 2.896 ms vs 2.530). `brk_probe` split the excess exactly into read
latency (10 clk grant→data vs 1, 57 %) and waiting for the next h=1/9 access slot (43 %); both
come from the V9968's own VRAM rules and the 8-clock SDRAM contract, so the real HRA cartridge
is probably as slow (not measured).

## What it does

OSD "VDP command cache: Original / Fast" (V9968 build, `status[59]` — the only unused bit, may
hold a stale 1 in old MSX1.CFG files). Original = today's RTL, bit- and cycle-identical.
Fast:
- next-word prefetch with up to two reads in flight (the VRAM interface already answers two in
  order, `vdp_vram_interface.v:269-300`), withdrawn when a demand access needs the port;
- no destination fetch for IMP writes in 4/8 bpp: per-nibble valid bits; a half-valid byte is
  filled and merged in the background or at write-back; any other read of an invalid nibble
  fetches first.

## Results

| | Max | Mean | vs ideal |
|---|---|---|---|
| Original | 3.533 ms | 2.896 ms | ×1.146 |
| prefetch only (v2) | 3.338 | 2.748 | ×1.087 |
| Fast (v2 + no-fetch) | 3.272 | 2.684 | ×1.061 |

V9938-reference commands with HS on: LMMM/LRMM 256×212 11.665 → 10.119 ms. Normal speed is also
affected (Go Figure HMMM 12.224 → 12.118 ms), so it cannot ride on the HS bit.

Gate `sim/v9968_vram/run_cmdcache.sh`: PASS. Original equals the pre-change RTL exactly (fuzz
screens 5–8, HS on/off, with/without CPU traffic, LMCM, command timings, texdemo times and
hashes). Fast: VRAM and S#2/S#7–S#9 identical on 20 fuzz runs without CPU traffic and on all
130 texdemo hashes. Mutants (a) half-valid write-back without merge 10/20, (b) half-valid read
hit without fetch 2/20 (weakest), (c) no-fetch for every logical op 16/20, (d) prefetch landing
over written bytes 18/20.

CPU write racing a command on the same byte (150 trials): Original loses the CPU's nibble once,
Fast never (openMSX does each pixel's read-modify-write at one instant, VDPCmdEngine.cc:180-181).
With general CPU traffic Fast's results depend on ordering (timing) — reported, not judged.

VPROBE, `sim/v9968_vram/run.sh`, `run_irq.sh`: PASS (Original).

## Why it was not merged

- Map estimate +1,170 ALM (34,737 → 35,907): `vdp_command_cache` combinational ALUTs 720 → 2,742
  (parallel tag compares, nibble-merge muxes). Estimated before: +300–550.
- clk_vdp worst slack in recent fits is +0.076 ns; the new logic sits on clk_vdp.
- Demo-level gain is small: the Geo3D demos are CPU-bound (openMSX: Geo3D drain ≤ 15 % of a frame),
  so ~5 % less command-engine time is about 1 % in fps. The R800 port-wait fix (9d60b3c) gave the
  visible speed-up.

## Not done

Fit/timing, Fast under fullsys/VPROBE, LMMC in the fuzz, board. If resumed: shrink the cache
logic first (serial tag compare, narrower merge), then map → seed sweep. A further lever, a
posted flush (CE falling before the last writes land), changes CE semantics and was not tried.
Scratch: /data/_claude/tmp/msx1-handoff/g3cache/ (gate5 output, map before/after copies).
