# MFRSD와 SCC+ 사운드 카트리지 — SCMD가 검출되지 않는 이유

조사일: 2026-08-23 · 브랜치 `moonsound_ascii16x`

## 한 줄 결론

**우리 코어는 무죄다.** SCMD(`SCMD110A`)는 코나미 SCC+ *사운드 카트리지*의 64/128KB
쓰기가능 RAM을 요구하는데, MFRSD 서브슬롯 1에는 그런 RAM이 없다(플래시뿐).
**실기 MFRSD에서도 동일하게 실패한다.** 이는 오탐이 아니라 정탐이다.

우리 코어에서 SCMD를 돌리려면 **`SLOT A/B = SCC+`** 를 쓰면 된다 — 이미 구현되어 있고,
128KB 쓰기가능 RAM + SCC-I + **비확장 슬롯**으로 실기 코나미 카트와 동일하다.

---

## 1. 증상

MFRSD 카트 A로 부팅한 VHD의 `p6`에서 `SC.COM` 실행 → SCC+ 미검출.
같은 MFRSD에 구운 SCC 게임 롬은 SCC 사운드가 훌륭하게 발음됨.

화면 메시지(실제 문자열, `CORE2.SYS` 주소 `0x406B`):

```
SCC cartridge is not mounted.
```

그리고 **소프트 실패가 아니라 하드 abort**다:

```
4057  CD 6E C0   CALL 0xC06E      ; SCC+ 슬롯 스캔
405A  3A 62 2C   LD A,(0x2C62)    ; 발견 개수
405D  B7         OR A
405E  20 30      JR NZ,0x4090
4060  11 6B 40   LD DE,0x406B
4063  0E 09      LD C,9
4065  CD 73 29   CALL 0x2973      ; 출력
4068  C3 00 00   JP 0x0000        ; ← DOS로 중단
```

---

## 2. 로드 구조 (VERIFIED)

`SC.COM`(431B, `0x0100`)은 MSX 버전만 판별하고 실제 드라이버를 두 파일로 나눠 올린다.

```
SC.COM+0x00:  11 00 03  LD DE,0x0300 / 0E 1A LD C,0x1A / CD 05 00 CALL 5   ; SETDMA 0x0300
SC.COM+0xB2:  21 00 C0  LD HL,0xC000 / RDBLK          ; CORE2.SYS → 0x0300
              11 00 C0  LD DE,0xC000 / SETDMA         ; ← 두 번째 파일은 0xC000
              RDBLK → CORE2.SY2 → 0xC000
              JP 0x0300
```

| 파일 | 크기 | 로드 주소 |
|---|---|---|
| `CORE2.SYS` | 35262 B | `0x0300` |
| `CORE2.SY2` | 4138 B | `0xC000` |

**왜 둘로 나뉘었나:** 슬롯 선택 루틴 `0x0302`가 후보 슬롯을 **페이지 1과 2**
(`0x4000~0xBFFF`)에 꽂기 때문에, 그 동안 `CORE2.SYS` 자신이 `0x4000~0xBFFF`에서
사라진다. 그래서 프로브 코드는 페이지 3(`0xC000`)에 살아야 한다.

---

## 3. 슬롯 선택 루틴 `0x0302` (VERIFIED — 이 문서의 핵심)

```
0302  C5             PUSH BC
0303  3A 46 2C       LD A,(0x2C46)      ; 후보 primary
0306  0F 0F          RRCA RRCA          ; → 비트 7:6
0309  DB A8          IN A,(0xA8)
030B  E6 3F          AND 0x3F
030D  B1             OR C
030E  D3 A8          OUT (0xA8),A       ; 페이지 3만 후보 primary로 (0xFFFF 접근용)
0310  78 07 07 47    LD A,B / RLCA RLCA / LD B,A      ; 후보 subslot → 비트 3:2
0314  07 07 B0 47    RLCA RLCA / OR B / LD B,A        ;              → 비트 5:4 에도
0318  3A FF FF       LD A,(0xFFFF)
031B  2F             CPL
031C  E6 C3          AND 0xC3                          ; 페이지 0,3 유지
031E  B0             OR B
031F  32 FF FF       LD (0xFFFF),A                     ; 서브슬롯 레지스터: 페이지 1,2
0322  3A 46 2C       LD A,(0x2C46) / RLCA RLCA ...
032C  3A 72 2C       LD A,(0x2C72) / AND 0xC3 / OR B
0332  D3 A8          OUT (0xA8),A                      ; A8: 페이지 1,2 = 후보 primary
```

