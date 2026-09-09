# MSX1/MSX2 for [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

A fork of [MiSTer-devel/MSX1_MiSTer](https://github.com/MiSTer-devel/MSX1_MiSTer) that adds
MoonSound (YMF278B/OPL4), a Z80 turbo, IKASCC-based SCC+, the ASCII16-X and NEO-8/16
mappers, expanded slots, standard OSD cheats, extended saves, and a number of VDP
accuracy fixes.

---

## 이 포크가 더한 것 / What this fork adds (summary)

**새로 생긴 것 / New**

- **Z80 터보 / Z80 turbo** — 5.37 / 7.16 / 10.7 MHz 세 단계. 파나소닉 MSX2+ 방식 포트 토글도 지원
  *Three steps (5.37 / 7.16 / 10.7 MHz), plus the Panasonic MSX2+ port toggle.*
- **SCC+ 정상화 / SCC+ done right** — IKASCC 기반, ch4/ch5 별도 파형. 듀얼 SCC+ 연주 가능
  *IKASCC-based, separate ch4/ch5 waveforms; two SCC+ can play at once.*
- **NEO-8 / NEO-16 매퍼 / mappers** — 최대 64MB, 시그니처 자동 인식 + OSD 수동 선택
  *Up to 64MB, auto-detected by signature or picked by hand in the OSD.*
- **확장 슬롯 / Expanded slots** — 주 슬롯에 서브 슬롯 on/off, 넣을 기능 선택
  *Sub-slots on/off per primary slot, each sub-slot's device chosen in the menu.*
- **치트 / Cheats** — .gg 형식, 자동/수동 로딩
  *.gg format, automatic and manual loading.*
- **세이브 확장 / Extended saves** — ASCII16X와 Yamanooto 매퍼 세이브 지원. ASCII16은 ASCII16X로 통합
  *Save support for the ASCII16X and Yamanooto mappers; ASCII16 folded into ASCII16X.*
- **AUDIO SETTINGS** — 음원별 게인 ±8dB, 뮤트, SCC 채널별 뮤트
  *Per-source gain (±8dB), mute, and per-channel SCC mute.*

**곁들여 고친 것 / Also fixed**

- VDP 버그 두 건 — Zanac EX 타이틀 깨짐, 뿌띠 까미용 공중부양
  *Two VDP bugs: Zanac EX title corruption, Putty Camiyon floating sprites.*
- OPL4·ASCII16X 쪽 수정으로 *Go Figure* 플레이 가능
  *OPL4 and ASCII16X fixes make Go Figure playable.*

아래는 항목별 상세 / Details below.

---

## What this fork adds

### MoonSound (YMF278B / OPL4)
Full OPL4 emulation — OPL3-compatible FM plus the PCM wavetable engine.

- Ports `0x7E/0x7F` (WAVE) and `0xC4-0xC7` (FM), `/WAIT` and `/INT` handled like the real cartridge
- 2MB sample RAM in addition to the wavetable ROM
- Menu: `MoonSound On/Off`, `PCM Mute`, `FM Mute`, `PCM Volume (+6/+12/+18/+24 dB)`, `Debug Overlay`
- Requires the `yrw801.rom` wavetable — supplied through the **FW PACK** (see below)

The PCM engine is validated against a bit-exact golden harness derived from the openMSX
`YMF278.cc` model, and the FM side against Nuked-OPL3.

### ASCII16-X mapper (large flash carts)
One `ASCII16X` menu entry covers both variants and dispatches on ROM size:

- ROM ≤ 4MB → classic ASCII16 behaviour (SRAM, plain banking)
- ROM > 4MB → ASCII16-X flash mapper with an 8MB chip, JEDEC/CFI command set

This is what MSXdev entries such as *GoFigure* need.

### NEO-8 / NEO-16 mappers
openMSX's concept mappers with 12-bit bank registers (up to 64MB). Recognised by the
`ROM_NEO8` / `ROM_NE16` signature at file offset 16, or selected by hand from the mapper
dropdown -- a damaged signature cannot be told apart 8-from-16 by banking alone.

### Cheats
Standard MiSTer OSD cheat support using the common Kitrinx `.gg` format.

- `Cheats` menu populated automatically from the cheat database
- `Load Cheat` to load a `.gg` file manually
- `Cheats On/Off` master toggle
- 4-way set-associative BRAM lookup engine, capacity ~2048 codes

### Pause
- `Pause on OSD` — freeze the machine whenever the OSD is open
- `Pause` — hotkey-triggered pause with an on-screen ⏸ indicator

### Storage
- `MegaFlashROM SCC+ SD` cartridge in slot A, with `Load SD card` mounting a `.VHD` image
  (Nextor-compatible FAT16, multi-partition images supported)
- `SRAM Save` / `SRAM Load`

### VDP accuracy
Several timing and behaviour fixes measured against real hardware and openMSX:

- Sprite pipeline restricted to display-area lines — removes ghost `S#0` collisions that
  made `ON SPRITE` traps fire continuously (sprites parked at Y=209 by `CLRSPR`)
- Real-chip vblank IRQ position, per-scanline VDP command throttling, positional `VR` flag
- `FH` flag armed only while `IE1` is enabled
- Optional V9958 mode

---

# Features MSX1
- reference HW Philips SVG8020/00
- RAM 64kB in slot 3
- Sound YM2149(PSG)
- Support two cartrige
- Automatic detect cartrige mapper
- Manual select mapper: `none, ASCII8, ASCII16X, Konami, KonamiSCC, KOEI, linear64, R-TYPE, WIZARDRY`
- Joystick.
- FDD support (VY0010). Use DSK image
- Cassete support. Analog or CAS emmulation
- PAL/NTSC mode
- Load bios for experimets

## Memory limitations
- No SDRAM 
  - Slot 1 ROM image max size 128kB
  - Slot 2 ROM image max size  64kB
  - Slot 3 64Kb RAM
- 32MB SDRAM
  - Slot 1 ROM image max size 1MB
  - Slot 2 ROM image max size 2MB
  - Slot 3 64Kb RAM
- 64MB SDRAM
  - Slot 1 ROM image max size 2MB
  - Slot 2 ROM image max size 4MB
  - Slot 3 64Kb RAM
- 128MB SDRAM
  - Slot 1 ROM image max size 4MB
  - Slot 2 ROM image max size 4MB
  - Slot 3 64Kb RAM

## ROM BIOS
Load them manually from the menu

# Features MSX2
- reference HW Philips SVG8240/00
- RAM in slot 3/2
- Sound YM2149(PSG)
- Video V9938 (V9958 selectable)
- Support two cartrige
- Cartrige emulation:
  - Slot A: `ROM, SCC, SCC+, FM-PAC, MegaFlashROM SCC+ SD, GameMaster2, FDC`
  - Slot B: `ROM, SCC, SCC+, FM-PAC`
- Automatic detect cartrige mapper
- Manual select mapper: `none, ASCII8, ASCII16X, Konami, KonamiSCC, KOEI, linear64, R-TYPE, WIZARDRY`
- Selectable SRAM size (auto, 1kB-32kB, none)
- Joystick.
- FDD support.
- RTC support
- Cassete support. Analog or CAS emmulation
- PAL/NTSC mode
- Load bios for experimets

## Memory limitations
- No SDRAM 
  - Slot 1 ROM image max size 128kB
  - Slot 2 ROM image max size  64kB
  - Slot 3/2 64Kb RAM
- 32MB SDRAM
  - Slot 1 ROM image max size 1MB
  - Slot 2 ROM image max size 2MB
  - Slot 3/2 512Kb RAM
- 64MB SDRAM
  - Slot 1 ROM image max size 2MB
  - Slot 2 ROM image max size 4MB
  - Slot 3/2 512Kb RAM
- 128MB SDRAM
  - Slot 1 ROM image max size 4MB
  - Slot 2 ROM image max size 4MB
  - Slot 3/2 512Kb RAM

## ROM BIOS
Copy bios files to Games/MSX1 folder or load them manually from the menu
- BIOS files use the `.MSX` file extension.
- Use the script `tools/CreateMSXPack/createMSXpack.py` to generate them.
- Refer to the XML files in the `Computer` and `Extension` directories to determine which BIOS ROM files are needed.
- Copy the required ROM files into the `tools/CreateMSXPack/ROM` directory.
- Then, run the `createMSXpack.py` script.
- The generated `.MSX` files will be located in the `tools/CreateMSXPack/MSX` directory.

### FW PACK (cartridge / extension firmware)
`Load FW PACK` supplies the firmware images used by the emulated cartridges — FM-PAC,
Game Master 2, MegaFlashROM SCC+ SD (Nextor) and the MoonSound wavetable.

| Extension | File | SHA1 |
|---|---|---|
| MOONSOUND | `yrw801.rom` | `32760893ce06dbe3930627755ba065cc3d8ec6ca` |

Place the ROMs in `tools/CreateMSXPack/ROM/` and build the pack with `createMSXpack.py`,
the same way as the BIOS pack.
