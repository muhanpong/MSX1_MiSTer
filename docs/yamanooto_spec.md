# Yamanooto (The SCC Alliance, 2023) — 스펙 감사 및 이식 설계

작성 2026-08-19. 1차 기준 = `Yamanooto Hardware Reference (public)` PDF(개정 15oct2024).
보조 = https://genami.shop/blogs/news/programming-the-yamanooto,
레퍼런스 구현 = openMSX `src/memory/Yamanooto.{cc,hh}` (체크아웃 `2712dbd1c`, `RELEASE_21_0-245`).

---
## 0. 요약

- Konami5(SCC)/Konami4 전환형 **8MB 플래시 카트** + SCC + PSG. 페이지1 상단(`0x7FFC-0x7FFF`)에
  설정 레지스터 4개.
- openMSX 구현은 **`yimmi8` 세대 펌웨어의 일관된 스냅샷**이다. 최신 `yimmi9rc2`와는
  **SCC+ RAM 모드 1건**에서만 어긋난다. 레퍼런스로 쓸 수 있으나 그 1건은 다르게 구현할 것.
- ★**openMSX 21.0 릴리스 바이너리를 레퍼런스로 삼지 말 것** — §5 참조.

---
## 1. 레지스터 맵 (PDF 원본 확정)

`0x4000-0x7FFF` 페이지1 최상단. **미러되지 않는다**(매퍼 영역은 미러됨 — 실기 검증,
openMSX commit `9a62047c7` "config regs are NOT mirrored").

| 주소 | 이름 | 리셋값 | 비고 |
|---|---|---|---|
| `0x7FFF` | ENAR | 00h | Features enable |
| `0x7FFE` | OFFR | 00h | Mapper offset |
| `0x7FFD` | CFGR | 00h | Configuration and Control |
| `0x7FFC` | – | `<undef>` | 스펙 미정의. openMSX는 FPGA 통신 채널로 구현(문서 밖) |

리셋/전원투입 후 **ENAR만 쓰기 가능하고 어떤 레지스터도 읽을 수 없다.** REGEN=1로 해제.

### ENAR (0x7FFF)
```
bit7 bit6 bit5 | bit4 | bit3 |  bit2:1  | bit0
 -    -    -   | WREN |  -   | RESERVED | REGEN
               |  RW  |      |          |  RW
```
- **WREN**: 플래시 쓰기 인에이블
- **REGEN**: 나머지 레지스터의 읽기·쓰기 전체를 개방

### OFFR (0x7FFE) — REGEN=1일 때만 R/W
8비트 오프셋. **매퍼 레지스터를 쓸 때만** 반영된다:
`내부 세그먼트 = (OFFR * 4) + 기록값`. 단위는 32KB(=4×8KB).

### CFGR (0x7FFD) — REGEN=1일 때만 R/W
```
bit7 bit6 |  bit5   bit4  | bit3 | bit2   | bit1 | bit0
 -    -   |    SUBOFF     |  K4  | ROMDIS | ECHO | MDIS
          |      RW       |  RW  |   RW   |  RC  |  RW
```
★**SUBOFF는 bit5:4 병합 셀(2비트)**. 평문으로 옮기면 정렬이 깨져 `SUBOFF=bit5, K4=bit4`로
오독하기 쉽다 — PDF 원본을 볼 것.

- **SUBOFF**: 오프셋에 하위 2비트를 추가해 **8KB granularity** 제공
- **K4**: Konami5(SCC) → Konami4 전환 (비SCC 게임 포함 컴필레이션 대응)
- **ROMDIS**: 플래시 접근 차단. DEL 키 부팅 시 자동 세트, 소프트웨어로 클리어해야 읽기/쓰기 가능
- **ECHO**: 내장 PSG가 MSX 내부 PSG 포트에도 반응(스테레오 출력). HOME 키 부팅 시에만 세트
- **MDIS**: 매핑 비활성 — 32KB 이하 롬이 스위칭 영역을 건드릴 때 뱅크 변경 방지. 주로 K4에서 문제
- MDIS 각주: *"This bit was (psg) LOW, which caused the built-in psg to sound with lower volume.
  It had no use so we re-purposed this bit."*

★**"CFGR은 CPU 리셋에서 보존된다"는 문장은 PDF에서 취소선으로 철회되었다**
(HISTORY `15oct2024: Changed CFGR/OFFR reset behavior (yimmi8beta3)`).
§1의 *"After **reset or power-up**, only ENAR is writable"*도 리셋과 전원투입을 동일 취급한다.
→ 리셋 시 ENAR/OFFR/CFGR **전부 0**이 현행 스펙이다.