즉 **하나의 `(primary, subslot)` 쌍을 `0x4000~0xBFFF` 전체에 꽂는다.**
따라서 프로브가 만지는 모든 것이 **같은 서브슬롯 하나**에서 나와야 한다:

| 주소 | 대상 |
|---|---|
| `0xBFFE` | SCC+ 모드 레지스터 |
| `0x9000` / `0xB000` | 뱅크 레지스터 |
| `0xB800~0xB8FF` | SCC-I 레지스터 창 |
| **`0x8000~0x9FFF`** | **뱅크된 RAM** |

> **SCMD는 서브슬롯을 제대로 순회한다.** Pazos가 다른 소프트웨어를 두고 반복해서
> 지적한 "primary 슬롯만 훑는다"는 문제에 SCMD는 **해당하지 않는다.**

---

## 4. 검출 루틴 (VERIFIED, 전량 자체 역어셈블)

### 4-1. 쓰기가능 판정 `0xC134`

```
C134  3A 00 80    LD A,(0x8000)
C137  4F          LD C,A            ; C = 원본
C138  3C          INC A
C139  32 00 80    LD (0x8000),A     ; 원본+1 기록
C13C  3A 00 80    LD A,(0x8000)
C13F  B9          CP C              ; ★ 원본과 비교
C140  28 06       JR Z,0xC148       ; 안 바뀜 → 쓰기 불가
C142  79 32 00 80 LD A,C / LD (0x8000),A   ; 원본 복원 (비파괴)
C146  AF C9       XOR A / RET       ; A=0, Z  = 쓰기 가능
C148  3E 01 B7 C9 LD A,1 / OR A / RET      ; A=1, NZ = 쓰기 불가
```

**극성: Z = 쓰기 가능, NZ = 쓰기 불가.**

### 4-2. 모드 설정 `0xC14C`

```
C14C  AF 32 FE BF   XOR A / LD (0xBFFE),A    ; 모드 0
C150  79 32 00 90   LD A,C / LD (0x9000),A   ; 뱅크2 = C
C154  3E 3F 32 FE BF LD A,0x3F / LD (0xBFFE),A ; 모드 0x3F = SCC+ + 전 세그먼트 RAM
```

### 4-3. 진입점 `0xC15A` — **사전검사가 있다**

```
C15A  3A FE BF   LD A,(0xBFFE) / LD B,A / PUSH BC   ; 모드 저장 (판정과 무관, 복원용)
C15F  AF 32 FE BF XOR A / LD (0xBFFE),A             ; 모드 0
C163  CD 34 C1   CALL 0xC134
C166  C2 6F C1   JP NZ,0xC16F                       ; 쓰기 불가 → 계속
C169  C1 78 32 FE BF C9  POP BC / 복원 / RET        ; 쓰기 가능 → 즉시 탈락(Z)
C16F  0E 00      LD C,0 / CALL 0xC14C / CALL 0xC134
C177  20 05      JR NZ,+5
C179  3E 01 32 89 C1   LD A,1 / LD (0xC189),A       ; 비트0 = 뱅크0 쓰기가능
C17E  0E 08      LD C,8 / CALL 0xC14C / CALL 0xC134
C186  20 07      JR NZ,+7
C188  3E 00      LD A,0x00        ; ← 0xC189는 이 즉치 피연산자(자가수정)
C18A  F6 02 32 89 C1   OR 0x02 / LD (0xC189),A      ; 비트1 = 뱅크8 쓰기가능
C18F  C1 78 32 FE BF   POP BC / 모드 복원
C194  3A 89 C1 B7 C9   LD A,(0xC189) / OR A / RET   ; NZ = 발견
```

**사전검사의 의미:** 모드 0에서 `0x8000`이 **쓰기 불가**여야 한다. 평범한 RAM 슬롯
(MFRSD 자신의 서브슬롯 2 메모리매퍼 포함)을 걸러내기 위한 장치다.

**결과 바이트 `0xC189`:** 비트0 = 뱅크0, 비트1 = 뱅크8. → 64KB(Snatcher)는 1,
128KB(확장)는 3.

