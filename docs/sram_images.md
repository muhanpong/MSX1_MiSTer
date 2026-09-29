# SRAM images: VD0..VD3 and the boot1..3.vhd layout (2026-09-30)

## Why

The core can only persist SRAM through an image the HPS has mounted.  The
firmware mounts exactly one image by itself for a game: the slot A ROM's
companion `saves/MSX1/<rom>.sav` on VD0 (`FS3` in CONF_STR; the drive index is
hard-coded to 0 in user_io.cpp).  Every other SRAM the core allocates --
FM-PAC PAC (slot A -> VD1, slot B -> VD2), GameMaster2 (VD1) and the machine's
own SRAM (Halnote, the turbo R firmware mapper -> VD3) -- had a bank in
nvram_backup but never an image, so it lived only while the core ran.

The firmware also auto-mounts `games/MSX1/boot<n>.vhd` (n = 0..3) on VD<n> at
core start when the file exists (user_io.cpp, "check if vhd present").  That is
the hook: put a file there once and VD1..VD3 are mounted every time.  `boot0.vhd`
must not be created -- it would take VD0 from the .sav.

## Layout

One file per VD, one 64 kB entry per *device kind*, so devices that share a VD
never overwrite each other:

| VD | file | entry 0 | entry 1 | entry 2 | size |
|---|---|---|---|---|---|
| 0 | `saves/MSX1/<rom>.sav` | raw SRAM from LBA 0 (unchanged) | | | = SRAM |
| 1 | `games/MSX1/boot1.vhd` | FM-PAC (slot A), 8 kB | GameMaster2, 8 kB | | 128 kB |
| 2 | `games/MSX1/boot2.vhd` | FM-PAC (slot B), 8 kB | | | 64 kB |
| 3 | `games/MSX1/boot3.vhd` | Halnote, 16 kB | FS-A1ST firmware SRAM, 16 kB | FS-A1GT firmware SRAM, 32 kB | 192 kB |

Entry n occupies LBA 128n .. 128n+127 (64 kB).  Its first sector is the header;
the rest of the first 4 kB is reserved; data starts at LBA 128n + 8 (byte offset
4 kB) and may be up to 60 kB.  A file may be larger than the table says; the
surplus is ignored.

Header sector (little-endian, unused bytes 0):

| offset | size | content |
|---|---|---|
| 0 | 8 | `"MSX1SRAM"` |
| 8 | 1 | format version, 1 |
| 9 | 1 | kind: 1 FM-PAC, 2 GameMaster2, 3 Halnote, 4 Panasonic 16 kB, 5 Panasonic 32 kB (`package.sv` SRAM_KIND_*) |
| 10 | 2 | SRAM size in kB |
| 12 | 4 | save counter (incremented on every save; 1 on the first save into a blank entry) |

## Behaviour (rtl/nvram_backup.sv)

* Kind and entry come from the pack/cart: memory_upload records the SRAM's kind
  from the record's mapper and size (`lookup_SRAM[n].kind`).
* Load (end of upload, or OSD "SRAM Load"): read the entry's header sector; if
  magic, version, kind and size all match, read the data into the SRAM bank;
  otherwise skip that bank (a message on the simulation log) and complete the
  request.  A blank file therefore loads nothing and harms nothing.
* Save (OSD "SRAM Save", autosave on OSD): read the header (for the counter),
  write the header with counter + 1, then the data.
* A file too small for the entry is skipped with a message (the core cannot grow
  a file; only VD0's .sav is created on write by the firmware).
* VD0 keeps the raw format so existing .sav files stay valid.

The data area is a raw copy of the SRAM, so it exchanges 1:1 with openMSX's
`.SRAM` files once the 4 kB header is stripped or prepended.

## Making the files

    tools/sramimg/mk_sram_images.sh /path/to/games/MSX1

writes zero-filled boot1.vhd (128 kB), boot2.vhd (64 kB), boot3.vhd (192 kB) and
leaves existing files alone.

## Bench

`sim/run_nvram_layout.sh` -- an SD model with four in-memory images: raw VD0,
FM-PAC/GM2 entries on VD1, the GT entry on VD3, bad magic, wrong kind, too-small
image, saves with counter increment and on a blank image.  A mutant with the
data base one sector off must fail.  Wired into the `saveload` landmine row.

## Known limit

The SRAM BRAM is 64 kB in total (systemRAM, addr_width 16).  Slot A ROM SRAM
(up to 32 kB) + FM-PAC A (8) + FM-PAC B (8) + machine SRAM (up to 32 with a GT
firmware block) can exceed it; memory_upload allocates sequentially and does not
check.  No pack carries the GT/ST firmware block yet (no firmware ROM in the ROM
store), so today the largest real total is 32 + 8 + 8 + 16 (Halnote) = 64.
Adding the GT block needs that budget revisited first.
