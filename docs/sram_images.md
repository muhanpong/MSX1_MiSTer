# SRAM images: the slot A .sav (VD0) and the SRAM file (VD1)

2026-09-30 format (64 kB entries, 4 kB header -- user decision), 2026-10-04 one
file on VD1 instead of boot1..3.vhd on VD1..VD3, the RTC entry, and autosave on
write (user decisions 2026-10-04: SC1 / VD1, slot A over slot B, RTC saved,
autosave on write, SRAM stays in BRAM).

## Why

The core can only persist SRAM through an image the HPS has mounted.  The
firmware mounts exactly one image by itself for a game: the slot A ROM's
companion `saves/MSX1/<rom>.sav` on VD0 (`FS3` in CONF_STR; the drive index is
hard-coded to 0 in user_io.cpp).  Every other SRAM the core allocates -- FM-PAC
PAC, GameMaster2, the machine's own SRAM (Halnote, the Panasonic firmware
mapper) -- and the RTC's settings memory lived only while the core ran.

They now share ONE file, the SRAM file, on VD1.  The OSD entry "SRAM File"
(`SC1,NVR`) picks it; the firmware remembers the pick in `config/MSX1.s1` and
mounts it at every core start (user_io.cpp, the `SC` restore).  An SC image is
opened without O_CREAT and never grows, so the file must exist at full size.
It is deliberately kept OUT of the packs, so that copying a pack folder over the
board's never replaces an SRAM.NVR holding saves; the user copies it once:
`createMSXpack.py` writes an empty `SRAM.NVR` next to `MSX/` (only when missing),
`packbuilder.html` has a separate "빈 SRAM.NVR 받기" button, and
`tools/sramimg/mk_sram_images.sh <dir>` makes one.  A `boot1.vhd`, if present,
is mounted by the firmware after the SC restore and so takes VD1 (read from the
firmware code order, not tested; left to the user).  VD2 and VD3 are unused.

## Layout

| VD | file | content | size |
|---|---|---|---|
| 0 | `saves/MSX1/<rom>.sav` | slot A ROM cart SRAM, raw from LBA 0 (unchanged) | = SRAM |
| 1 | `SRAM.NVR` (any name, picked with SC1) | one 64 kB entry per kind, below | 2 MB (32 entries, 6 in use) |

| entry | kind | device | data |
|---|---|---|---|
| 0 | 1 | FM-PAC PAC | 8 kB |
| 1 | 2 | GameMaster2 | 8 kB |
| 2 | 3 | Halnote (HB-F1XV) | 16 kB |
| 3 | 4 | Panasonic firmware SRAM, FS-A1ST | 16 kB |
| 4 | 5 | Panasonic firmware SRAM, FS-A1GT | 32 kB |
| 5 | 6 | RTC (RP5C01) settings memory | 1 kB (64 nibbles, then copies) |

Entry = kind - 1.  Entry n occupies LBA 128n .. 128n+127 (64 kB).  Its first
sector is the header; the rest of the first 4 kB is reserved; data starts at LBA
128n + 8 (byte offset 4 kB) and may be up to 60 kB.  A file may be larger than
the table says; the surplus is ignored.

The blank file is 2 MB, 32 entries, so 26 are spare for devices added later
(Matsushita 2 kB SRAM, S1985 backup RAM, ...).  Each entry is checked against the
file size on its own: an entry beyond the end of a smaller file is skipped (not
read, not written) and the others work.  A smaller file is grown without losing
anything by appending zeros (`truncate -s 2M SRAM.NVR`) -- never by replacing it
with a new blank one.  Kind numbers are append-only and never reused: a new
device reusing a kind shares that entry with the old one and they overwrite each
other.  The engine addresses up to kind 255 (16 MB).

The entry follows the DEVICE, not the slot: an FM-PAC saves to entry 0 whichever
slot it is in.  When two banks have the same kind (an FM-PAC in slot A and in
slot B) the lower bank owns the entry -- slot A -- and the other is neither
loaded nor saved (it runs on volatile SRAM).  Banks: 0 slot A ROM (VD0), 1 slot A
FM-PAC/GM2, 2 slot B FM-PAC/GM2, 3 machine SRAM, 4 RTC.

Header sector (little-endian, unused bytes 0):

| offset | size | content |
|---|---|---|
| 0 | 8 | `"MSX1SRAM"` |
| 8 | 1 | format version, 1 |
| 9 | 1 | kind: 1 FM-PAC, 2 GameMaster2, 3 Halnote, 4 Panasonic 16 kB, 5 Panasonic 32 kB, 6 RTC (`package.sv` SRAM_KIND_*) |
| 10 | 2 | SRAM size in kB |
| 12 | 4 | save counter (incremented on every save; 1 on the first save into a blank entry) |

## Behaviour (rtl/nvram_backup.sv)