**자가수정 코드 주의:** `0xC189`, `0xC0C7`, `0xC0D2`, `0xC103`이 즉치 피연산자다.
본 프로젝트에는 "FPGA에서 self-modifying code 미반영"이라는 미해결 항목이 있으나
([[project_vgm_timbre_rootcause]]), **이 건의 원인은 아니다** — 레퍼런스 구현도 동일하게
실패하고, `0xC188` 자가수정이 실패해도 비트1은 일반 데이터 쓰기로 세팅된다.

### 4-4. 다른 검출 경로는 없다 (VERIFIED)

- `0x2C62`(발견 개수)를 쓰는 곳은 두 군데뿐: `0xC06F`에서 0으로 초기화, `0xC126`에서 증가.
  후자는 `0xC15A` 성공 시에만 호출되는 `0xC0D7` 안에 있다.
- `0xC000`의 슬롯 스캔은 `"APRLOPLL"` / `"PAC2OPLL"` 시그니처 전용(FM-PAC). SCC와 무관.
- `0xC1AB`의 `"SCC"`는 `"SCCPCMMUSIC"` 리터럴의 일부이며 `0x2C62`를 건드리지 않는다.

**RAM 쓰기가능 테스트가 유일하고 결정적인 판정이다.**

---

## 5. SCMD는 그 RAM을 **실제로 쓴다** (VERIFIED — 중요)

"매퍼를 쓰는 것도 아니고 SCC+ 음원만 쓰려는 것 아닌가?"라는 의문에 대한 답이다.
아니다. RAM은 탐지 지표가 아니라 **곡 데이터 저장소**다.

### 5-1. 카트리지 RAM에 8KB씩 적재 (`CORE2.SY2:0xC418`)

```
C418  3A DD C1   LD A,(0xC1DD)        ; 다음 뱅크 번호
C41B  32 00 90   LD (0x9000),A        ; 뱅크2 = 그 뱅크
C41E  3C 32 DD C1 INC A / LD (0xC1DD),A
C422  3E 3F      LD A,0x3F
C424  32 FE BF   LD (0xBFFE),A        ; ★ RAM 모드 ON (bit4)
C427  21 00 40   LD HL,0x4000         ; 소스 = 메인 RAM (디스크에서 읽은 곡)
C42A  11 00 80   LD DE,0x8000         ; 목적지 = 카트리지
C42D  01 00 20   LD BC,0x2000         ; 8 KB
C430  ED B0      LDIR                 ; ★ 카트리지로 복사 (HL→DE)
C432  AF 32 FE BF XOR A / LD (0xBFFE),A ; RAM 모드 OFF
                 ; 바로 아래 0x6000→0x8000 8KB 한 번 더, 뱅크 증가하며 반복
```

### 5-2. 리플레이어 채널 포인터 9개가 전부 `0x8000` (`CORE2.SYS:0x4976`)

```
4976  21 00 80   LD HL,0x8000
4979  22 15 33   LD (0x3315),HL     ┐
497C  22 74 33   LD (0x3374),HL     │  0x5F 간격 = 채널별 곡 포인터 9개
497F  22 D3 33   LD (0x33D3),HL     │
...                                 │
4991  22 0D 36   LD (0x360D),HL     ┘
```

### 5-3. 재생 시에는 RAM 모드를 끈다 (`CORE2.SYS:0x4A72`)

```
4A72  FE 02      CP 0x02
4A74  CA 90 4A   JP Z,0x4A90          ; A==2 → 뱅크8 변형(128KB)
4A77  3E 20      LD A,0x20
4A79  32 FE BF   LD (0xBFFE),A        ; ★ 모드 0x20 — bit4 클리어
4A7C  AF 32 00 90 XOR A / LD (0x9000),A ; 뱅크2 = 0 (또는 8)
4A88  3E 81      LD A,0x81
4A8A  32 00 B0   LD (0xB000),A        ; 뱅크3 = 0x81 (bit7 → SCC+ 창 활성)
4AA7  21 00 B8 / 11 01 B8 / 01 9F 00 / 36 00 / ED B0
                                      ; 0xB800~0xB89F (파형 5채널) 클리어
4AB4  ... 16바이트 → 0xB8A0 (주파수/볼륨 레지스터)
4AC3  32 C0 B8   LD (0xB8C0),A        ; 채널 인에이블 = 0
```

