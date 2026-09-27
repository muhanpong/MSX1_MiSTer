# μ·PACK(Bit²/ASCII BM-117) 슬롯 B — 검토·FW 팩·실기 계획 (msx-machine-expert, 2026-09-27)

대상: `origin/mupack` 8443c50 (= nextz80 fb6995a + 4커밋). 빌드·보드 조작 없음.

## 1. 설계·구현 검토 — 실물/openMSX와 다른 점: 없음

| 항목 | 기준(openMSX) | 브랜치 | 판정 |
|---|---|---|---|
| 슬롯 구성 | `extensions/mu-PACK.xml`: 카트 자체 확장, 서브0 빔 / 서브1 256KB MemoryMapper(0000-FFFF) / 서브2 mu-pack.rom 16KB @4000 / 서브3 빔 | memory_upload.sv:814-815 서브1 `MAPPER_MUPACK`, 페이지마스크 AA(4페이지), 16블록 / 서브2 ROM_MUPACK, 마스크 08(페이지1만) | 일치 |
| ROM | sha1 e88ca790 ("Confirmed by Retrofan"), 16KB | 동일 파일, FW 팩 레코드 ID 9 | 일치 |
| MIDI | `<MSX-MIDI><external/>` — E2h 쓰기 전용, 리셋 시 비활성+제한(MSXMidi.cc:19-20, 75-77), b7=1 비활성, b0=1 → E0/E1(8251만), b0=0 → E8~EF | midi.sv:88-103, 245, 386: `ext_ctl` 리셋 81, `ext_on=~b7`, `ext_lim=b0`, 제한 시 port={00,a0}, E2는 sel 밖(항상 반응) | 일치 |
| 매퍼 폭 | MSXMemoryMapperBase: 세그먼트 & (n-1), 되읽기 `reg \| ~(bit_ceil(n)-1)` | msx2_ram_mapper.sv:22,24 동일식, count=16 → 세그먼트 16은 0 | 일치 |
| 매퍼 공존 | MSXMapperIO 기본 EXTERNAL 모드: 모든 매퍼 readIO를 **AND** | msx_slots.sv:234 AND 결합 | 일치 |
| ROM 없는 FW 팩 | MIDI 장치는 ROM과 독립 | DEV_MIDI_EXT를 서브1·서브2 두 줄에 → ROM 줄이 빠져도 MIDI 유지 | 일치 |

곁가지(μ·PACK과 무관, 기존 사항): openMSX는 FS-A1ST/GT에 `<MapperReadBackBits>5</MapperReadBackBits>` → 매퍼 되읽기 상위 3비트를 1로 강제. 코어는 전 비트 되읽기. 매퍼 ≤512KB면 상위 3비트가 원래 1이라 차이 없음, **1/2/4MB turbo R 변종 팩에서만** bit5-7이 달라질 수 있음. 우선순위 낮음.

설계 선택(수용된 것, 실물과 다르진 않음): GT에 5가 저장된 경우 내장 MIDI 우선·슬롯 B엔 ROM/매퍼 잔존 / sub-slots On이면 μ·PACK 무시.

## 2. FW 팩 재생성 — 로컬 생성·검증 완료, 보드엔 안 올림

- 방법: 브랜치의 `tools/CreateMSXpack/Extension/CART_FW_*.xml`(각각 `<fw name="MU_PACK">` 추가) + ROM 저장소(메인 체크아웃 `tools/CreateMSXpack/ROM/`, mu-pack.rom은 `extensions/`) → `createMSXpack.py`.
- 결과(`scratchpad/mupack/fw/`):

| 파일 | 크기 | md5 |
|---|---|---|
| CART_FW_JP.MSX | 10,535,008 | 4e3cd697a01f30732c118ab013aefa0c |
| CART_FW_JP_2slot.MSX | 10,535,008 | e201fdf4535b8db10692ac6e0e9b113e |
| CART_FW_EN.MSX | 10,535,008 | a3b8166ca1e2d517bc8eb5a3ae5eec81 |
| CART_FW_EN_2slot.MSX | 10,535,008 | 6bde3678888880a085ea6f32b11bb87c |

