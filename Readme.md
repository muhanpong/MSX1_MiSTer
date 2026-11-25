# MSX2/MSX2++ for [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki) (WIP)

[MiSTer-devel/MSX1_MiSTer](https://github.com/MiSTer-devel/MSX1_MiSTer)의 포크에 HRA!의 V9968 VDP와 Geo3D 3D 엔진을 얹은 **실험판**이다. 일반 V9958 코어는 `nextz80` 브랜치에 있다. 자세한 설명과 검증 기록은 [docs/README_details.md](docs/README_details.md).

## 바로 쓰기

1. `releases/MSX1_20261124a_sdram128v9968_ec79e13.rbf`를 `_Computer/`에 복사한다.
2. 기계 팩·FW 팩을 넣는다([팩 만들기](#machine-and-fw-packs)).
3. SDRAM이 필요하다. 128MB 권장(실기 확인).

## 이 브랜치

- **V9968 VDP** — 모든 기계에서 V9968. VRAM 4MB(R#28–R#30 뱅크), 출력 31kHz. upstream v0.99.14 기준
- **주의** — v0.99.14부터 R#26/R#27은 쓰는 즉시 반영된다(줄 단위 래치 없음)
- **Geo3D v2.0.0** — 포트 9Dh/9Fh. OSD `Geo3D fill`을 HMMV로 하면 SCREEN 8에서 약 2배 빠르다. 데모 롬은 매퍼를 `ASCII16X`로 고른다
- **VDP 체크 툴 롬** — `releases/V9968_VDPTOOLS_20261124_688ab71.rom`. HRA!의 시험 프로그램 8종(MIT, © 2026 HRA!)을 메뉴에서 실행. A/Space 실행, B/ESC 복귀, 매퍼 auto. 소스는 `tools/vdptools/`
- **Y8960 카트리지** — hra1129의 [복합 음원 카트리지](https://github.com/hra1129/Y8960_Cartridge). `SLOT B`를 `Y8960`으로 고르고 BIOS `y8960bas.rom`을 그 슬롯 롬으로 로드한다. BIOS는 [MSX Sound Suite Extension](https://github.com/madscient/MsxSoundSuiteExtension) 릴리스에 있으며 개인 사용만 허용돼 여기서 배포하지 않는다. 실기 미확인
  - 카트리지의 SSG2·OPM·타이머·매퍼를 더하고, SSG1·OPLL·OPL2+ADPCM·SCC는 코어에 있는 PSG·OPLL·MSX-AUDIO·SCC가 맡는다
  - 꽂혀 있는 동안 `Audio Card`는 OSD 설정과 상관없이 MSX-AUDIO로 동작한다(MoonSound는 못 씀)
  - 없는 것: 채널별 팬, OPLL 음색 뱅크, OPL2 파형 선택, 시스템 컨트롤러(플래시 갱신)
- **OSD** — `VDP command speed`(V9968/V9938), `R800 VDP access wait`(기본 8.66µs, 98h–9Bh에만)
- **upstream과 다른 점** — FH·인터럽트 규칙 등. 항목과 이유는 `rtl/video/v9968/ORIGIN.md`

## 릴리스

| rbf | 내용 | 상태 |
|---|---|---|
| **20261124a** `ec79e13` | V9968 v0.99.14, VRAM 4MB, Y8960 카트리지 | 128MB 실기 확인 (Y8960 미확인) |
| 20261113a `7e4e67a` | MSX-AUDIO 추가 | 실기 확인 |
| 20261111a `45b8fb3` | V9968 v0.99 | JoyMega 3버튼 결함 — 쓰지 말 것 |
| 20261029d `923140c` | OPL4 PCM engine3 | |

이전 파일도 `releases/`에 있다.

## 알려진 문제

- 32MB 보드는 기계 RAM이 최대 2MB다(4MB 팩도 2MB로 동작). 롬·RAM 영역: 128MB 보드 28MB, 64MB 32MB, 32MB 24MB
- MSX1 기계도 MSX2 팔레트로 나온다

## 라이선스

V9968 RTL은 HRA!의 조건(**허가 없는 상업적 이용 금지**)을 따른다. Geo3D와 VDP 체크 툴의 시험 프로그램은 MIT.

---

## Features

**Sound**
- **MoonSound (OPL4)** — FM + PCM, 2MB sample RAM. Needs `yrw801.rom` (FW pack) and a pack with the `MOONSOUND` record
- **MSX-AUDIO (Y8950)** — OSD `Audio Card`. Ports C0h/C1h. No BIOS ROM. Not together with MoonSound
- **Y8960 Cartridge** — hra1129's combo sound cart. `SLOT B` = `Y8960`, then load its BIOS `y8960bas.rom` (not included: personal use only). Adds SSG2, OPM, timer and mapper; the core's PSG, OPLL, MSX-AUDIO and SCC play the rest. The Audio Card is MSX-AUDIO while it is in
- **SCC / SCC+** — IKASCC, two SCC+ at once
- **MIDI** — MSX-MIDI at E8h–EFh on any machine, μ·PACK in slot B, MT32-pi on the USER port
- **Mixer** — per-source volume ±8dB and mute, per-channel SCC mute (`Video & Audio settings`)

**CPU and machines**
- **turbo R** — FS-A1GT / FS-A1ST packs; R800 7.16 / 21.5 MHz; Z80 ↔ R800 by software or OSD
- **Z80 turbo** — 5.37 / 7.16 / 10.7 / 21.5 MHz
- **turbo R disk ROM** — built from your own dumps (WD2793 driver)

**Cartridges**
- **Mappers** — ASCII16-X (flash, up to 8MB), NEO-8 / NEO-16 (up to 64MB), Yamanooto. ASCII16-X and NEO are recognised by their header signature
- **ASCII16X entry** — ≤ 4MB without header = plain ASCII16; > 4MB or `ASCII16X` header at 10h = flash mapper
- **MegaFlashROM SCC+ SD** — slot A, with a `.VHD` SD image (Nextor)
- **Expanded slots** — four sub-slots per cartridge slot
- **Cheats** — `.gg` files

**Saves**
- **Flash carts** (ASCII16X / Yamanooto) save to `.sav`
- **SRAM Autosave** — saves when writes stop
- **SRAM.NVR** — one file for FM-PAC, GameMaster2, Halnote, turbo R SRAM and RTC. **Not in the packs: copy it to the SD card once and select it in the OSD (`SRAM(PAC/Turbo-R/...)`). Never overwrite one you already use.** Get an empty one from the pack builder or `createMSXpack.py`

**Input and misc**
- **JoyMega** — 3/6-button Mega Drive pad on the joystick port
- **Pad buttons** — spare buttons press Space, Return, F1 or Pause (`Define buttons`)
- **Pause** — on OSD open or by hotkey
- **Reset on ROM change** — `No` holds the machine while a ROM is swapped
- **From upstream** — FDD (DSK), cassette (CAS or audio in), RTC, PAL/NTSC, two cartridge slots

## Machine and FW packs

Build packs from your own ROM dumps:

- In a browser: [pack builder](https://muhanpong.github.io/MiSTer/packbuilder.html) (offline, no upload)
- Or: put the ROMs in `tools/CreateMSXpack/ROM/` and run `tools/CreateMSXpack/createMSXpack.py`

Copy the `.MSX` files to `games/MSX1/`. The FW pack carries the cartridge firmware (FM-PAC, GameMaster2, MegaFlashROM SCC+ SD, MoonSound `yrw801.rom`).

## Build

```
REV=MSX1_V9968 ASM=1 tools/sdram128/compile.sh      # V9968 build (Quartus 17.0, SEED=N)
tools/sdram128/compile.sh                           # plain V9958 build
```