**핵심:** 실제 코나미 SCC+ 카트에서 모드 bit4는 **쓰기만** 제어하고
`0x8000~0x9FFF` **읽기는 항상 RAM**이다. 그래서 재생부는 bit4를 끈 채
(뱅크 레지스터를 계속 쓰기 위해) 그 창에서 곡을 **읽는다.**

→ MFRSD에서는 그 읽기가 **플래시 내용**을 돌려준다. **검출을 속여도 소용없다.**

---

## 6. MFRSD 쪽 (VERIFIED — openMSX + 우리 RTL 양쪽)

### 6-1. 서브슬롯 1에 RAM 없음

openMSX `MegaFlashRomSCCPlusSD::writeMemSubSlot1` (`:582`): `mapperReg` 8가지 모드를
전부 추적해도 전 경로가 `writeToFlash()`로 끝난다. **메모리 저장이 없다.**
`isRamSegment2/3`(`:627-629`)은 **SCC 창을 닫는 조건에만** 쓰인다.

우리 RTL도 동일:

| 파일:행 | 내용 |
|---|---|
| `mfrsd.sv:100-102` | `isRamSegment2/3` → `scc_req`에만 사용 |
| `mfrsd.sv:171-173` | 전 주소가 `flash_addr = 0x010000 + ...` → `mem_addr = mfrsd_base_ram + flash_addr` |
| `msx_slots.sv:192` | SDRAM 쓰기는 `cpu_wr & ~ram_ro` |
| `memory_upload.sv:423` | 기본 `ro <= 1'd1` (MFRSD 플래시 이미지는 ROM) |
| `flash.sv:131` | 언락 없는 단독 쓰기는 `bytePrgram` 조건 불충족 → 무시 |

`0xBFFE` 프로브 시퀀스에는 AMD 언락(`0xAA`→`0xXAAA`)이 없으므로 플래시는
read-array 상태를 유지하고 되읽기 값이 변하지 않는다.

### 6-2. MFRSD는 확장 슬롯이다

```
memory_upload.sv:663-666
  subslot 0 → Recovery       (DEV_FLASH)
  subslot 1 → MegaFlashROM   (DEV_SCC2 | DEV_FLASH)   ← SCC-I 여기
  subslot 2 → RAM 512KB      (ROM_RAM, DEV_MFRSD2|DEV_PSG) ← RAM 저기
  subslot 3 → MegaSD         (DEV_FLASH)
```

`memory_upload.sv:271`의 `if (subslot != 0) cart_slot_expander_en |= 1 << slot`이
걸리므로 **반드시 확장 슬롯**이 된다.

> **SCC-I는 서브슬롯 1, RAM은 서브슬롯 2.**
> §3에서 본 대로 코나미 사운드 카트리지 규약은 둘이 **같은 서브슬롯**일 것을 요구한다.
> **RAM 용량을 늘려도 소용없다 — 자리가 틀린 것이다.**

### 6-3. 벤더 자신의 소프트웨어가 반대 극성을 쓴다

`mfrsd.rom` 안의 `VGMPLAY.COM`(`0x7B062A`): `LD HL,0x8000 / CALL 0x5755 / RET Z`
= **"RAM이면 이 슬롯을 거부"**. bit4를 세우지 않는다.
즉 Pazos 쪽 소프트는 "MFRSD = RAM 없음"을 전제로 짜여 있다.

---

## 7. Pazos 본인의 답 (MRC "Big MegaFlashROM SCC+ SD topic", 108쪽 전량 조사)

핸들 `guillian` = Manuel Pazos. 스레드 1,069개 글 전수 검색.

**핵심 (p61, 2016-01-03):**
> "bear in mind that the MegaFlashROM SCC+ SD **implements only the SCC-I (sound chip)
> and not the 64K RAM included in the original sound cartridge**. So it can't be used
> with the original game."

**보강:**
- p73 (2016-08-12): "original Konami Game Collection search for (SD) Snatcher sound
  cartridges, **that have an SCC-I and 64K RAM**."
- p98 (2024-09-09): "Unpatched Snatcher or SD Snatcher games will search for a
  Snatcher/SD Snatcher Sound cartridge in any slots. In this case they will use the
  **sound cartridge, not the SCC/SCC+ in the MFR SD**."
- p54: "**flashROM memory can't be used as RAM.** It will not expand your computer memory."
- p44: "The 512K RAM in MegaFlashROM SCC+ SD is **just a normal RAM expansion**."
- p25: "It has real SRAM memory, but the mapper is implemented in the FPGA." (512K 얘기)