- 검증: 네 파일 모두 오프셋 0xA08060에 mu-pack.rom 16KB, 직전 헤더 `4D 53 58 00 09 00 01 …`(= "MSX\0", ID **09 = ROM_MUPACK**, 1블록). 기존 부분은 **바이트 단위 동일**(새 JP의 앞 10,518,608B == 기존 JP), 증가분 16,400B = ROM + 헤더 16B.
- 보드 현재 FW 팩 8개(`/media/fat/games/MSX1/` 4개 + `MSX/` 4개)는 모두 μ·PACK 없는 판(md5 04fda78c / 5d95539b / ff0ff1eb / 87798f1b)과 동일.
- 업로드 제안(사용자 결정): 기존 파일은 두고 **새 이름**(예: `CART_FW_JP_mupack.MSX`)으로 올려 OSD "Load FW PACK"(FC2)에서 골라 시험 → 통과 후 교체 여부 결정.

## 3. 실기 확인 계획 (합격 기준 선정)

전제: 사용자 "해" → `tools/buildgate/build.sh` → `deploy.sh`, RBF `MSX1_20260927c_…`. FW 팩은 위 새 이름으로 추가.

openMSX 기준값(ST_synthB = 보드 "FS-A1ST DOS2" 팩 등가, 격리 홈에서 측정):
- `CALL RAMDISK(4064,S):PRINT S` → 슬롯 B 없음 **96**, μ·PACK **352** (**+256KB**)
- BASIC 여유 바이트 25277 → **25269**(−8: μ·PACK ROM의 BASIC 확장이 작업영역을 잡음 = ROM이 올라간 증거)

| # | 구성 | 확인 | 합격 |
|---|---|---|---|
| 1 | ST DOS2 팩, 슬롯 B **Empty**, 새 FW 팩 | 기준선: 여유 바이트, RAMDISK 최대, OSD에 MIDI 행 보임 | 값 기록(대조군) |
| 2 | 같은 팩, 슬롯 B **MU-PACK** | OSD 메인에 "MIDI: MU-PACK (Slot B) active", MIDI 행 없음 | 보임/숨음 |
| 3 | 〃 | 여유 바이트 = #1 − 8 | −8 |
| 4 | 〃 | `CALL RAMDISK(4064,S):PRINT S` = #1 + 256 | +256 |
| 5 | 〃 + `I-City(k)(1-8)_muPack_fix.dsk` | FM/MIDI 선택 메뉴 → MIDI → "MIDI 초기화중" → 오프닝, MT32-pi/MIDILINK 소리 | 소리 남 |
| 6 | 〃 + `ARMI102_MIDI11.DSK` 또는 MIDRY `/I5` | 연주 | 소리 남 |
| 7 | #5를 슬롯 B **Empty**로 | 환영도시에 MIDI 메뉴 없음, OSD MIDI 행 보임 | 음성대조 |
| 8 | 슬롯 B MU-PACK + **옛 FW 팩**(μ·PACK 없음) | MIDRY `/I5` 연주됨, 여유 바이트는 #1과 같음(ROM 없음) | 8443c50 주장 확인 |
| 9 | GT 팩 | "MIDI: FS-A1GT built-in active", 슬롯 B 목록에 MU-PACK 없음, 환영도시 GT MIDI 기존대로 | 유지 |
| 10 | 회귀 | 슬롯 B 0~4 각각 동작, **SLOT A/B sub-slots 페이지 표시·숨김**(h7/h8 치환 부분), 비GT + OSD MIDI On(MIDI Interface 3) | 기존과 동일 |

CONF_STR 새 요소 3개(메인 메뉴 마스크 안내 줄 `-,text` 첫 사용 / h7·h8 치환 / 슬롯 B 두 줄 전환)는 시뮬로 못 봄 — #2·#9·#10이 그 확인임. 하나라도 안 보이면 나머지와 섞지 말고 그 항목만 따로 되돌려 볼 것(20260904 3건 동시 실패 전례).

## 모르는 것 / 가를 측정
- 옛 코어(RBF)에 새 FW 팩을 넣었을 때 추가 레코드(ID 9) 처리: 끝에 붙은 레코드라 무해할 것으로 보이나 미확인 → 새 이름으로 올리면 옛 코어는 옛 팩을 계속 쓰므로 위험 없음.
- 실기 turbo R + μ·PACK의 외부 슬롯 접근 대기(R800)는 openMSX·코어 모두 미모델링 — 이번 범위 밖.

## 사용자 결정 사항
1. 빌드("해") 여부와 시점
2. FW 팩 업로드 방식(새 이름으로 병행 → 검증 후 교체 권장)
3. 이 문서를 리포(mupack 브랜치 docs/)에 커밋할지