* Kind and entry come from the pack/cart: memory_upload records the SRAM's kind
  from the record's mapper and size (`lookup_SRAM[n].kind`).  The RTC is
  nvram_backup's own bank 4, addressed at 18'h20000; MSX1.sv routes that range
  (bit 17, beyond the 64 kB BRAM) to the RTC's second port (rtc.vhd).
* Load (end of upload, or OSD "SRAM Load"): read the entry's header sector; if
  magic, version, kind and size all match, read the data into the SRAM bank;
  otherwise skip that bank (a message on the simulation log) and complete the
  request.  A blank file therefore loads nothing and harms nothing.
* Save (OSD "SRAM Save", or autosave): read the header (for the counter), write
  the header with counter + 1, then the data.
* A file too small for the entry is skipped with a message (the core cannot grow
  a file; only VD0's .sav is created on write by the firmware).
* VD0 keeps the raw format so existing .sav files stay valid.

### Order of transfers (2026-10-04, `sim/run_nvram_order.sh`)

* **A mounted image is read.**  The firmware mounts without asking the core (core
  start, every ROM load for VD0's .sav, an OSD pick), so `img_mounted` now raises a
  load for that bank.  Before, only the OSD button or the upload's own request read
  an image, and an image mounted mid-session got the previous data saved into it.
* **Load before save.**  After an upload the BRAM holds the fill pattern until the
  load has run, so a pending load is served before a save of the same bank.
* **Nothing during an upload.**  While memory_upload rebuilds the layout
  (`upload_busy` = its `reset_rq`) no transfer starts and save requests are
  dropped; the upload's end raises the load.
* **save_guard covers SRAM saves.**  nvram_backup's `guard` (a transfer in flight,
  or a servable save waiting) is part of `saving` in MSX1.sv, so a reset button or
  a ROM upload waits for it.  Before, `saving` was only the flash paths.
### Autosave on write (2026-10-04, OSD "SRAM Autosave", status[52])

* A CPU write into a bank's BRAM range (port A, not the upload) or into the RTC
  settings memory (blocks 2-3, registers 0..12 only -- the BIOS writes the mode
  register and the clock on every access) marks the bank dirty.
* A dirty bank is saved when writes have been quiet for 2^24 clocks (~0.78 s),
  or 2^28 clocks (~12.5 s) after the first write if they never stop, or at once
  when `flush` rises: a file download (`ioctl_download`, i.e. a ROM or pack about
  to replace the layout) or an OSD Reset / Reset & Detach.
* `guard` counts a dirty bank as a save waiting, so save_guard holds a load or a
  reset button for it; while `flush` is held the dirty term is dropped, or a game
  that writes its SRAM every frame would hold an upload off for good.
* An upload drops what was dirty (it belongs to the layout being replaced).
* Flash carts (ASCII16X / Yamanooto, flash_dirtysave) still save when the OSD
  opens with the option on.  The manual SRAM Save / Load buttons are unchanged.
* With the option Off nothing is saved except by SRAM Save.

The data area is a raw copy of the SRAM, so it exchanges 1:1 with openMSX's
`.SRAM` files once the 4 kB header is stripped or prepended.

## Making the file

    tools/sramimg/mk_sram_images.sh /path/to/games/MSX1/MSX

writes a zero-filled SRAM.NVR (2 MB), leaves an existing one alone, and warns
if a boot1..3.vhd is there.  createMSXpack.py (next to `MSX/`) and
packbuilder.html (its own button) make the same file.

## Benches

`sim/run_nvram_layout.sh` -- an SD model with two in-memory images: raw VD0, the
FM-PAC / GM2 / GT / RTC entries on VD1, bad magic, wrong kind, too-small file,
saves with counter increment and on a blank file, slot A over slot B, a mount
loading every entry, and autosave (quiet, off, age, flush + guard, upload drop,
RTC, a write outside every bank).  Five mutants (data base one sector off, no
slot priority, no quiet trigger, no flush, no upload drop) must each fail.
`sim/run_nvram_order.sh` -- load before save, nothing during an upload, mount ->
load, guard without gaps.  `sim/run_rtc_nvport.sh` -- the RTC second port and
mem_dirty on the ghdl netlist.  All in the `saveload` / `rtcnv` landmine rows.

## Known limit

The SRAM BRAM is 64 kB in total (systemRAM, addr_width 16).  Slot A ROM SRAM
(up to 32 kB) + FM-PAC A (8) + FM-PAC B (8) + machine SRAM (up to 32 with a GT
firmware block) can exceed it (the RTC is not in the BRAM); memory_upload allocates sequentially and does not
check.  No pack carries the GT/ST firmware block yet (no firmware ROM in the ROM
store), so today the largest real total is 32 + 8 + 8 + 16 (Halnote) = 64.
Adding the GT block needs that budget revisited first.
