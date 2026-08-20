# TODO — OSD layout and core behaviour requests

Recorded 2026-08-21. These are wanted changes, not defects.

---

## 1. Make the forced reset on ROM / mapper change optional

**Now:** `rtl/peripheral/slots/memory_upload.sv:78`

```verilog
assign reset_rq = ! (state == STATE_IDLE | state == STATE_ERROR);
```

`reset_rq` is asserted for the **whole** upload FSM, and `MSX1.sv:405` folds it
straight into the machine reset:

```verilog
wire reset = RESET | status[0] | status[10] | reset_rq;
```

So loading a ROM, or changing the mapper for an already-loaded one, always resets
the machine. There is no way to turn it off.

**Wanted:** an OSD toggle, so a ROM or mapper can be swapped **without** resetting —
useful for comparing mappers on the same running program, and for anything that
should survive the swap.

**Care needed before implementing.** The reset is not decoration; it is what keeps
the CPU off the bus while `memory_upload` is streaming into DDR3/SDRAM and while
the slot layout registers change underneath it. Points to settle:

* A swap that changes `lookup_RAM` bases or the slot layout while the CPU is
  executing from the old mapping is a genuine hazard, not just a cosmetic one.
  The safe form is probably "hold the CPU (like `msx_pause` / `dma_active`) for the
  transfer, then release without asserting reset", not "drop the reset entirely".
* Slot/subslot select registers and the mapper's own bank registers keep their old
  values across a no-reset swap. Decide whether they should be re-initialised.
* `rom_eject` (`status[10]`) and the boot-time autoload path should keep resetting;
  the toggle should only cover a user-initiated swap of an already-running machine.
* Check the interaction with `nvram_backup` / `flash_dirtysave`, which use
  `upload_active` and `load_sram` to decide when to restore.

Suggested shape: `"O[nn],Reset on ROM change,Yes,No;"`, defaulting to **Yes** so
existing behaviour is unchanged unless asked for.

## 2. Group the MoonSound items under an "Audio settings" page

**Now:** five MoonSound entries sit flat at the OSD top level (`MSX1.sv`, in
`CONF_STR`), between the Pause and Debug Overlay items:

```
"O[45],MoonSound,Off,On;"
"O[46],PCM Mute,Off,On;"
"O[47],FM Mute,Off,On;"
"O[50:49],OPL4 PCM Volume,0dB,-4dB,-8dB,-12dB;"
"O[53:52],OPL4 FM Volume,0dB,-4dB,-8dB,-12dB;"
```

**Wanted:** an `Audio settings` submenu, with the MoonSound items inside it —
mirroring the existing `"P1,Video settings;"` page, so the top level stays short.

Mechanically this is just a page prefix, e.g.

```
"P2,Audio settings;",
"P2O[45],MoonSound,Off,On;",
...
```

Points to settle:

* **Which items move.** MoonSound On/Off is arguably a machine-configuration item
  rather than an audio-mixer one, and it also gates `ms_audio_*` in `msx.sv:1381`.
  Mute/Volume clearly belong under Audio. Debug Overlay is not audio and should
  stay where it is.
* `status` bit numbers do **not** change — a page prefix is presentation only, so
  saved settings survive.
* Watch the CONF_STR menu-index rule this project has already been bitten by: a
  token at index 1 is a dead slot (MiSTer reserves it for SS/UART/MIDI). Adding a
  page near the top shifts indices, so re-check that `"C,Cheats;"` and anything
  else order-sensitive stays at index >= 2. See `project-cheat-engine` in memory.
* If a future PSG/SCC volume control appears (see `TODO_yamanooto.md`, the cart-PSG
  vs SCC ratio note), it belongs on the same page — worth leaving room.