---
## 2. openMSX 감사 결과

### 2.1 그대로 이식 가능 (일치 확인)
| 항목 | 내용 | 인용 |
|---|---|---|
| 레지스터 주소 | `ENAR=0x7FFF, OFFR=0x7FFE, CFGR=0x7FFD, FPGA=0x7FFC` | `Yamanooto.cc:20,23,24,33` |
| 비트 배치 | `WREN=0x10 REGEN=0x01 / SUBOFF=0x30 K4=0x08 ROMDIS=0x04 ECHO=0x02 MDIS=0x01` — PDF와 완전 일치 | `cc:21-29` |
| REGEN 게이팅 | 쓰기: ENAR만 무조건, 나머지는 `else if (enableReg & REGEN)`. 읽기: 불충족 시 **플래시 내용** 반환 | `cc:146,170,185,197-201` |
| 리셋 | ENAR/OFFR/CFGR 전부 0, `powerUp()`은 `reset()` 그대로 호출 | `cc:64-76` |
| **오프셋 산술** | `offset = (offsetReg<<2) \| ((configReg&SUBOFF)>>4)` = **OFFR*4 + SUBOFF**, 범위 0..1023 | `cc:246` |
| **지연 래치** | OFFR 쓰기는 뱅크를 즉시 바꾸지 않음(`// does NOT immediately switch bankRegs`). 뱅크 쓰기 시점에만 합산 | `cc:224,252,266` |
| 10비트 뱅크 | `(value+offset) & 0x3FF` = 1024세그먼트 × 8KB = 8MB | `hh:50, cc:123,252,266` |
| K5/K4 디코드 | K5 `(address&0x1800)==0x1000` (5000/7000/9000/B000대) / K4 `0x6000 <= address` (4000-5FFF 고정) | `cc:249,263` |
| MDIS | K4·K5 양쪽 뱅크 쓰기에 `(configReg & MDIS) == 0` | `cc:249,263` |
| ROMDIS | 읽기 3곳 + 쓰기 1곳 전부 게이트 | `cc:163,179,190,237` |
| 레지스터 미러 없음 | 매퍼는 미러, 레지스터는 미러 안 됨 | commit `9a62047c7` |

### 2.2 ★raw / adjusted 분리 — 전 사용처 일관 (핵심 설계)
| 배열 | 용도 | 사용처 |
|---|---|---|
| `bankRegs` (오프셋 **적용**값, 10비트) | **플래시 주소 생성**, 디버거 세그먼트 표시 | `cc:123,252,266,344` |
| `rawBanks` (기록 **원본**값, 8비트) | **SCC 가시성 판정** | `cc:112,115,253,267` |

K4 경로(`cc:250-254`)와 K5 경로(`cc:263-268`) 모두 두 배열을 쌍으로 갱신한다. 섞인 곳 없음.

**왜 중요한가** — 아래 §5의 512KB 버그가 정확히 이 분리를 안 했을 때 생긴다.

### 2.3 openMSX와 **다르게** 구현할 것 — 1건
**`sccMode & 0x10`(RAM 모드)이면 SCC+ 창(`0xB800-0xBFFD`)을 닫을 것 — 읽기·쓰기 양쪽.**

openMSX `isSCCAccess()`에는 RAM 모드 조건이 **한 줄도 없다**(`cc:104-117`).
`sccMode`에서 실제로 쓰이는 비트는 `0x20`(Plus/Compatible) 하나뿐이고, bit4와 bit2:0은
저장만 되고 아무 효과가 없다.

