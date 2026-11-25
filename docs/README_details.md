# MSX2/MSX2++ for MiSTer — full notes (V9968_Geo3D)

The short version is the [Readme](../Readme.md). This page keeps every detail: verification notes, history, and the per-feature explanations.

A fork of [MiSTer-devel/MSX1_MiSTer](https://github.com/MiSTer-devel/MSX1_MiSTer) that adds
MoonSound (YMF278B/OPL4), turbo R machines with an R800, a Z80 turbo, MSX-MIDI with
MT32-pi support, IKASCC-based SCC+, the ASCII16-X and NEO-8/16 mappers, expanded slots,
standard OSD cheats, extended saves, and a number of VDP accuracy fixes.

이 브랜치(`V9968_Geo3D`)는 그 위에 HRA!의 V9968 VDP와 Geo3D 3D 엔진을 얹은 **실험판**이다.
*This branch (`V9968_Geo3D`) adds HRA!'s V9968 VDP and the Geo3D engine on top: **experimental**.*

---

## 이 브랜치: V9968_Geo3D / This branch: V9968_Geo3D

기존 V9958 코어는 `nextz80` 브랜치에 있다.
*The regular V9958 core lives on the `nextz80` branch.*

### 바로 쓰기 / Quick start

1. `releases/MSX1_20261124a_sdram128v9968_ec79e13.rbf`를 MiSTer의 `_Computer/`에 복사한다(현재판).
   *Copy the current rbf to `_Computer/` on the MiSTer.*
2. 기계 팩·FW 팩은 기존 코어와 같다(아래 MSX2의 [ROM BIOS](#rom-bios-1)). SDRAM 모듈이 필요하다. 128MB 보드를 권장한다(실기 확인). 64MB·32MB 보드도 동작하지만 32MB 보드에는 제한이 있다(아래 알려진 문제).
   *Machine and FW packs are the same as for the regular core (see [ROM BIOS](#rom-bios-1) under MSX2). An SDRAM module is required. A 128MB board is recommended (confirmed on the board); 64MB and 32MB boards work too, with a limit on 32MB (see Known issues).*
3. VDP 점검용으로 `releases/V9968_VDPTOOLS_20261124_688ab71.rom`을 카트리지로 넣을 수 있다(매퍼 auto, 아래 참고).
   *For a VDP check, load `releases/V9968_VDPTOOLS_20261124_688ab71.rom` as a cartridge (mapper on auto; see below).*

### 무엇이 다른가 / What is different

- **V9968 VDP** — HRA!의 [V9968_Cartridge](https://github.com/hra1129/V9968_Cartridge) RTL을 내부 VDP로 쓰는 별도 빌드(Quartus 리비전 `MSX1_V9968`). 모든 기계 종류에서 V9968로 동작하고, VRAM 4MB(256KB × 16뱅크, R#28–R#30)는 SDRAM에 있으며, 출력은 31kHz다
  *A separate build (Quartus revision `MSX1_V9968`) with HRA!'s V9968 RTL as the internal VDP on every machine type; 4MB VRAM (16 banks of 256KB, R#28–R#30) in SDRAM; 31 kHz output.*
- **upstream V9968 v0.99.14** (453d5f3, 20261124a부터) — 4MB VRAM 뱅크(R#28 CPU, R#29 배경/스프라이트, R#30 명령 소스/목적지), V9958 표와 같은 명령 종료 상태, 인터럽트 정리(F/FH를 실시간으로 읽음), SP3·SCREEN 8·YJK 스프라이트 수정
  *4MB VRAM banks (R#28 CPU, R#29 background / sprites, R#30 command source / destination), command end state as the V9958's table, interrupt rework (F / FH read live), SP3 / SCREEN 8 / YJK sprite fixes.*
  - **주의: R#26/R#27은 이제 줄 단위로 래치되지 않고 쓰는 즉시 반영된다**(V9958·openMSX와 같음). 라인 인터럽트에서 가로 스크롤을 바꾸는 소프트는 쓰는 시각에 따라 결과가 달라진다
    ***Note: R#26 / R#27 are no longer latched per line; a write takes effect at once** (as on the V9958 and in openMSX). Software that changes the horizontal scroll from a line interrupt now depends on when it writes.*
  - 32MB 보드는 DQM이 A11/A12에 묶여 있어 VRAM 위쪽 2MB를 bank 3 행 01에 두고, SDRAM 컨트롤러가 가려진 워드를 다시 읽는다(`docs/sdram_tdm_design.md` 15절)
    *On 32MB boards (DQM tied to A11/A12) the upper 2MB of VRAM sits on bank 3's rows 01 and the SDRAM controller re-reads the masked words (`docs/sdram_tdm_design.md` section 15).*
- **Geo3D v2.0.0** — Alex Moncks의 3D 엔진. 포트 9Dh/9Fh, 42.95MHz
  *Alex Moncks' 3D engine on ports 9Dh/9Fh at 42.95 MHz.*
  - OSD `Geo3D fill (SCREEN 8)`: LINE(기본) / HMMV. HMMV를 고르면 SCREEN 8에서 면의 가로줄을 HMMV 한 번으로 칠해 그리기가 약 2배 빨라진다(이 코어에만 있는 옵션)
    *OSD `Geo3D fill (SCREEN 8)`: LINE (default) / HMMV. With HMMV a face row in SCREEN 8 goes out as one HMMV, about twice as fast (an option of this core only).*
  - Geo3D 데모는 내장 98h 판을 쓴다. 데모의 ASCII16 롬은 자동 판별이 틀리므로 OSD 매퍼를 `ASCII16X`로 고르거나 파일 오프셋 10h에 `ASCII16X` 헤더를 넣는다
    *Use the internal 98h builds of the demos. Auto-detect gets their ASCII16 ROMs wrong: pick `ASCII16X` in the OSD mapper menu, or put an `ASCII16X` header at file offset 10h.*
- **SDRAM 128.86MHz** — 고정 12클럭 TDM 컨트롤러(`rtl/peripheral/sdram_tdm.sv`). V9968 VRAM은 bank 3 전용 슬롯을 쓴다
  *A fixed 12-clock TDM SDRAM controller; the V9968's VRAM has its own slot in bank 3.*
- **OPL4 PCM engine3** — 새로 만든 PCM 엔진(20261029d부터 기본). 슬롯 제어를 프레임 경계에 모아 처리하고, 웨이브 데이터는 정해진 시각에 읽는다. openMSX(`YMF278.cc`) 기준 골든 23개 시나리오와 비트 단위로 일치하고, ALM은 2,815 → 1,291로 줄었다. 이전 엔진은 `PCM_ENGINE2=1 tools/sdram128/mk_v9968_qsf.sh`로 빌드한다
  *A rebuilt PCM engine (default from 20261029d): slot control bunched at the frame edge, wave data read at fixed times; bit-exact with the openMSX-based golden model on 23 scenarios; 2,815 → 1,291 ALM. Build the previous engine with `PCM_ENGINE2=1 tools/sdram128/mk_v9968_qsf.sh`.*
- **OSD** — `VDP command speed V9968/V9938`(명령 대기를 V9938 속도에 맞춤). `Scandoubler Fx`의 CRT 25/50/75%는 V9968 자체 스캔라인으로 동작한다
  *`VDP command speed V9968/V9938` (V9938-paced command waits); the CRT 25/50/75% choices of `Scandoubler Fx` drive the V9968's own scanlines.*
- **R800/터보 VDP 대기 / R800 and turbo VDP waits** — R800의 VDP 대기(8.66µs)는 실기 turbo R처럼 98h–9Bh에만 걸린다. Geo3D 포트 9Dh/9Fh에는 대기가 없어 R800에서 Geo3D가 빨라진다. 터보 Z80에는 VDP 간격 대기가 없다(V9968 버스는 요청을 잃지 않는다). OSD `R800 VDP access wait`: 8.66µs(실기, 기본), None, 1.0–7.5µs
  *The R800 VDP wait (8.66 µs) covers 98h–9Bh only, as on a turbo R; Geo3D's 9Dh/9Fh have no wait, so Geo3D is faster on the R800. A turbo Z80 gets no VDP spacing (the V9968 bus cannot drop a request). OSD `R800 VDP access wait`: 8.66 µs (real, default), None, 1.0–7.5 µs.*
- **화면 폭 / Width** — upstream 8a37b33의 가로 표시 폭(1600→1440 클럭)을 반영
  *upstream 8a37b33's horizontal display width (1600 → 1440 clocks).*

### VDP 체크 툴 롬 / VDP check tools ROM

`releases/V9968_VDPTOOLS_20261124_688ab71.rom` — HRA!의 [V9968_Cartridge](https://github.com/hra1129/V9968_Cartridge) `test/` 시험 프로그램 8종(upstream 453d5f3, **MIT, © 2026 HRA!**)을 디스크나 MSX-DOS 없이 메뉴에서 실행하는 512KB ASCII16 롬이다.
*HRA!'s V9968_Cartridge `test/` programs (upstream 453d5f3, **MIT, (c) 2026 HRA!**) on one 512KB ASCII16 ROM with a menu; no disk or MSX-DOS needed.*

| 프로그램 / Program | 내용 / What it checks |
|---|---|
| VDPCHK | 레지스터·VRAM·명령 자가 점검 / registers, VRAM, commands |
| VDPREG | 명령 종료 후 레지스터 / registers after a command ends |
| VDPVIEW | 그림 P01–P19 / pictures P01–P19 |
| VDPINT | 라인 인터럽트 그림 P20–P23 / line-interrupt pictures P20–P23 |
| VDPDIAG | 화면 모드 전환 진단 / screen-mode switching |
| VRAMSTRS | VRAM 부하(3회) / VRAM stress (3 rounds) |
| VDPTEST | 명령 종료 부하 / command termination stress |
| VRAMRW | VRAM 읽기·쓰기 경로 / VRAM read and write paths |

- 조작: 커서 키나 조이스틱으로 고르고 Space·A 버튼으로 실행, 끝나면 ESC·B 버튼으로 메뉴로 돌아온다. 프로그램 안에서도 A 버튼은 Space, B 버튼은 ESC다
  *Cursor keys or joystick to choose, SPACE or button A to run, ESC or button B back to the menu. Inside the programs A is SPACE and B is ESC.*
- OSD 매퍼는 auto로 둔다(ASCII16으로 판별된다). 파일을 쓰지 못하므로 결과는 화면으로만 본다
  *Leave the OSD mapper on auto (it is detected as ASCII16). There is no file output; results are on screen only.*
- 소스·빌드·openMSX 시험은 `tools/vdptools/`, 라이선스 원문은 `tools/vdptools/LICENSE_V9968_Cartridge.txt`
  *Source, build and openMSX checks: `tools/vdptools/`; licence text: `tools/vdptools/LICENSE_V9968_Cartridge.txt`.*

### upstream V9968에 더한 수정 / Fixes on top of upstream V9968

모두 `rtl/video/v9968/ORIGIN.md`에 재현 방법과 함께 적어 두었다. upstream 보고 초안은 `docs/upstream_issues_v9968_20261022.md`.
*All recorded with repro commands in `rtl/video/v9968/ORIGIN.md`; upstream report drafts in `docs/upstream_issues_v9968_20261022.md`.*

- 화면을 끌 때 붙잡힌 스프라이트 VRAM 요청이 VDP 명령을 멈춤 *(a sprite VRAM request held across display-off froze VDP commands)*
- R#9 LN을 프레임 중간에 바꾸면 화면 시작이 10줄 움직임(224라인 오버스캔) *(a mid-frame R#9 LN change moved the display start by 10 lines)*
- status 읽기와 같은 클럭의 인터럽트 이벤트 유실, 그리고 한 클럭 늦은 status 래치로 인한 FH/F 유실 *(interrupt events lost on the clock of a status read, and FH/F lost through the one-clock-late status latch)*
- 프레임 인터럽트 시점에 FH가 지워져, S#1을 늦게 읽는 라인 인터럽트 처리가 FH=0을 봄 — ASO 224(R800) 검은 화면의 원인, 실기 확인 *(FH was cleared at the frame interrupt, so a line-interrupt handler that reads S#1 late saw FH = 0 — the cause of ASO 224's black screen; confirmed on hardware)*
- IE1이 꺼져 있어도 FH가 세워짐 — 위 수정 뒤 VBLANK까지 남아 Knightmare 224 v2가 시작되지 않던 원인(20261024b~20261027a). 20261029a부터 수정, 실기 확인 *(FH was set with IE1 off; after the fix above it survived into VBLANK and Knightmare 224 v2 did not start on 20261024b–20261027a; fixed from 20261029a, confirmed on hardware)*
- 명령 실행 중 CPU 쓰기가 두 번 실행됨 — R800 VDP 대기를 낮추면 SUPER CAT·PRISM FLIGHT 화면이 깨지던 원인. 20261025b부터 수정(a85c175), 실기 확인 *(the V9968 ran a CPU write twice while a command was running — SUPER CAT / PRISM FLIGHT broke at a short R800 VDP wait; fixed from 20261025b, a85c175, confirmed on hardware)*

v0.99.14 병합 뒤에도 위의 FH 규칙 두 가지는 이 코어 쪽 것을 유지한다.
*The two FH rules above are kept after the v0.99.14 merge.*

### 릴리스 / Releases (`releases/`)

| 파일 / File | 내용 / Contents | 비고 / Note |
|---|---|---|
| **`MSX1_20261124a_sdram128v9968_ec79e13.rbf`** | 현재판: upstream V9968 v0.99.14, VRAM 4MB, Y8960 카트리지(`SLOT B` = `Y8960`, BIOS 별도)<br>*current: V9968 v0.99.14, 4MB VRAM, the Y8960 cartridge (BIOS not included)* | 128MB 보드 실기 확인, Y8960은 미확인<br>*confirmed on a 128MB board; Y8960 not yet checked* |
| `MSX1_20261113a_sdram128v9968_7e4e67a.rbf` | MSX-AUDIO 추가(OSD `Audio Card`: MoonSound / MSX-AUDIO / None), `JoyMega Buttons`가 Slot A 카트리지 종류와 설정 비트를 같이 쓰던 문제 수정<br>*MSX-AUDIO added; the `JoyMega Buttons` option no longer shares a setting bit with the slot A cartridge type* | 실기 확인 / confirmed on the board |
| `MSX1_20261111a_sdram128v9968_45b8fb3.rbf` | upstream V9968 v0.99(2a99ac9), 16번째 스프라이트, R800 OTIR 첫 바이트 간격, JoyMega 수정<br>*V9968 v0.99, the 16th sprite, R800 OTIR first-byte spacing, the JoyMega fix* | **JoyMega를 3버튼으로 두면 Slot A 카트리지 종류가 바뀜 — 20261113a 이후를 쓸 것**<br>***Its 3-button JoyMega setting changes the slot A cartridge type — use 20261113a or later*** |
| `MSX1_20261029d_sdram128v9968_923140c.rbf` | PCM engine3, V9968 FH 수정, Geo3D HMMV 옵션<br>*engine3, the V9968 FH fix, the Geo3D HMMV option* | |
| `MSX1_20261029c_sdram128v9968_9b1cea1.rbf` | 같은 수정에 이전 PCM 엔진(engine2)<br>*the same fixes with engine2* | 비교용 / for comparison |

그 전 rbf(20261025b, 20261027a, 20261029a)도 `releases/`에 그대로 있다.
*The earlier rbfs (20261025b, 20261027a, 20261029a) stay in `releases/`.*

### 빌드 / Build

`REV=MSX1_V9968 ASM=1 tools/sdram128/compile.sh` (Quartus 17.0). `SEED=N`으로 시드를 지정하고, 시드 비교는 `tools/sdram128/seed_table.sh`로 한다. 일반 V9958 빌드는 `tools/sdram128/compile.sh`.
*Quartus 17.0; `SEED=N` picks the fitter seed and `tools/sdram128/seed_table.sh` compares seeds. The plain V9958 build is `tools/sdram128/compile.sh`.*

### 라이선스 / Licence

V9968 RTL 파일 헤더는 HRA!의 3조항 조건을 따른다(**허가 없는 상업적 이용 금지** 포함). Geo3D와 VDP 체크 툴의 시험 프로그램은 MIT다.
*The V9968 RTL file headers carry HRA!'s 3-clause terms (including **no commercial use without written permission**). Geo3D and the test programs in the VDP check tools ROM are MIT.*

### 알려진 문제 / Known issues

- SDRAM의 일부는 V9968 VRAM 몫이라, 롬·기계 RAM·MoonSound 샘플이 들어가는 일반 영역은 128MB 보드 28MB, 64MB 보드 32MB, 32MB 보드 24MB다. 가장 큰 구성(4MB 기계 + MoonSound + 8MB 카트 2개)이 약 24.4MB여서, **32MB 보드에서는 기계 RAM이 최대 2MB로 줄어든다**(4MB 팩도 2MB로 동작)
  *Part of the SDRAM belongs to the V9968's VRAM, so the general area (ROMs, machine RAM, MoonSound samples) is 28MB on a 128MB board, 32MB on a 64MB board and 24MB on a 32MB board. The largest setup (a 4MB machine + MoonSound + two 8MB carts) is about 24.4MB, so **on a 32MB board the machine RAM is capped at 2MB** (a 4MB pack runs with 2MB).*
- MSX1 기계도 MSX2 표준 팔레트로 표시된다
  *MSX1 machines show the MSX2 standard palette.*

---

## 이 포크가 더한 것 / What this fork adds (summary)

**새로 생긴 것 / New**

- **MoonSound (OPL4)** — YMF278B FM + PCM 웨이브테이블 엔진, 2MB 샘플 RAM
  *YMF278B FM plus the PCM wavetable engine, with 2MB of sample RAM.*
- **MSX-AUDIO (Y8950)** — MoonSound의 OPL3를 FM으로 쓰고 ADPCM·타이머·샘플 RAM을 더했다. MoonSound와 동시에는 못 쓴다(OSD `Audio Card`). ADPCM은 openMSX와 샘플 단위로 일치(VGMPlay로 재생한 6곡). BIOS ROM 없음 — 포트를 직접 쓰는 소프트용
  *The MoonSound's OPL3 as the FM part, plus ADPCM, timers and sample RAM. Exclusive with MoonSound (OSD `Audio Card`). The ADPCM matches openMSX sample for sample (six tunes played by VGMPlay). No BIOS ROM: for software that drives the ports itself.*
- **Y8960 Cartridge** — [hra1129의 복합 음원 카트리지](https://github.com/hra1129/Y8960_Cartridge). 카트리지의 SSG2·OPM·타이머·매퍼를 더하고, SSG1·OPLL·OPL2+ADPCM·SCC는 코어에 이미 있는 PSG·OPLL·MSX-AUDIO·SCC가 맡는다. `SLOT B`를 `Y8960`으로 고르고 BIOS ROM을 로드한다
  *[hra1129's combo sound cartridge](https://github.com/hra1129/Y8960_Cartridge). Its SSG2, OPM, timer and mapper are added; its SSG1, OPLL, OPL2 + ADPCM and SCC are the PSG, OPLL, MSX-AUDIO and SCC the core already has. Set `SLOT B` to `Y8960` and load its BIOS ROM.*
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
- **Video & Audio settings** — 영상 설정과 같은 페이지에 음원별 게인 ±8dB, 뮤트, SCC 채널별 뮤트
  *On the same OSD page as the video settings: per-source gain (±8dB), mute, and per-channel SCC mute.*
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
- OPL4 웨이브 레지스터를 읽으면 쓴 값이 돌아옴 (전에는 reg 2·6 말고 0) — 읽고-고쳐-쓰는 곡 정지 루틴이 팬을 지우던 문제(*Neon Horizon*)
  *OPL4 wave registers read back what was written (all but reg 2 and 6 used to read 0), so a read-modify-write stop routine no longer wipes the pan (Neon Horizon).*
- R#9 LN 전환으로 화면이 끝나지 않는 프레임(오버스캔)에서도 스프라이트 표시 — 위 보더 첫 줄들, LN 1→0 전환 직후
  *Sprites in frames where an R#9 LN switch keeps the display from ending (overscan): on the first top-border lines and right after an LN 1→0 switch.*

아래는 항목별 상세 / Details below.

---

## What this fork adds

### MSX-AUDIO (Y8950)
`Audio Card` = `MSX-AUDIO`. The FM part is the MoonSound's OPL3 run as an OPL at the Y8950's
49716 Hz; ADPCM (sample RAM and CPU-fed), both timers with `/INT`, the 8-bit DAC and register
read-back are added.

- Ports `0xC0` (register / status) and `0xC1` (data); `0xC2/0xC3` stay free
- Sample RAM: **256 KB when the pack carries the `MOONSOUND` record** (it lives in the
  MoonSound's wave RAM area), 32 KB otherwise. VGMPlay needs the 256 KB
- The mute and volume rows are shared with the MoonSound: `PCM/ADPCM` acts on the ADPCM
- Not there: the BIOS ROM (FS-CA1 / NMS-1205 software that calls it), recording, CSM speech,
  the keyboard and I/O port
- Checked with `sim/msx_audio/replay_omsx.sh`: a VGM played by VGMPlay on openMSX, its port
  log replayed through the RTL, ADPCM output compared with openMSX's own channel recording

### Y8960 Cartridge
[Y8960 Cartridge](https://github.com/hra1129/Y8960_Cartridge) by hra1129 (upstream `a83d807`) is
SSG x2, OPLL, OPL2 + ADPCM, SCC and OPM behind an SCC-style mapper with 128 KB BIOS ROM and
128 KB RAM. The machine already has most of those chips, so the core adds only what it lacks
and lets its own chips play the rest:

| Cartridge chip | Here |
|---|---|
| SSG1 | the main PSG (also reached through `7FF0h`/`7FF1h`) |
| SSG2 | upstream `ssg_core` (registers `10h`-`1Fh`, read at `A2h`) |
| OPLL | the core's OPLL (`7Ch`/`7Dh`, `7FF4h`/`7FF5h`) |
| OPL2 + ADPCM | the Audio Card as MSX-AUDIO (`C0h`/`C1h`, `7FF2h`/`7FF3h`) |
| SCC | the SCC of the cartridge's slot |
| OPM (YM2151) | upstream IKAOPM (`7Eh`/`7Fh`, `7FFBh`/`7FFCh`) |
| timer (`B0h`-`B3h`), I/O enablers, mapper | upstream / `y8960_cart.sv` |

- **How to use**: set `SLOT B` to `Y8960` and load the cartridge's BIOS as that slot's ROM
  (the mapper is fixed; with no ROM loaded the slot is empty). The BIOS is `y8960bas.rom` from
  [MSX Sound Suite Extension](https://github.com/madscient/MsxSoundSuiteExtension) releases
  (personal use only, not redistributable, so it is not in any pack here). Software finds the
  cartridge by the ROM header, so a ROM image has to be there. One Y8960, on SLOT B only
- **While a Y8960 is in a slot the Audio Card is an MSX-AUDIO**, whatever the OSD says (the
  MoonSound shares its OPL3 and is not available then). `C0h`/`C1h` answer once the cartridge's
  enabler (`7FFFh` bit 0) is set. The ADPCM sample RAM follows the MSX-AUDIO rule above
  (256 KB with the `MOONSOUND` record in the pack, 32 KB otherwise)
- **Mixer volume registers** (`7FF7h`-`7FFAh`, `7FFDh`, `7FFEh`; 0-128) act on top of the OSD
  volumes: SSG on every PSG, OPLL on the OPLL, OPL2 on the Audio Card's output, SCC on every
  SCC, OPM on the OPM, and the master on all of those. Key click, cassette input and the
  turbo R PCM are not affected. With no cartridge every factor is exactly 1
- **Timer**: counts in units of the cartridge's 42.95 MHz system clock, as the BIOS expects
  (the core clocks it at 21.48 MHz and steps it by two)
- **Not there**: the per-channel pan registers, the OPLL voice banks and the OPL2 waveform
  select (the reused chips do not have them), and the system controller (I/O `40h`-`4Fh`, the
  cartridge's flash updater). The OPLL voices are the YM2413's own; the cartridge's bank 0 is
  a re-creation that differs slightly in 13 of the 15 melodic voices
- Checks: `sim/y8960/run.sh` (the wrapper alone; the core's 21.48 MHz clocking against
  upstream's 42.95 MHz), `sim/fullsys/yprobe/run.sh` (through the whole machine)

### MoonSound (YMF278B / OPL4)
Full OPL4 emulation — OPL3-compatible FM plus the PCM wavetable engine.

- Ports `0x7E/0x7F` (WAVE) and `0xC4-0xC7` (FM), `/WAIT` and `/INT` handled like the real cartridge
- 2MB sample RAM in addition to the wavetable ROM
- Wave registers read back what was written, as `regs[reg]` does in openMSX (software that
  reads, modifies and writes back the pan / LFO registers keeps them)
- Menu: `Audio Card` (MoonSound / MSX-AUDIO / None), `PCM/ADPCM Mute`, `Card FM Mute`, `PCM/ADPCM Volume`, `Card FM Volume` (2 dB steps), `Debug Overlay`
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
  the way a real turbo R does (`8.66us`, the default) -- on the V9958 build, without it R800
  software that writes the VDP back to back drops data (the V9968 build does not drop writes;
  see above).
- The R800 is NextZ80 run at the R800's clock: fast, but not cycle-exact R800 timing.
- **PCM** (`rtl/peripheral/turbor/`): the 8-bit D/A at `A4h` (write: sample; read: the 15.7 kHz
  counter) and `A5h` (BUFF / MUTE / FILT / SEL / SMPL, read bit 7 = comparator), following
  openMSX `MSXTurboRPCM.cc`. The MUTE bit silences all sound, as on the real machine, but only
  after software has written `A5h`. The BIOS `PCMPLY` (0186h) is played in hardware: the CPU
  is held while `pcm_play.sv` reads the samples from RAM at 15.75 / 7.875 / 5.25 / 3.94 kHz,
  and CTRL+STOP aborts with carry set. Not implemented: `PCMPLY` from VRAM and `PCMREC`
  (both return at once, carry clear). The PCM has no OSD volume or mute row.
- The `CPU` page shows the R800 rows only on a turbo R pack, and only the Z80 ladder on any
  other machine.

#### Machine packs
Packs are built from your own ROM dumps with `tools/CreateMSXpack/createMSXpack.py`, or in a
browser with the offline pack builder: [`tools/CreateMSXpack/packbuilder.html`](../tools/CreateMSXpack/packbuilder.html)
(hosted at <https://muhanpong.github.io/MiSTer/packbuilder.html>; see
[`PACKBUILDER.md`](../tools/CreateMSXpack/PACKBUILDER.md)). The page reads a ROM folder or a
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
against a re-typed copy of itself. `JoyMega Buttons` picks a 6-button (default)
or a 3-button pad; openMSX picks 3-button when Mode is held as the pad is plugged
in, which has no meaning for a USB pad that is simply always there. The phase
steps only on a pin-8 edge that disagrees with it, as openMSX does, so the first
edge after the 1.5 ms timeout reads phase 0.

The triggers are read as the pad gives them; the R#15 pin 6/7 outputs are not
applied (nothing is wired to those pins). See
[`docs/joystick_pin67_outputs.md`](joystick_pin67_outputs.md).

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
  one 64 kB entry each ([`docs/sram_images.md`](sram_images.md)).
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
A per-source mixer in the OSD, all on one 2 dB ladder (`0` .. `±8 dB`). It is on the
`Video & Audio settings` page, below the video rows.

- Volume, mute and (for SCC) per-channel mute for PSG, MSX-MUSIC, SCC, and MoonSound PCM/FM
- Labels are dB versus unity, so `+8dB` is a real +8 dB

### VDP accuracy
Several timing and behaviour fixes measured against real hardware and openMSX. They are in
the V9938/V9958 VDP of the regular build; the `MSX1_V9968` build uses the V9968 instead (see
the top of this page):

- Sprite pipeline restricted to display-area lines — removes ghost `S#0` collisions that
  made `ON SPRITE` traps fire continuously (sprites parked at Y=209 by `CLRSPR`)
- Real-chip vblank IRQ position, per-scanline VDP command throttling, positional `VR` flag
- `FH` flag armed only while `IE1` is enabled
- Overscan frames — when an R#9 LN switch past the end line keeps the display from ending
  (*km224*, *ASO*), the next frame's top-border lines and the lines after an LN 1→0 switch
  show their sprites, matched line by line against an openMSX table
- Optional V9958 mode

---

# Features MSX1
- reference HW Philips SVG8020/00
- RAM 64kB in slot 3
- Sound YM2149(PSG)
- Support two cartridges
- Automatic cartridge mapper detection
- Manual select mapper: `none, ASCII8, ASCII16X, Konami, KonamiSCC, KOEI, linear64, R-TYPE, WIZARDRY, Yamanooto, NEO-8, NEO-16`
  - `ASCII16X` covers plain ASCII16 too: see [ASCII16-X mapper](#ascii16-x-mapper-large-flash-carts) above
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
Load them manually from the menu.

# Features MSX2
- reference HW Philips SVG8240/00
- RAM in slot 3/2
- Sound YM2149(PSG)
- Video V9938 (V9958 selectable; the V9968 in the `MSX1_V9968` build)
- Support two cartridges
- Cartridge emulation:
  - Slot A: `ROM, SCC, SCC+, FM-PAC, MegaFlashROM SCC+ SD, GameMaster2, FDC, Empty`
  - Slot B: `ROM, SCC, SCC+, FM-PAC, Empty`
  - Either slot can instead be expanded into four sub-slots (see *Expanded slots* above)
- Automatic cartridge mapper detection
- Manual select mapper: `none, ASCII8, ASCII16X, Konami, KonamiSCC, KOEI, linear64, R-TYPE, WIZARDRY, Yamanooto, NEO-8, NEO-16`
  - `ASCII16X` covers plain ASCII16 too: see [ASCII16-X mapper](#ascii16-x-mapper-large-flash-carts) above
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
Copy the BIOS files to the `games/MSX1` folder, or load them manually from the menu
- BIOS files use the `.MSX` file extension.
- Use the script `tools/CreateMSXpack/createMSXpack.py` to generate them.
- Refer to the XML files in the `Computer` and `Extension` directories to determine which BIOS ROM files are needed.
- Copy the required ROM files into the `tools/CreateMSXpack/ROM` directory.
- Then, run the `createMSXpack.py` script.
- The generated `.MSX` files will be located in the `tools/CreateMSXpack/MSX` directory.
- **`SRAM.NVR` (the save file for FM-PAC / GameMaster2 / machine SRAM / RTC) is written next
  to `MSX/`, not inside it. Copy it to the board once yourself and select it with
  `SRAM(PAC/Turbo-R/...)` in the OSD — see [SRAM.NVR](#sramnvr--fm-pac-gamemaster2-machine-sram-rtc-settings).**

### FW PACK (cartridge / extension firmware)
`Load FW PACK` supplies the firmware images used by the emulated cartridges — FM-PAC,
Game Master 2, MegaFlashROM SCC+ SD (Nextor) and the MoonSound wavetable.

| Extension | File | SHA1 |
|---|---|---|
| MOONSOUND | `yrw801.rom` | `32760893ce06dbe3930627755ba065cc3d8ec6ca` |

Place the ROMs in `tools/CreateMSXpack/ROM/` and build the pack with `createMSXpack.py`,
the same way as the BIOS pack.
