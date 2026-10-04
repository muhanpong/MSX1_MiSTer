# MSX1/MSX2 for [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

A fork of [MiSTer-devel/MSX1_MiSTer](https://github.com/MiSTer-devel/MSX1_MiSTer) that adds
MoonSound (YMF278B/OPL4), turbo R machines with an R800, a Z80 turbo, MSX-MIDI with
MT32-pi support, IKASCC-based SCC+, the ASCII16-X and NEO-8/16 mappers, expanded slots,
standard OSD cheats, extended saves, and a number of VDP accuracy fixes.

---

## 이 포크가 더한 것 / What this fork adds (summary)

**새로 생긴 것 / New**

- **MoonSound (OPL4)** — YMF278B FM + PCM 웨이브테이블 엔진, 2MB 샘플 RAM
  *YMF278B FM plus the PCM wavetable engine, with 2MB of sample RAM.*
- **turbo R** — FS-A1GT / FS-A1ST 기계 팩, R800과 Z80 실행 중 전환(소프트웨어 또는 OSD), R800 7.16 / 21.5 MHz
  *FS-A1GT / FS-A1ST machine packs; the R800 and the Z80 switch at run time (by software or the OSD); R800 at 7.16 / 21.5 MHz.*
- **Z80 터보 / Z80 turbo** — 3.58 기본에 5.37 / 7.16 / 10.7 / 21.5 MHz 추가. 파나소닉 MSX2+ 방식 포트 토글도 지원
  *5.37 / 7.16 / 10.7 / 21.5 MHz on top of the stock 3.58, plus the Panasonic MSX2+ port toggle.*
- **turbo R 디스크 ROM 합성 / disk ROM synthesis** — MSX-DOS 2.30/2.31 커널과 WD2793 드라이버를 사용자 덤프에서 합성
  *The turbo R disk ROM (MSX-DOS 2.30/2.31 kernel + WD2793 driver), synthesized from your own dumps.*
- **MIDI / MT32-pi** — E8h-EFh MSX-MIDI(어느 기계에나), FS-A1GT 내장 MIDI, 슬롯 B의 μ·PACK, USER 포트 MT32-pi
  *An MSX-MIDI at E8h-EFh on any machine, the FS-A1GT's built-in one, μ·PACK in slot B, and an MT32-pi on the USER port.*
- **SCC+ 정상화 / SCC+ done right** — IKASCC 기반, ch4/ch5 별도 파형. 듀얼 SCC+ 연주 가능
  *IKASCC-based, separate ch4/ch5 waveforms; two SCC+ can play at once.*
- **NEO-8 / NEO-16 매퍼 / mappers** — 최대 64MB, 시그니처 자동 인식 + OSD 수동 선택
  *Up to 64MB, auto-detected by signature or picked by hand in the OSD.*
- **확장 슬롯 / Expanded slots** — 주 슬롯에 서브 슬롯 on/off, 넣을 기능 선택
  *Sub-slots on/off per primary slot, each sub-slot's device chosen in the menu.*
- **치트 / Cheats** — .gg 형식, 자동/수동 로딩
  *.gg format, automatic and manual loading.*
- **세이브 확장 / Extended saves** — ASCII16X와 Yamanooto 매퍼 세이브 지원. OSD의 ASCII16X 항목은 4MB 이하면 ASCII16, 4MB 초과나 ASCII16X 헤더면 ASCII16X. FM-PAC·GameMaster2·Halnote·turbo R 펌웨어 SRAM·RTC 설정은 **SRAM.NVR 파일 하나**에 저장 — **SRAM.NVR은 팩에 들어 있지 않으니 직접 한 번 복사**하고 OSD `SRAM(PAC/Turbo-R/...)`에서 고를 것. SRAM은 쓰기가 멈추면 자동 저장(`SRAM Autosave`)
  *Save support for the ASCII16X and Yamanooto mappers. The OSD's ASCII16X entry is plain ASCII16 up to 4MB, ASCII16X above 4MB or with an ASCII16X header. FM-PAC, GameMaster2, Halnote, turbo R firmware SRAM and the RTC settings are saved in **one file, SRAM.NVR** — **it is not part of the packs: copy it once yourself** and pick it in the OSD under `SRAM(PAC/Turbo-R/...)`. SRAM is saved automatically once writes stop (`SRAM Autosave`).*
- **AUDIO SETTINGS** — 음원별 게인 ±8dB, 뮤트, SCC 채널별 뮤트
  *Per-source gain (±8dB), mute, and per-channel SCC mute.*
- **일시정지 / Pause** — OSD 열림 또는 단축키, 화면에 ⏸ 표시
  *On OSD open or a hotkey, with an on-screen ⏸ indicator.*
- **JoyMega 패드 / JoyMega pad** — MSX 조이스틱 포트에 메가드라이브 6버튼 패드, openMSX와 같은 핀 8 위상 프로토콜
  *A 6-button Mega Drive pad on the MSX joystick port, on the same pin-8 phase protocol openMSX uses.*
- **패드 버튼 / Pad buttons** — 남는 버튼으로 Space·Return·F1을 누르거나 일시정지
  *Spare pad buttons press Space, Return or F1, or pause the machine.*
- **Reset on ROM change** — 롬을 바꿀 때 리셋 대신 기계를 멈춰 두는 선택
  *Hold the machine instead of resetting it while a ROM is swapped.*

**곁들여 고친 것 / Also fixed**

- VDP 버그 두 건 — Zanac EX 타이틀 깨짐, 뿌띠 까미용 공중부양
  *Two VDP bugs: Zanac EX title corruption, Putty Camiyon floating sprites.*
- OPL4·ASCII16X 쪽 수정으로 *Go Figure* 플레이 가능
  *OPL4 and ASCII16X fixes make Go Figure playable.*
- VDP 커맨드 엔진 타이밍을 실측 슬롯 맵으로 교체 (7개 명령 평균 오차 19.4% → 2.8%)
  *VDP command-engine timing replaced with a measured access-slot map (mean error over seven commands 19.4% → 2.8%).*
- MoonSound FM 음정을 YMF278B 샘플레이트로 (+7센트 어긋남 해소)
  *MoonSound FM at the YMF278B sample rate, removing a +7 cent detune.*
- 롬 로드 때 세이브 자동 로드가 리셋에 묻혀 안 되던 문제
  *The .sav auto-load on ROM load no longer gets lost inside the machine reset.*

아래는 항목별 상세 / Details below.

---

## What this fork adds

### MoonSound (YMF278B / OPL4)
Full OPL4 emulation — OPL3-compatible FM plus the PCM wavetable engine.

- Ports `0x7E/0x7F` (WAVE) and `0xC4-0xC7` (FM), `/WAIT` and `/INT` handled like the real cartridge
- 2MB sample RAM in addition to the wavetable ROM
- Menu: `MoonSound On/Off`, `PCM Mute`, `FM Mute`, `PCM Volume`, `FM Volume` (2 dB steps), `Debug Overlay`
- Requires the `yrw801.rom` wavetable — supplied through the **FW PACK** (see below)
- The wavetable is loaded **only when the machine pack carries a `MOONSOUND` device record**
  (`<device typ="MOONSOUND" ...>` in the pack's XML). The OSD `MoonSound` switch alone does not
  load it: on a pack without the record the FM side plays but the PCM side reads an empty wave
  ROM, so PCM sound effects are missing or very weak. The debug overlay shows it — row 0
  (`ROM Base Set`) stays red.
  - Packs for the MSX2+ and turbo R machines (FS-A1FX / WX / GT / ST, HB-F1XV) already carry the record.
  - Plain MSX2 packs do not. `Computer/Panasonic/Panasonic FS-A1F basic MoonSound.xml` and
    `Computer/Sony/Sony_HB-F1XDmk2_MoonSound.xml` are the stock packs plus that one record;
    for any other pack, add the same `<device>` line to its XML and rebuild with `createMSXpack.py`.
  - The record occupies no slot (it sits outside `<primary>`): slot A and B stay free for cartridges.

The PCM engine is validated against a bit-exact golden harness derived from the openMSX
`YMF278.cc` model, and the FM side against Nuked-OPL3.

### Z80 turbo
`Z80 Speed` on the OSD's `CPU` page: `3.58MHz` (stock), `5.37MHz (Panasonic)`, `7.16MHz`,
`10.7MHz`, `21.5MHz`. The Z80 is T80s on a single clock enable, so `21.5MHz` is one T-state
per `clk21m`.

- The Panasonic step also answers the switched I/O ports `0x40/0x41` a real Panasonic MSX2+
  uses, so software that probes for it sees the faster clock (not on a turbo R pack, whose
  own speed control is the R800)
- SCC and OPLL are paced so they stay correct at the higher clocks

### turbo R
A machine pack whose BIOS says turbo R (byte `002Dh` = 3) brings up the turbo R hardware:
the S1990 with its CPU switch (`E4h`/`E5h`), the `E6h` timer, the PCM, and the R800.
Any other pack gets none of it, whatever the OSD says.

- **CPU switching.** The Z80 (T80s) and the R800 (NextZ80) share the bus and hand over at
  run time, the way the S1990 does it: by software (`OUT E5h`, the BIOS `CHGCPU`) or from
  the OSD's `CPU (turbo R)`: `Auto` (software decides), `Force Z80`, `Force R800`. The OSD
  choice is applied when the menu closes. A popup says which CPU the machine has settled on.
- `R800 Speed`: `7.16MHz` or `21.5MHz`. `R800 VDP access wait` spaces R800 writes to the VDP
  the way a real turbo R does (`8.66us`, the default) -- without it R800 software that writes
  the VDP back to back drops data.
- The R800 is NextZ80 run at the R800's clock: fast, but not cycle-exact R800 timing.
- The `CPU` page shows the R800 rows only on a turbo R pack, and only the Z80 ladder on any
  other machine.

#### Machine packs
Packs are built from your own ROM dumps with `tools/CreateMSXpack/createMSXpack.py`, or in a
browser with the offline pack builder: [`tools/CreateMSXpack/packbuilder.html`](tools/CreateMSXpack/packbuilder.html)
(hosted at <https://muhanpong.github.io/MiSTer/packbuilder.html>; see
[`PACKBUILDER.md`](tools/CreateMSXpack/PACKBUILDER.md)). The page reads a ROM folder or a
collection `.zip`, lists which ROMs each pack still needs, and makes no network request.

- `Panasonic FS-A1GT DOS2` (512KB, and 1/2/4MB RAM variants), `Panasonic FS-A1ST DOS2`
  (256KB, and 512KB/1/2/4MB variants), `Panasonic FS-A1GT DOS2-ILLUK` (the GT with the
  Korean *Illusion City* kanji font)
- The MSX-MIDI of the FS-A1GT and its Opening ROM are part of its pack

#### MSX-DOS 2 and the synthesized disk ROM
This core's floppy controller is a WD2793. The turbo R, like the Panasonic FS-A1 models
with a disk drive, uses a TC8566AF, so its own disk ROM cannot drive it. The turbo R packs
(all ten) carry a disk ROM synthesized from the machine's firmware -- its MSX-DOS
2.30/2.31 kernel -- and the WD2793 driver of a Sony HB-F1XD disk ROM:
`tools/turbor_diskrom/synth_diskrom.py`, also built inside the pack builder page. No ROM
content is in this repository; the tools patch your dumps and check the result's SHA-1.

The pack format also has an `MSXDOS2` block for the ASCII MSX-DOS 2.20 ROM, but no pack
uses it any more: with 2.20 active, *SD Snatcher* never runs its boot sector and *Illusion
City* corrupts its stack, so it was taken out of the 30 packs that carried it.

### SCC / SCC+ (IKASCC)
The SCC sound path is the die-shot-based IKASCC core, with the SCC+ extensions added.

- Real SCC, SCC-compatible, and SCC+ modes, with the private ch5 waveform RAM in SCC+
- Two SCC+ cartridges can play at once (one IKASCC per cart slot)
- Per-cartridge and per-channel mute in the audio menu

### Expanded slots
Each cartridge slot can be expanded into four sub-slots, each holding its own device:
`None / ROM / SCC / SCC+ / FM-PAC / GameMaster2` (GameMaster2 on slot A only).

- Bank and chip state is tracked per (slot, sub-slot)
- `SLOT A/B sub-slots` pages in the OSD select each sub-slot's device

### ASCII16-X mapper (large flash carts)
One `ASCII16X` menu entry covers both variants:

- ROM ≤ 4MB without an ASCII16X header → classic ASCII16 behaviour (SRAM, plain banking)
- ROM > 4MB, or any ROM with the `ASCII16X` signature at file offset 0x10 → ASCII16-X flash
  mapper laid out as a full 8MB chip, JEDEC/CFI command set (byte program and erase;
  buffer program `25h..29h` is not implemented)

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

### JoyMega pad
A Mega Drive pad on the MSX joystick port. The MSX toggles pin 8 of the port
and the pad answers with a different slice of itself on each of eight phases,
which is how six buttons fit through a port built for two. Phases 5 and 7 differ
only in the direction lines, and that is what software looks at to tell a
6-button pad from a 3-button one.

`JoyMega Pad` in the menu puts one on port A, port B or both. With it off the
port behaves exactly as it did before, as a plain two-button joystick.

The phase table is transcribed from openMSX `src/input/JoyMega.cc`, and the
testbench checks the RTL against that source's own masks and shifts rather than
against a re-typed copy of itself. It is always a 6-button pad: openMSX only
picks 3-button when Mode is held as the pad is plugged in, which has no meaning
for a USB pad that is simply always there.

### Pad buttons
Buttons the MSX cannot reach through the joystick port do something else instead
of going to waste.

- `A` / `B` are the port's two triggers when JoyMega is off, and the pad's A and
  B when it is on; `C`, `Start`, `X`, `Y`, `Z`, `Mode` are JoyMega only
- `Space`, `Return`, `F1` press that key in the keyboard matrix
- `Pause` freezes the machine without opening the OSD
- Either pad can press any of them, and nothing is taken away from the keyboard

Assign them once with `Define buttons` in the main MiSTer menu. A pad that has
never been through it falls back to a sensible A/B/X/Start/L/Y/R/Select layout.
For anything past this list -- a different key, a two-button chord, autofire --
the firmware's own `Advanced` button map does it without a core change.

### MIDI and MT32-pi
- `MIDI` (`On`/`Off`): an I/O-only MSX-MIDI (8251 + 8254) at `E8h-EFh` on any machine.
  The FS-A1GT's built-in MSX-MIDI comes from its pack, and `SLOT B` → `MU-PACK` puts a
  μ·PACK (Bit2) in slot B with its own MSX-MIDI; the menu says which one is active.
- MIDI OUT goes to the MiSTer's MIDI link (`UART`) and to the USER port at the same time.
  MIDI IN is not connected at present.
- An **MT32-pi** on the USER port gets its own `MT32-pi` page while it is detected:
  `Use MT32-pi`, `Show Info` (its LCD as an overlay), the default `Synth` (Munt /
  FluidSynth), `Munt ROM`, `SoundFont`, and `Reset Hanging Notes`. A popup shows the
  synth's mode when it changes, and notes still sounding after a machine reset are
  silenced.

### Reset on ROM change
`Reset on ROM change` (`Yes` by default). With `No` the machine is held, not reset, while a
new ROM is staged, so a mapper or ROM can be swapped under a running program. The slot,
sub-slot and mapper bank registers keep their old values across such a swap, which is why
`Yes` is the default; a flash cartridge (ASCII16X / Yamanooto) is always reset.

### Storage & saves
- `MegaFlashROM SCC+ SD` cartridge in slot A, with `Load SD card` mounting a `.VHD` image
  (Nextor-compatible FAT16, multi-partition images supported)
- `SRAM Save` / `SRAM Load`
- Flash saves for the ASCII16X and Yamanooto mappers: what the game programs into flash is
  persisted to a `.sav` (dirty-block tracking, so only changed 64KB blocks are written)
- `SRAM Autosave` — SRAM (the slot A `.sav` and `SRAM.NVR`) is saved automatically when the
  game's writes to it go quiet (~0.8 s), at the latest ~12.5 s after the first write, and at
  once before a ROM/pack load or an OSD reset. Opening the OSD does not save SRAM, so switching
  the option Off does not write first. Flash carts (ASCII16X / Yamanooto) still save when the
  OSD opens. With the option Off, only `SRAM Save` writes
- A blinking on-screen icon while a flash save is being written; a reset or a ROM load waits
  until any save has finished, so a save is never cut short
- A ROM cartridge in slot B has no SRAM; carts that save to SRAM belong in slot A

#### SRAM.NVR — FM-PAC, GameMaster2, machine SRAM, RTC settings
> **SRAM.NVR is NOT inside the machine / FW packs. Copy it to the board ONCE, by hand,
> then select it in the OSD under `SRAM(PAC/Turbo-R/...)`.**
> **Never copy a blank SRAM.NVR over one you already use — that erases your saves.**

- One 2 MB file holds the FM-PAC's PAC memory, GameMaster2, Halnote, the Panasonic
  (FS-A1ST / FS-A1GT) firmware SRAM and the RTC settings (SET SCREEN, SET BEEP, title, ...),
  one 64 kB entry each ([`docs/sram_images.md`](docs/sram_images.md)).
- Get an empty one from `createMSXpack.py` (written as `SRAM.NVR` next to the `MSX/` folder,
  deliberately not inside it), from the pack builder's **빈 SRAM.NVR 받기** button, or with
  `tools/sramimg/mk_sram_images.sh <dir>`. Put it anywhere on the SD card, e.g. `games/MSX1/`.
- Pick it once in the OSD: `SRAM(PAC/Turbo-R/...)`. The firmware remembers the choice
  (`config/MSX1.s1`) and mounts it at every core start. The firmware does not create or
  grow this file, so it has to be the full-size one.
- The save follows the device, not the slot: an FM-PAC saves to the same entry in slot A or
  B. With an FM-PAC (or GameMaster2) in both slots, only slot A's is saved.
- A `games/MSX1/boot1.vhd`, if present, is mounted on the same drive and takes precedence.

### Audio settings
A per-source mixer in the OSD, all on one 2 dB ladder (`0` .. `±8 dB`).

- Volume, mute and (for SCC) per-channel mute for PSG, MSX-MUSIC, SCC, and MoonSound PCM/FM
- Labels are dB versus unity, so `+8dB` is a real +8 dB

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
- Support two cartridges
- Automatic cartridge mapper detection
- Manual select mapper: `none, ASCII8, ASCII16X, Konami, KonamiSCC, KOEI, linear64, R-TYPE, WIZARDRY, Yamanooto, NEO-8, NEO-16`
  - The `ASCII16X` entry is one menu item for two mappers: a ROM of 4MB or less is read as plain
    **ASCII16** (8-bit banks, optional SRAM); a ROM above 4MB, or any ROM whose header carries the
    `ASCII16X` signature (file offset 0x10), is read as **ASCII16X** (12-bit banks, flash chip, no SRAM).
    An ASCII16X cart is always laid out as a full 8MB flash chip, whatever the image size.
    Automatic detection honours the same signature at any size; `NEO-8`/`NEO-16` carry theirs too.
- Joystick.
- FDD support (VY0010). Use DSK image
- Cassette support: analog input or CAS emulation
- PAL/NTSC mode
- Load BIOS for experiments

## Memory limitations
- With SDRAM (any size): ROM images up to 8MB per cartridge slot
  (ASCII16X / Yamanooto flash carts are exactly 8MB; NEO-8/16 images up to 8MB today)
- Without SDRAM (BRAM fallback): small ROMs only, 64kB machine RAM

## ROM BIOS
Load them manually from the menu

# Features MSX2
- reference HW Philips SVG8240/00
- RAM in slot 3/2
- Sound YM2149(PSG)
- Video V9938 (V9958 selectable)
- Support two cartridges
- Cartridge emulation:
  - Slot A: `ROM, SCC, SCC+, FM-PAC, MegaFlashROM SCC+ SD, GameMaster2, FDC, Empty`
  - Slot B: `ROM, SCC, SCC+, FM-PAC, Empty`
  - Either slot can instead be expanded into four sub-slots (see *Expanded slots* above)
- Automatic cartridge mapper detection
- Manual select mapper: `none, ASCII8, ASCII16X, Konami, KonamiSCC, KOEI, linear64, R-TYPE, WIZARDRY, Yamanooto, NEO-8, NEO-16`
  - The `ASCII16X` entry is one menu item for two mappers: a ROM of 4MB or less is read as plain
    **ASCII16** (8-bit banks, optional SRAM); a ROM above 4MB, or any ROM whose header carries the
    `ASCII16X` signature (file offset 0x10), is read as **ASCII16X** (12-bit banks, flash chip, no SRAM).
    An ASCII16X cart is always laid out as a full 8MB flash chip, whatever the image size.
    Automatic detection honours the same signature at any size; `NEO-8`/`NEO-16` carry theirs too.
- Selectable SRAM size (auto, 1kB-32kB, none)
- Joystick.
- FDD support.
- RTC support
- Cassette support: analog input or CAS emulation
- PAL/NTSC mode
- Load BIOS for experiments

## Memory limitations
- With SDRAM (any size): ROM images up to 8MB per cartridge slot
  (ASCII16X / Yamanooto flash carts are exactly 8MB; NEO-8/16 images up to 8MB today)
- Machine RAM comes from the machine pack — packs with 1MB / 2MB / 4MB memory mappers
  are provided (Sony HB-F1XDmk2, Panasonic FS-A1F, ...)
- Without SDRAM (BRAM fallback): small ROMs only, reduced machine RAM

## ROM BIOS
Copy bios files to Games/MSX1 folder or load them manually from the menu
- BIOS files use the `.MSX` file extension.
- Use the script `tools/CreateMSXPack/createMSXpack.py` to generate them.
- Refer to the XML files in the `Computer` and `Extension` directories to determine which BIOS ROM files are needed.
- Copy the required ROM files into the `tools/CreateMSXPack/ROM` directory.
- Then, run the `createMSXpack.py` script.
- The generated `.MSX` files will be located in the `tools/CreateMSXPack/MSX` directory.
- **`SRAM.NVR` (the save file for FM-PAC / GameMaster2 / machine SRAM / RTC) is written next
  to `MSX/`, not inside it. Copy it to the board once yourself and select it with
  `SRAM(PAC/Turbo-R/...)` in the OSD — see [SRAM.NVR](#sramnvr--fm-pac-gamemaster2-machine-sram-rtc-settings).**

### FW PACK (cartridge / extension firmware)
`Load FW PACK` supplies the firmware images used by the emulated cartridges — FM-PAC,
Game Master 2, MegaFlashROM SCC+ SD (Nextor) and the MoonSound wavetable.

| Extension | File | SHA1 |
|---|---|---|
| MOONSOUND | `yrw801.rom` | `32760893ce06dbe3930627755ba065cc3d8ec6ca` |

Place the ROMs in `tools/CreateMSXPack/ROM/` and build the pack with `createMSXpack.py`,
the same way as the BIOS pack.