근거: openMSX 이슈 **#1964**(open) — artrag 보고, bifi 문서
(http://bifi.msxnet.org/msxnet/tech/soundcartridge#programming) 기준으로
`0xB800`의 SCC+ 레지스터가 보이려면 모드 비트 + **bank4가 RAM 모드가 아닐 것** + bank4 세그먼트 bit7.
artrag 증언: *"현재 `yimmi8.bin`은 bank4의 RAM 모드를 검사하지 않아 실제 SCC+와 다르다.
다만 **`yimmi9rc2.bin`에서 검사를 추가해 수정**되었다."*
→ 최신 펌웨어와 bifi 스펙 양쪽에 맞추려면 닫는 것이 맞다.

★단 **#1964는 단순 버그가 아니라 문서 충돌**이다. `MSXSCCPlusCart.cc:172-177`:
> *"**According to Sean Young**: when the regions are in RAM mode you can **read from** the SCC(+)
> but not write to them ... TODO check this out => ask Sean..."*

즉 openMSX의 읽기 경로 거동은 Sean Young 서술을 따른 **의도적 구현**이며, 이것이 bifi 문서 및
artrag의 실기 관찰과 정면 충돌한다. **Yamanooto에 한해서는** artrag의 실기 증언이 1차 근거이므로
읽기·쓰기 모두 닫는다. (원조 Konami Sound Cartridge는 별개 판단 — `sccplus_spec.md` S8 참조.)

### 2.4 미구현 / 주의 (openMSX 측)
| 심각도 | 항목 | 내용 |
|---|---|---|
| 1 | SCC+ RAM 모드 미검사 | §2.3. **#1964 open** |
| 2 | DEL/HOME 부팅 키 | `cc:14-15` TODO. ROMDIS/ECHO의 유일한 HW 세트 경로 부재 → 플래시 복구 시나리오 재현 불가 |
| 3 | ECHO `RC` 시맨틱 | 순수 RW로 취급. `RC` 표기 정의가 스펙에 없어 **판정불가** |
| 4 | WREN=1 부작용 | `WREN=1`이면 뱅킹·SCC·모드 레지스터가 **전부 무시**(`cc:236` if/else). 또 레지스터 쓰기 후 `return`이 없어 `ENAR ← 0x11` 같은 쓰기가 **자기 자신을 플래시 명령 스트림에 주입** |
| 5 | K4에서 SCC 완전 차단 | `if (configReg & K4) return false;` (`cc:106`). 형제 구현 KUC는 정반대로 문서화 |
| 6 | FPGA 채널 스텁 | `0x9F`(SPI JEDEC ID) 쓰고 4회 읽으면 `1F 23 00 00`. 그 외 명령 전부 무시. READY 항상 1 |
| 7 | `0xBFFE-0xBFFF` 읽기 창 | Yamanooto/KUC는 창에서 **제외**, MSXSCCPlusCart/MFRSCC+SD는 **포함**. openMSX 내부 불일치, 실기 미확인 |
| 8 | `peekMem`/`readMem` 미러 불일치 | `peekMem`은 미러 후 레지스터 검사, `readMem`은 검사 후 미러 → `0xFFFF`에서 디버거와 CPU 읽기 값이 다름. **openMSX 버그** |
| 9 | CFGR readback bit7 강제 OR | `return configReg \| FPGA_WAIT` (`cc:152`). read-modify-write 시 bit7이 눌러 담김 |

---
## 3. SCC / PSG / 플래시

- **SCC 창**: Compatible `rawBanks[2]&0x3F==0x3F` && `0x9800-0x9FFF` /
  Plus(`sccMode&0x20`) `rawBanks[3]&0x80` && `0xB800-0xBFFD`
- **SCC 모드 레지스터**: `0xBFFE/0xBFFF`. 원조 Konami Sound Cartridge와 동일 주소이며
  설정 레지스터(`0x7FFC-0x7FFF`)와 무관. **K5 분기 내부 + WREN=0**일 때만 기록됨(`cc:271-278`)
- **PSG**: 포트 `0x10`(주소 래치) / `0x11`(데이터). 읽기 미등록. ECHO=1이면 `0xA0/0xA1` 추가 등록.
  볼륨은 SCC 대비 3.0배(실기 녹음 비교 근거 URL이 소스에 있음)
- **플래시**: openMSX는 `S29GL064N90TFI04` 8MB(8KB×8 + 64KB×127), 전 섹터 쓰기 가능.
  스펙에 칩명은 없음

---
## 4. 실기 확인이 필요한 항목 (스펙 미규정)
1. `RC` 표기 정의 — ECHO를 소프트웨어로 세트할 수 있는가
2. CPU 리셋 시 **뱅크 레지스터**가 0,1,2,3으로 복귀하는가
3. K4 모드에서 SCC 생사
4. WREN=1일 때 매퍼·SCC 쓰기 및 레지스터 영역 쓰기의 플래시 전달 여부
5. 플래시 칩 ID / CFI / 섹터 배치
6. PSG `0x12` 읽기 가능 여부, `0x10`/`0xA0` 래치 공유 여부
7. `0xBFFE/0xBFFF` **읽기** 시 SCC인가 플래시인가
8. `0x9800`(Compatible) 창에도 RAM 모드 조건이 걸리는가 — yimmi9rc2 변경 범위 불명
9. ENAR/CFGR 무정의 비트의 readback 마스킹 여부
10. 뱅크 합산 랩 폭(openMSX는 10비트)
11. SCC 스테레오 제어 경로 (openMSX는 고정 밸런스 근사)

---
## 5. ★openMSX 버전 함정 — 512KB 경계 신화

커뮤니티 보고: *"YAMANOOTO에 SCC 롬을 넣을 때는 512KB 경계에 파일을 고정해야 SCC 소리가
정상으로 나온다. 따라서 넣을 수 있는 SCC 롬 수는 13~14개로 제한된다."*
→ **실기 현상이 아니라 openMSX 버그**다. 실기는 수십 개가 정상 동작한다.

원인: 수정 전 `isSCCAccess()`가 **오프셋이 적용된** `bankRegs`로 판정했다.
```cpp
return ((bankRegs[2] & 0x3F) == 0x3F) && ...      // bankRegs = (기록값 + offset) & 0x3FF
```
게임은 SCC를 켜려고 `0x3F`를 쓴다 → `(0x3F + offset) & 0x3F == 0x3F` 요구
→ `offset ≡ 0 (mod 64)` → 오프셋 단위가 8KB이므로 **64 × 8KB = 512KB 경계**.
8MB ÷ 512KB = 16칸, 펌웨어/메뉴 몫 제외 = **13~14개** — 보고된 숫자와 정확히 일치.

수정: 커밋 `b3ad12816` (2025-10-11), 이슈 **#1992**(closed, artrag 보고/조사/테스트).
`rawBanks`를 도입해 **기록 원본값**으로 판정하도록 변경.

★**이 수정은 아직 릴리스에 없다.**
```
최신 태그 : RELEASE_21_0 (2025-09-26)
수정 커밋 : b3ad12816    (2025-10-11)   ← 릴리스 이후
git tag --contains b3ad12816 → (빈 출력)
```
→ 배포판 openMSX 21.0으로 대조하면 존재하지 않는 제약을 하드웨어에 새기게 된다.
**master 빌드 필수.** 이 PC 기준:
`/home/muhanpong/Documents/github/openMSX/derived/x86_64-linux-opt/bin/openmsx`
(버전 문자열 `21.0-245-g2712dbd1c`. `/usr/bin/openmsx`는 pacman 21.0 = 버그 있음)

참고: SCC/SCC+ 자체(`SCC.cc`, `MSXSCCPlusCart.cc`)는 RELEASE_21_0 이후 변경이
include 순서와 enum 테이블 자료형뿐이라 **의미 변경이 없다**. 버전 함정은 Yamanooto 한정.

---
## 6. 우리 코어 이식 설계

### 6.1 OSD 진입 경로 — **Mapper 드롭다운**으로 추가
`cart_typ_t`(3비트)와 SLOT 드롭다운 `O[19:17]`은 **이미 8개로 포화**라 여기 추가하면
HPS status 비트 재배치가 필요하다(회귀 위험).
반면 Mapper 드롭다운은 `O[23:20]` **4비트에 10개만 사용 — 6칸 여유**.
Yamanooto는 본질적으로 "롬을 얹는 플래시 카트"로 ASCII16X와 성격이 같으므로 Mapper 항목으로 넣는다.

주의: `msx_config.sv:57`의 `mapper_A_select + 4'd2` 규칙상 인덱스 10은
`MAPPER_FMPAC`(내부 매퍼)와 충돌한다. 또 `memory_upload.sv:303`이
`mapper <= mapper_typ_t'(conf[8])`로 **외부 설정 파일에서 enum 값을 읽으므로**
기존 enum 값을 밀면 기존 ROM PACK이 깨진다.
→ `MAPPER_YAMANOOTO`를 enum **맨 끝에 추가**하고, 인덱스→enum 변환을 ASCII16X처럼 특수 처리한다.

### 6.2 재사용 자산
| 필요 | 기존 자산 |
|---|---|
| SCC 음원 | `scc_sound.sv` + IKASCC (Real/Compat/Plus 완비) — `scc_req`/`scc_mode` 소스만 추가 |
| PSG | `msx_slots.sv:480` `psg psg`, `DEV_PSG`로 카트별 게이트 |
| 플래시 | `flash.sv` (MFRSD/ASCII16X에서 사용 중) |
| 뱅킹 골격 | `konami_scc.sv` 구조 참고 (단 오프셋·10비트 뱅크는 신규) |

### 6.3 1차 구현 범위 / 유보
**구현**: 레지스터 4개(FPGA 제외), REGEN/WREN 게이팅, OFFR+SUBOFF 오프셋 산술과 지연 래치,
10비트 뱅크, K4/K5 전환, MDIS, ROMDIS, SCC 가시성(**raw 뱅크 기준 + RAM 모드 차단**), PSG, 플래시 읽기.

**유보**: FPGA 통신 채널(`0x7FFC`) — 스펙 밖 + openMSX도 스텁, SD 슬롯,
DEL/HOME 부팅 키(호스트 키 연동 필요), SCC 스테레오, ECHO `RC` 시맨틱(정의 불명).