**왜 안 넣었나 — 근거 있는 것만:**
- p27 (2013-12-16): "the FPGA in the cartridge has **not enough capacity to implement
  anything more**. In order to implement MSX-MUSIC or whatever, a new cartridge must be
  done (new PCB, different FPGA, new VHDL code...)"
- p65 (2016): "There is no enough space in the FPGA for a SN76489"
- p10: "the new MFRSD **doesn't have the subslot simulation. Its subslots are used for
  the different parts of the cartridge** (SD reader, MegaFlashROM SCC+ and recovery)"
- p100 (2024): "if you flash a **ASCII8 ROM**, then the cartridge is configured as an
  ASCII 8, **so the SCC is not available** in that configuration."
  → ROM 매퍼 모드와 SCC가 같은 쓰기 디코더를 공유하는 상호배타 관계
- p25 (2013): 부팅 `S` 키가 생긴 이유 — "**due to some DSKs games writing to ROM and
  SCC mapper registers**"

**설계상 양자택일 (p26, 2013-12-15):**
> "When running a DSK, MSX is restarted to disable subslots... **That means that all
> devices in MegaFlashROM SCC+ SD will be disabled except the MegaFlashROM SCC+. So the
> RAM will not be available.**"
> (p53) "hold **R**/**F** to enable the RAM. Also, to enable the SCC in DSK mode you
> need to hold **S** key."

SCC를 primary 슬롯에서 보이게 하면 RAM이 죽고, RAM을 살리면 SCC가 서브슬롯으로 들어간다.
**둘 다는 불가능.**

**2013년에 이미 같은 증상 보고:**
- p12 roadfighter (2013-05-04): "Scc works with Konami games, **but not from dos with the
  SCC replayer van Tyfoon soft**"
- p12 (05-05): "**SCC musixx from tyfoon soft does not recognise the scc**"

Pazos의 일반론적 답변(p12/p16: "소프트웨어가 슬롯을 제대로 안 훑는다")은 Fony 데모 등에는
맞지만 **SCMD에는 맞지 않는다** — §3에서 확인했듯 SCMD는 서브슬롯까지 제대로 순회한다.
SCMD의 정확한 사유는 p61(64K RAM 부재)이다.

---

## 8. 우리 코어에 이미 있는 정답: `SLOT A/B = SCC+`

```
memory_upload.sv:661
  CART_TYP_SCC2 → {MAPPER_KONAMI_SCC, DEVICE_NONE, ROM_RAM, 8'hAA, 8'h00, 0, ram_size=8, DEV_SCC2}
```

- `ram_size` 단위는 16KB (`memory_upload.sv:261` `data_size <= {cart_ram_size,14'h0}`)
  → 8 × 16KB = **128KB** (코나미 "확장" 서브타입, 프로브 결과 flags=3)
- `ROM_RAM` → `ro <= 1'd0` (`:415`) = **쓰기 가능**
- `DEV_SCC2` → `sccDevice = 1` (`msx_slots.sv:463`) = SCC-I
- 서브슬롯 0 한 줄뿐 → `cart_slot_expander_en` 미설정 → **비확장 primary 슬롯**
- OSD 노출: `msx_config.sv:6` `"O[31:29],SLOT B,ROM,SCC,SCC+,FM-PAC,Empty;"` (인덱스 2)

### SCMD 시퀀스 대조

| SCMD 동작 | 우리 RTL |
|---|---|
| 모드 0에서 `0x8000` 쓰기 실패해야(사전검사) | `konami_scc.sv:74` `en_ram = sccMode[4] \| (sccMode[5]&sccMode[2])` = 0 → `:79` `mem_unmaped` → 차단 ✓ |
| 모드 `0x3F`에서 쓰기 성공해야(검출) | bit4=1 → `en_ram`=1 → 차단 해제 + `ro=0` → SDRAM 기록 ✓ |
| 뱅크 0 / 뱅크 8 | 128KB = 8KB×16뱅크 → 뱅크 8 존재 → flags=3 ✓ |
| `LDIR` 8KB × N | 동일 경로 ✓ |
| 재생: 모드 `0x20`, `0x8000` 읽기 | `konami_scc.sv:63-64` 주석대로 **읽기는 게이트 안 함** → RAM 내용 ✓ |
| 파형 → `0xB800`, 뱅크3 bit7 | `:65-68` `scc_req` → IKASCC ✓ |

