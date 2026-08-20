# TODO — someday / low priority

Things that are real but that nobody is waiting on. Kept out of the active TODO
files so they do not dilute them. Each entry should say *why* it is parked, so a
future reader can tell whether the reason still holds.

---

## Yamanooto: ECHO and the HOME-key boot

**Parked because:** on current firmware, software cannot reach this feature at all,
and implementing either half alone buys nothing.

ECHO (CFGR bit1) makes the cartridge PSG *also* answer the internal PSG's ports
0xA0/0xA1, so music written for the internal PSG is doubled through the
cartridge's stereo output. The manual's stated purpose is to work around machines
whose internal PSG is badly balanced against the SCC.

Two facts from the 15oct2024 hardware reference decide this:

* the prose reads *"This is **set only** during boot when you press the HOME key"*
  (the 7dec2023 revision said "automatically set during boot" — it was tightened);
* the CFGR bit table marks ECHO **`RC`**, alone among CFGR bits, where SUBOFF, K4,
  ROMDIS and MDIS are all `RW`.

Read together: **software can read and clear ECHO but cannot set it.** The only
path to ECHO on real hardware is a HOME-key boot, which this core does not model.
So today ECHO can only ever be 0 here, and our not implementing the port aliasing
accidentally matches a non-HOME boot exactly.

Consequences of that, both directions:

* Nothing observable is lost right now. No program can set the bit, so no program
  can probe with it either.
* If someone implements the aliasing **without** the HOME path, every title would
  get a doubled PSG that real hardware only gives after a HOME boot — worse than
  leaving it alone. The two go together or neither does.

If it is ever done:

* openMSX registers it **out-only** — `Yamanooto.cc:96`,
  `register_IO_Out_range(0xA0, 2, this)`. Duplicating *reads* would break
  joystick and keyboard input, which come back through the internal PSG.
* Our `psg.sv:21` decodes `cpu_addr[7:3] == 5'b00010` (0x10-0x17) and derives
  bc1/bdir from `cpu_addr[1:0]`, so the alias is an extra `cs` term for 0xA0/0xA1
  with the same bc1/bdir decode.
* CFGR bit1 should become clear-only (`configReg[1] <= configReg[1] & din[1]`).
  Ours and openMSX's both let a write set it, which diverges from the `RC` marking
  — harmless while the bit drives nothing, not harmless once it does.
* A HOME-key boot path would need the key state sampled at reset. Note the core's
  `reset` is not an MSX-style CPU reset (`MSX1.sv:405` is HPS reset + OSD items +
  the ROM-load request), so "at boot" needs defining first.

Source: `Yamanooto Hardware Reference (public) (1).pdf` rev 15oct2024, section 2.3
and the CFGR bit table; official User Manual (the stated purpose).
