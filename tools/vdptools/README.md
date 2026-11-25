# vdptools.rom

The V9968 Cartridge test programs on one 512 KB ASCII16 ROM with a menu, so they
run on the MiSTer MSX core without a disk or MSX-DOS.

**Source of the programs**: [hra1129/V9968_Cartridge](https://github.com/hra1129/V9968_Cartridge)
`test/` at revision 453d5f3, MIT licence, Copyright (c) 2026 HRA!. The full licence
text is [`LICENSE_V9968_Cartridge.txt`](LICENSE_V9968_Cartridge.txt) and has to go
with any copy of the ROM. The menu, loader and stub in `vdptools.asm` are this
repository's. Released as `releases/V9968_VDPTOOLS_20261124_688ab71.rom`.

| item | program | what it does |
|---|---|---|
| 1 | VDPCHK | registers / VRAM / commands self check (V9968-only parts skipped on a V9958) |
| 2 | VDPREG | command end registers |
| 3 | VDPVIEW | pictures P01-P19 |
| 4 | VDPINT | line interrupt pictures P20-P23 |
| 5 | VDPDIAG | screen switch diagnosis |
| 6 | VRAMSTRS | VRAM stress (3 rounds) |
| 7 | VDPTEST | command termination stress |
| 8 | VRAMRW | VRAM read / write paths |

Keys: cursor up/down or joystick 1; SPACE / RETURN / trigger A runs; after the
program ESC / trigger B returns to the menu. Inside the programs trigger A is
SPACE and trigger B is ESC as well.

## How it works

- Bank 0 (4000h) holds the menu and the loader; each .COM starts on its own bank.
- The loader copies the program to RAM at 0100h (pages 0-2 = the page-3 RAM slot)
  and lays out page 0 the way MSX-DOS would: 0000h warm boot (back to the menu),
  0005h BDOS, 000Ch RDSLT, 001Ch CALSLT, 0038h interrupt, (0006h) = E000h.
- The page-3 stub (E000h-E3FFh) is the "DOS": console functions only (00h, 01h,
  02h, 06h, 07h, 08h, 09h, 0Bh, 1Ah); every file function fails, so the programs
  print "LOG FILE ERROR" instead of writing their .LOG.
- Console output is also kept in a 2 KB ring (E400h); after the program the
  screen is rebuilt (80 columns) and the output printed again.
- The interrupt stub sets R#15 = 0 before the BIOS handler: VDPTEST leaves R#15 =
  14 (its `wreg` returns A = 80h + register, so the final `xor a` is lost) and the
  unacknowledged VDP interrupt would re-enter until the stack is gone.
- `pack.py` patches each `OUT (0AAh),A / IN A,(0A9h)` keyboard read (VDPVIEW,
  VDPINT, VDPDIAG, VRAMSTRS) into `OUT (0AAh),A / RST 30h / NOP`; the RST 30h
  handler reads the row and pulls SPACE / ESC low for the joystick triggers.
- 32 never-executed `LD (7000h),A` in bank 0 make the MiSTer core's mapper
  detection (`rtl/peripheral/slots/mapper_detect.sv`, replicated in `detect.py`)
  pick ASCII16; without them the programs' `LD (8000h),A` make it Konami. The OSD
  has no plain ASCII16 entry, so leave the mapper on auto.

## Build and test

    ./build.sh            # fetches the .COM files from the V9968_Cartridge clone (rev 453d5f3)
    ./run_tests.sh        # openMSX: all eight programs from the menu, then the pad paths

openMSX's V9958 times out on VDPTEST case #59 (LMCM) in both passes and reads
VRAMRW's LMCM points differently; these come from the emulator, not the ROM.