### 실기 코나미 카트와의 대조

| | 확장 여부 | `0x8000` 뒷단 | 사운드 칩 |
|---|---|---|---|
| 실제 코나미 SCC+ 사운드 카트 | 비확장 | 64/128KB RAM | SCC-I |
| **우리 `SLOT A/B = SCC+`** | **비확장** | **128KB RAM (`ro=0`)** | SCC-I |
| MFRSD 서브슬롯 1 | 확장(0~3) | 플래시 | SCC-I |

**두 축 모두 실기와 일치한다.** (⚠ 실기 SCMD 검증은 아직 안 했다 — §11)

---

## 9. 3인 크리틱 합의

| 크리틱 | 판정 | 근거 |
|---|---|---|
| `scc-hw` | CLAIM HOLDS | Pazos 문서 + 사용자 매뉴얼("512K RAM은 옵션") + 펌웨어 → 서브슬롯 1은 NOR 플래시, SRAM 없음 |
| `scc-rtl` | DIVERGES (별건 6종) | D1~D6 발견. D1/D2를 유력 용의자로 지목했으나, `0xBFFE` 읽기가 판정과 무관함이 확인되어 D2는 원인 아님 |
| `scc-probe` | CLAIM HOLDS | **실제 `SCMD110A.DSK`를 openMSX에서 openMSX 자신의 MFRSD 모델에 물려 실행** |

`scc-probe`의 실측 (openMSX 21.0-245-g2712dbd1c, Philips NMS 8250):

```
MFRSD_BLANK                        → found=0 → "SCC cartridge is not mounted."  ← 사용자 증상 재현
Konami_Snatcher_Sound_Cartridge    → found=1, rec0=01 00 04 01 00, 드라이버 정상 설치
```

세 크리틱 모두 `cc5fa4d` 되돌림이 옳았다는 데 동의.

---

## 10. 철회 사항 (내가 만든 것 중 폐기)

### 10-1. `tools/scmd_mfrsd/CORE2P.SYS` — 두 겹으로 무효

1. **주소 오프셋 오류.** `CORE2.SYS`는 `0x0300`에 로드되므로 파일 오프셋 `0x7BA8`의
   스텁은 실행 주소 `0x7EA8`이다. 내가 심은 `CD A8 7B`(= `CALL 0x7BA8`)는 **0x300 어긋난다.**
2. **고쳐도 무의미.** 호출지점(주소 `0x4A77`/`0x4A90`)은 **플레이어 init**인데, 드라이버는
   그 전에 `0x4068: JP 0x0000`으로 이미 중단한다.

### 10-2. `tools/scmd_mfrsd/MFRSDSCC.BAS` — 무효

BASIC POKE로 `mapperReg=0`, `0xBFFE=0x20`을 세팅해도 **RAM이 생기지 않는다.**
사용자 실측("basic 해도 검출 안되네")과 일치.

`msx1-mister-e9` 세션에 `p6\scmd110m` 배치를 부탁해 둔 상태이나 **불필요한 파일**이다.

### 10-3. 그 밖에 폐기된 가설

| 가설 | 반증 |
|---|---|
| 슬롯 ID(`SL`) 오류 | `Sony_HB-F1XV_nologo.xml` — SLOT A = primary 1 (사용자 최초 추정 1-1이 옳았음) |
| `mapperReg[2]` 자기잠금 | `mfrsd.rom:0x7B52BF`의 `OPFXSD`가 `XOR A / LD (0x7FFF),A`를 자유롭게 수행 |
| SCC+ 창 폭(256B vs 2KB) | 프로브 경로와 무관 (단, D1로 별도 존치) |
| SCMD가 슬롯 스캔을 못 함 | §3 — 서브슬롯까지 제대로 순회함 |

---

## 11. "MFRSD SCC++"를 만들 수 있는가 — 검토 결과

**단일 저장소 모델**이라면 성립한다. RAM 모드가 별도 RAM을 만드는 게 아니라
**같은 SDRAM 플래시 이미지에 대한 CPU 쓰기를 열어주는 것**이면:

- 읽기는 원래부터 같은 이미지 → **읽기 경로 모호성이 발생하지 않는다**
- MFRSD 플래시 영역은 **영속되지 않는다** (`msx_slots.sv:579` `flash16x_active`는
  `MAPPER_ASCII16X | MAPPER_YAMANOOTO`에만 세워지고, `nvram_backup`은 `lookup_SRAM`과
  `flash16x_*`만 다룬다) → 낙서해도 리셋하면 `mfrsd.rom`에서 복구
- 구현 규모: `msx_slots.sv:192`의 `mapper_ascii16x_prog_we | mapper_yamanooto_prog_we`
  옆에 항 하나 추가 + `mfrsd.sv`의 `mem_unmaped`가 `en_ram` 쓰기를 죽이지 않게 — 사실상 2줄

**그럼에도 권고는 "옵트인일 때만":**

1. **MFRSD에 구운 Snatcher / SD Snatcher 자기파괴.** 그 게임들은 모든 슬롯에서 사운드
   카트리지를 찾는다(p98). 지금은 검출 실패라 안전한데, RAM을 열면 검출에 성공하고
   **자기 ROM이 있는 바로 그 뱅크**에 곡을 쓴다. 저장소가 하나이므로 실행 중 자기를 덮어쓴다.
2. **`sccMode` bit4 잔존 상태의 OPFXSD.** `sccMode`는 `mfrsd.sv:61` 리셋에서만
   클리어된다. bit4가 살아 있으면 프로그램 쓰기가 JEDEC FSM을 우회해 생 데이터로 들어가
   소거/상태폴링 의미론이 어긋난다 → **silent failure.**
   값싼 가드: `mapperReg`가 비-SCC 모드로 쓰이면 `sccMode` 클리어.
3. **실익이 작다.** MFRSD는 확장 슬롯이라 RAM을 넣어도 primary만 훑는 소프트는 여전히
   실패하고, 서브슬롯까지 훑는 소프트(SCMD)는 `SLOT A/B = SCC+`로 이미 된다.
   즉 새로 살릴 소프트웨어 집합이 **기존 옵션의 진부분집합**이다.
4. **골든 대조 기준선 상실.** 실기·openMSX 어디에도 없는 동작이 되어, D1~D6을 찾아낸
   방법론(openMSX 대조)을 그 경로에서 못 쓴다.

**결론: 기본 Off의 OSD 토글이 아니면 넣지 않는다.**

---

## 12. 남은 것

**D1~D6은 `docs/TODO_scc_divergences.md`로 분리했다** — 항목별 파일:행, openMSX 대응,
확인 상태(VERIFIED / 대조 미완), 작업 순서 원칙이 거기에 있다.

- [ ] **실기 검증**: `SLOT B = SCC+`로 SCMD 동작 확인 (배포된 RBF로 바로 가능, RTL 수정 불요)
- [ ] `msx1-mister-e9`에 `MFRSDSCC.BAS` 배치 취소 통지
- [x] `tools/scmd_mfrsd/` 산출물 처리 → **유지 + `README.md`로 사용 비권고 명시** (2026-08-23)

## 13. 조사 자료 위치

| 위치 | 내용 |
|---|---|
| `/tmp/mfrsd_thread/` | MRC 스레드 HTML 108쪽 + `posts.json`(1,069글) + `parse.py` + `find.py` |
| `/tmp/scmd/` | `SC.COM`, `CORE2.SYS`, `CORE2.SY2`, `CORER.SYS`, `CORET.SYS`, `SCMD110A.DSK` |
| `/tmp/scc-probe/z80dis.py` | 자체 작성 Z80 역어셈블러 (`<file> <base> <start_off> <end_off>`) |
| `tools/scmd_mfrsd/` | 폐기 예정 산출물 + `SCMD110A_original.DSK`, `SLOTSCAN.BAS` |

재현 예:
```bash
python3 /tmp/scc-probe/z80dis.py /tmp/scmd/CORE2.SY2 0xC000 0x134 0x19B   # 검출 루틴
python3 /tmp/scc-probe/z80dis.py /tmp/scmd/CORE2.SYS 0x300  0x02   0x50   # 슬롯 선택
python3 /tmp/scc-probe/z80dis.py /tmp/scmd/CORE2.SYS 0x300  0x4750 0x4830 # 플레이어 init
python3 /tmp/mfrsd_thread/find.py "64 ?K.{0,30}RAM" guillian 330          # 스레드 검색
```

⚠ `/tmp`는 휘발성이다. 장기 보존이 필요하면 별도 위치로 복사할 것.
