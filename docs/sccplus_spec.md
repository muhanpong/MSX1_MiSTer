# SCC+ (SCC-I) 지원 — 스펙 계약 (2026-08-17 동결)

## 현황(조사 확정)
- 음원 = IKASCC_player_s (rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v), 실칩 SCC 재현:
  ch1-3 독립 RAM(u_mem_ch1..3), **ch4/ch5는 RAM 1개(u_mem_ch45) 공유** — 시분할 먹스(ch45_sr).
  u_ctrl_ch5의 o_RAM_WRRQ/o_RAM_ADDR_CPU/o_RAM_D **미연결**(ch5는 ch4 파형 읽기 전용).
- 레지스터 맵 = SCC 고정 (RAM 0x00-0x7F, FREQ 0x80-, VOL 0x8A-, MUTE 0x8F).
- 래퍼 scc_sound.sv는 sccPlusChip/sccPlusMode 포트를 **선언만 하고 미사용**. IKASCC로 전달 안 됨.
- 매퍼 konami_scc.sv는 SCC+ 접근(0xB800, sccMode[5]&bank[3][7])을 정확히 판정해 scc_req/scc_mode 출력.
- legacy rtl/sound/scc_wave.sv는 SCC+ 완전 구현(빌드 미포함) — 참고 자료로만 사용, 복귀하지 않음.

## 목표
IKASCC 기반을 유지한 채 SCC+ 3모드를 실칩/openMSX 시맨틱으로 구현. 기존 SCC 동작 bit-동일 유지.

## 모드 정의 (openMSX SCC.cc 준거)
| 모드 | 파형 RAM | FREQ/VOL/EN | 변형(deform) | 읽기 |
|---|---|---|---|---|
| Real (SCC) | ch1-4 0x00-0x7F, ch5=ch4 미러 | 0x80-0x9F | 0xE0-0xFF | 0x80-0xDF → 0xFF |
| Compatible (SCC+칩, SCC모드) | ch1-4 0x00-0x7F, **ch5=ch4 미러**(0xA0-0xBF 쓰기 무시) | 0x80-0x9F | 0xC0-0xDF | 0xA0-0xBF 읽기 가능(=ch4 파형) |
| Plus (SCC+모드) | ch1-5 0x00-0x9F 각 독립 | 0xA0-0xBF | 0xC0-0xDF | 0xA0-0xFF → 0xFF |
모드 소스: sccPlusChip(=DEV_SCC2, 카트 타입) / sccPlusMode(=konami_scc scc_mode bit, sccMode[5]&bank[3][7]).
  Real = ~sccPlusChip. Compatible = sccPlusChip & ~sccPlusMode. Plus = sccPlusChip & sccPlusMode.

## 구현 스펙 (모듈별 소유권 = 에이전트별)
### S1. IKASCC ch5 독립 RAM (rtl/IKASCC/src/IKASCC_modules/IKASCC_player_s.v) — 에이전트 A
- u_mem_ch5 신규(IKASCC_player_memory_s), u_ctrl_ch5의 o_RAM_WRRQ/o_RAM_ADDR_CPU/o_RAM_D/o_RAM_RDRQ 연결.
- ch5 RAM 주소 먹스: ch1 패턴(`rdrq ? addr_cpu : addr_cntr`) 그대로.
- **모드 입력 포트 i_SCCP_MODE[1:0]** 추가(0=Real,1=Compat,2=Plus). **Real·Compat 모드**에서는 ch5_wavelatch를 **기존처럼 ch45_ram_q**(ch4 미러)에서, **Plus에서만** ch5 전용 RAM에서 래치. ★근거: openMSX `SCC::writeWave`가 `mode != Plus`이면 wave4를 wave5로 복사 — 즉 Compat도 ch5=ch4. ch4/ch5 시분할 로직·ch4 경로는 **불변**.
- **IKASCC 내부 좌표 확정: ch5 RAM 창 = 0xA0-0xBF** (u_ctrl_ch5 ADDR_RAM_BASE=8'hA0, FREQ/VOL/MUTE는 기존 0x80/0x8E/0x8F 유지, ch4는 0x60 유지). Real·Compat에서는 0xA0-0xBF가 전용 ch5 RAM이 아니어야 하므로 **i_SCCP_MODE==2(Plus)일 때만 ch5 RAM 쓰기/읽기 요청을 허용**(그 외에는 ch5=ch4 미러).
- o_DB 먹스에 ch5_ram_rdrq 분기 추가.
- 기존 SCC(Real) 동작 bit-동일 보장이 최우선.

### S2. 래퍼 주소 리맵 + 읽기 마스킹 (rtl/peripheral/slots/scc_sound.sv) — 에이전트 B
- sccPlusChip/sccPlusMode → 카트별 mode[1:0] 산출, IKASCC i_SCCP_MODE로 전달.
- **ABLO 리맵**(IKASCC 좌표: 파형 ch1-4 0x00-0x7F, FREQ/VOL 0x80-0x9F, ch5 RAM 0xA0-0xBF, deform 0xE0-0xFF):
  - Real: 통과.
  - Compat: **0xA0-0xBF 읽기 → 0x60-0x7F**(공유 ch4/ch5 RAM = openMSX `readWave(4,..)`), **0xA0-0xBF 쓰기 → 0xC0-0xDF**(IKASCC 미디코드 = 싱크, openMSX writeMem은 무시), 0xC0-0xDF(deform) → 0xE0-0xFF, 나머지 통과.
    → 리맵 함수는 읽기/쓰기 비대칭이므로 `cpu_rd`를 인자로 받음.
  - Plus: 0x00-0x7F 통과, **0x80-0x9F(ch5 RAM) → 0xA0-0xBF**, **0xA0-0xBF(FREQ/VOL) → 0x80-0x9F**, 0xC0-0xDF → 0xE0-0xFF.
- 읽기 마스킹(scc_dout): 모드별 openMSX 표대로 0xFF 강제 영역 적용. Compat의 0xA0-0xBF 읽기는 ch4 파형(=ch5) 반환.
- oe/scc_dout 게이팅·wave 합산·A/B 분배 등 기존 로직 불변.

### S3. 검증 TB (sim/tb_sccplus.sv, iverilog) — 에이전트 C
- IKASCC_player_s + scc_sound 통합 TB. 시나리오:
  T1 Real: 기존 SCC 시퀀스(ch1-4 파형 기록/재생, ch5=ch4 미러) — 수정 전 RTL과 파형 출력 bit-동일 (골든=수정 전 커밋 체크아웃 시뮬).
  T2 Compat: **ch5 출력이 ch4 미러**임을 확인(ch4 = -128 → ch5 solo도 음수), 0xA0-0xBF 읽기가 ch4 파형 반환, **0xA0-0xBF 쓰기가 완전히 무시**됨(ch4·읽기값 불변), 0xC0 deform 동작.
  T3 Plus: 0x00-0x9F 5채널 독립, 0xA0-0xBF FREQ/VOL 적용, 0xA0-0xFF 읽기 0xFF.
  T4 모드 전환: Plus↔Compat 전환 시 전용 ch5 RAM 내용 보존(Plus 복귀 시 확인), Compat 구간에서는 0xA0-0xBF가 ch4 미러로 보일 것.
  T5 A/B 카트 독립성.
- 전 시나리오 PASS 로그.

## 제약
C1. IKASCC 개조는 S1 범위 최소. 파일 상단에 개조 사유 주석.
C2. Real 모드 bit-동일 = 회귀 게이트(골든 비교 필수).
C3. ALM 예산 ≤300 (RAM 32B×2카트 M10K 0.5개 수준).
C4. konami_scc.sv/msx_slots.sv 불변.

## 실기 체크리스트 (배포 후)
①SCC 게임(Gradius2/Salamander) 음 정상 ②SCC+ 게임(Snatcher/SD-Snatcher, SCC+ 카트 설정) ch5 음색 openMSX 대조 ③MFRSD(SCC+ 내장) 음 정상 ④GoFigure/Zanac 회귀 없음.

## 에이전트 편성 (3, 각자 소유 파일만 수정)
A: S1 (IKASCC_player_s.v)   B: S2 (scc_sound.sv)   C: S3 (sim/tb_sccplus.sv 신규)
채택·병합·골든 비교·빌드·배포 = 메인. A/B는 포트명 i_SCCP_MODE[1:0]으로 계약.


## S5. 정정 이력 (2026-08-18, 실기 검증 전)
초판 설계는 Compatible 모드에서도 ch5를 독립 RAM으로 두었으나, openMSX `src/sound/SCC.cc`
원본 대조 결과 **오설계**로 확인되어 수정함.

```cpp
// SCC::writeWave
if ((currentMode != Mode::Plus) && (channel == 3)) {
        wave[4][p] = wave[3][p];        // ch4 -> ch5 복사: Real 뿐 아니라 Compatible 에서도
}
// SCC::writeMem, Mode::Compatible
} else if (address < 0xC0) {
        // 0xA0..0xBF : ignore write wave form 5
}
```
증상(수정 전): SCC2 카트가 SCC+ 모드를 켜지 않은 채(=Compat) 구동되는 모든 일반 SCC 게임에서
ch5가 ch4 파형 대신 초기화되지 않은 전용 RAM을 재생 → 5번 채널 음색 오류.
`scc_mode = sccDevice & sccMode[5] & bank3[7]` 이므로 MFRSD·SCC2 지정 카트의 평소 상태가 Compat라
영향 범위가 넓었음. TB(T2)도 잘못된 기대값("ch5 independent")을 단언하고 있어 44/44 통과가
검출력을 갖지 못했음 — 사양 오류는 TB로 잡히지 않는다는 사례.

(참고) deform 레지스터 0xE0-0xFF는 이 리포에서 `test <= 8'h00` 로 영구 비활성(IKASCC_player_s.v)
이므로 Compat/Plus에서 0xE0-0xFF가 deform 창으로 새어 들어가도 실제 부작용은 없음 — 기존 제약이라
이번 변경 범위에서 제외.


## S3b. 검출 TB (sim/tb_sccdetect.sv, sim/run_sccdetect.sh) — 2026-08-18 추가

`tb_sccplus.sv`는 `sccPlusChip`/`sccPlusMode`를 테스트벤치 레지스터로 직접 구동하므로
**검출 경로를 전혀 타지 않는다.** 그래서 `cart_konami_scc`를 루프에 넣은 별도 TB를 추가:

```
CPU 쓰기 → cart_konami_scc → scc_req / scc_mode → scc_sound → IKASCC
```
모든 자극은 실제 16비트 주소의 Z80 메모리 쓰기(0x9000 / 0xB000 / 0xBFFE)다.

레퍼런스: openMSX `src/sound/MSXSCCPlusCart.cc` (`<SCCplus>` 디바이스, extensions의
`scc+.xml` / `Konami_SD-Snatcher_Sound_Cartridge.xml`이 쓰는 그 클래스).

| 항목 | 우리 RTL | openMSX `MSXSCCPlusCart` | |
|---|---|---|---|
| SCC+ 활성 | `sccMode[5] & bank[3][7]` | `(modeRegister&0x20) && (mapper[3]&0x80)` | ✓ |
| SCC 활성 | `~sccMode[5] & bank[2][5:0]==0x3F` | `!(mode&0x20) && ((mapper[2]&0x3F)==0x3F)` | ✓ |
| 모드 레지스터 | `{addr[15:1],0}==0xBFFE` | `(address\|1)==0xBFFF` | ✓ |
| SCC 창 | `addr[15:11]==5'b10011` (0x9800-0x9FFF) | 0x9800-0x9FFF | ✓ |
| SCC+ 창 | `addr[15:8]==8'hB8` (0x9800**만 256B**) | 0xB800-0xBFFF (2KB) | **△** |
| RAM 세그먼트 | `[0]=m4\|m0, [1]=m4\|m1, [2]=m4\|(m5&m2), [3]=m4` | `setModeRegister` 4항목 | ✓ |

### 시나리오 (40 checks)
- **D0** 일반 SCC 카트(sccDevice=0): 창 게이팅, 2KB 미러(0x9900), **0xBFFE 무반응**(SCC 칩엔 SCC+ 없음)
- **D1** SCC+ 카트 리셋 상태 = **Compatible**: ch5가 ch4 미러(읽기+실제 재생 레벨 일치), 0xA0-0xBF 쓰기 무시
- **D2** → Plus: 모드 bit5만으론 부족(EN_NONE), bank3 bit7 필요 / 창이 0x9800→0xB800 이동 / ch5 독립화
- **D3** 0xBFFF 별칭 동작, 0xBFFD는 모드 레지스터 아님, bank3 bit7 해제 시 EN_NONE
- **D4** Plus→Compat→Plus 왕복: Compat에선 미러 복귀, 전용 ch5 RAM은 보존

### ★음성 대조(negative control)
`NEGCTL=1 sim/run_sccdetect.sh` 는 2026-08-18에 고친 결함(Compat에서 ch5 전용 RAM 활성)을
스크래치 사본에 **다시 주입**하고 TB가 그것을 잡는지 확인한다. 결과: **34 passed / 6 failed**
(D1.4, D1.5b, D1.6b, D1.6c, D4.1, D4.1b — 읽기 3건 + 실제 재생 3건). 통과만 하는 TB는 증거가
아니라는 것이 이번 사건의 교훈이므로, 이 대조를 러너에 상시 포함한다.

### 시뮬레이터
Verilator 5.050 (`--binary --timing`). iverilog 13은 `konami_scc.sv:25`의
`bank <= '{'{...},'{...}}` 2차원 unpacked 배열 대입 패턴에서
"cannot evaluate VEC4 expression"으로 죽는다. **시뮬레이터를 맞추자고 RTL을 고치지 않는다.**
(`tb_sccplus.sv`는 골든 비교 흐름이 iverilog에 묶여 있으므로 그대로 둔다.)

### 남은 미검증 (실기 필요)
- OSD `SLOT A/B → SCC+` 선택이 `cart_conf.typ = CART_TYP_SCC2`로 전달되는지(HPS status 비트 배선)
- 실제 게임/리플레이어의 검출 루틴 통과 여부
- SCC+ 창 미러(0xB900-0xBFFD)를 쓰는 소프트가 있는지 — 있으면 위 표의 △가 실결함이 됨


## S6. 실제 게임 검출 루틴 대조 (2026-08-18)

시뮬레이터가 아니라 **실제 상용 게임의 코드**로 검출 경로를 검증한 기록.
디스크 이미지 원시 역어셈블. 두 게임이 **서로 다른 방식**으로 카트를 검출한다.

### (1) SD Snatcher (Konami 1990) — SCC 창 2단 시험
원본판 파일 오프셋 `0xB3489` (Z80 `0xC289`, 파일↔Z80 베이스 `0xA7200`):
```
C289: 26 80 / CD 24 00     LD H,80h / CALL ENASLT   ; 슬롯을 페이지2에 매핑
C28E: AF / 32 FE BF        LD (0BFFEh),A  A=0       ; 모드 <- 0 (Compatible 강제)
C292: 3E 02 / 32 00 90     bank2 <- 2               ; SCC 창 닫힘
C297: CD B9 C2 / 38 1B     CALL probe / JR C,fail   ; ★쓰기 먹히면 실패(그냥 RAM)
C29C: 3E 3F / 32 00 90     bank2 <- 3Fh             ; SCC 창 열림
C2A1: CD B9 C2 / 30 11     CALL probe / JR NC,fail  ; ★쓰기 안 먹히면 실패
C2A6: AF / 32 8F 98 / 32 C0 98 / 32 E0 98           ; 뮤트 + deform(양쪽 좌표 모두)
C2B0: 3E 02 / 32 00 90 / 37 / C9                    ; 창 닫고 CY=1 성공
C2B7: A7 / C9                                       ; CY=0 실패
probe(C2B9): 21 00 98 / 7E 2F 77 BE / 20 02 37 C9 / A7 C9
             LD HL,9800h; LD A,(HL); CPL; LD (HL),A; CP (HL)
```
**우리 코어 판정: 통과.**
- 음성 시험: `sccMode=0` → `en_ram = m4|(m5&m2) = 0` → 쓰기 시 `mem_unmaped=1` →
  `msx_slots.sv:156-157`이 `sdram_ce`/`bram_ce`를 죽여 실제로 차단. 읽기는 `cpu_wr=0`이라
  `mem_unmaped=0`이므로 카트 메모리 정상 반환 → `~X != X` → CY=0 ✓
- 양성 시험: `bank2=0x3F` → `scc_req=1`, 모드 Compatible → 0x9800 = ch1 파형 RAM ✓
- 후속 `0x8F`(뮤트) 통과 / `0xC0`→리맵→`0xE0`(deform) ✓ / `0xE0`은 deform 창에 닿지만
  deform이 영구 비활성이라 무해

★★ **원본 SD Snatcher는 `0xBFFE <- 0`, 즉 Compatible 모드로 재생한다.**
2026-08-18에 고친 ch5=ch4 미러 결함이 정확히 이 모드였다. 수정 전이었다면 이 게임의
5번 채널이 깨진 채로 울렸을 것이다. → S5 정정 이력의 심각도 판단이 실증됨.

`[SCC+]` 패치판은 검출 루틴이 통째로 제거되어 있고(probe 시그니처 0건), 레지스터를
`0x98xx` → `0xB8xx`로 옮기며 freq/vol이 `0x8B` → `0xAB`로 **정확히 +0x20** 이동한다
(= openMSX의 Plus 좌표). 활성 `0xBFFE<-0x20` 후 `0xB000<-0x80`, 해제 `0xB000<-0x03` 후
`0xBFFE<-0x3F`. **접근 주소가 전부 0xB800-0xB8FF 이내**이므로 S3b 표의 △(SCC+ 창 256B)는
이 게임에서 무영향.

### (2) Snatcher (Konami 1988) — 모드 레지스터 RAM 쓰기보호 시험
파일 오프셋 `0x1817`. `[SCC]`판과 `[SCC+]`판이 **바이트 단위로 동일** = 코나미 원본 루틴:
```
21 FE BF        LD HL,0BFFEh
AF              XOR A
36 20 / 12      LD (HL),20h ; LD (DE),A     ; 모드 0x20 = RAM 쓰기금지 -> 이 쓰기는 막혀야 함
3C / 36 30 / 3D / 02
                LD (HL),30h ; LD (BC),A     ; 모드 0x30 = 전 세그먼트 RAM -> 이 쓰기는 먹혀야 함
36 20 / 3C / 12 / 36 30 / 02 / 3D / 36 20 / 12   ; 값 바꿔가며 반복
```
그리고 `0x1888`: `3E 30 / 32 FE BF` 후 읽고-반전-쓰고-되읽어 비교(RAM 쓰기 가능 확인).
BC와 DE는 0x1000 떨어진 두 주소라 앨리어싱까지 본다.

**우리 코어 판정: 통과.** `en_ram` 4식이 openMSX `MSXSCCPlusCart::setModeRegister()`의
`isRamSegment[0..3]`와 완전히 일치. → **TB D5로 상시 회귀 방어**(아래).

부가 사실: Snatcher 1988 `[SCC]`판은 사운드 카트리지의 **128KB RAM을 뱅크 전환 실행 메모리**로
쓴다(`0x9000`/`0xB000` 뱅크 레지스터). `[SCC+]`판은 대신 본체 메모리 매퍼 포트 `0xFC-0xFF`를
쓰고 `0xBFFE` 쓰기 헬퍼 2개가 `C9`(RET)로 무력화되어 있다. 즉 두 판의 차이는 음원이 아니라
**메모리 뱅킹 방식**이다.
`CART_TYP_SCC2`의 `ram_size=8` → `data_size = ram_size << 14` = **128KB** ✓ 실제 SCC-I와 일치.
(참고: `konami_scc.sv`의 `mem_size` 포트는 선언만 되고 미사용 = 뱅크 마스킹 없음. 128KB는
8KB×16뱅크이고 두 게임 모두 그 범위 안의 뱅크 값만 쓰므로 무영향. 기존 사항.)

### D5 — 모드 레지스터 RAM 게이팅 (tb_sccdetect.sv)
Snatcher 1988의 시험을 그대로 옮긴 검사. `mem_unmaped`를 쓰기 중에 포착해 세그먼트별
쓰기 허용 마스크를 openMSX와 대조한다(bit0=0x4000 … bit3=0xA000).

| 모드 | 기대 RAM 마스크 | 근거 |
|---|---|---|
| 0x00 | 0000 | 전부 보호 |
| 0x01 / 0x02 / 0x03 | 0001 / 0010 / 0011 | `mode&0x01`, `mode&0x02` |
| **0x20** | **0000** | ★Snatcher 쓰기금지 위상 |
| 0x24 | 0100 | `(mode&0x24)==0x24` — bit5와 bit2가 **함께**여야 함 |
| 0x04 | 0000 | bit2만으론 seg2가 RAM이 아님 |
| 0x10 | 1111 | bit4 = 전 세그먼트 RAM |
| **0x30** | **1111** | ★Snatcher 쓰기가능 위상 |
| 0x3F | 1111 | SD Snatcher 드라이버 복원값 |

**음성 대조**: `mem_unmaped`에서 `& ~en_ram` 항을 제거(=쓰기보호 무시)하면 **7건 FAIL**
(마스크가 전부 1111로 나옴). 검출력 확인됨.

현재 `sim/run_sccdetect.sh` 결과: **50 passed, 0 failed**.


## S7. SD Snatcher 판본 정리 + SCC+ 창 미러 사용 여부 확정 (2026-08-18)

| 판본 | "NOT ORIGINAL" 문자열 | 코나미 SCC 검출 probe | `@0xB3400` |
|---|---|---|---|
| jp **원본**(무표기) | 없음 | **있음** (0xB34BC) | `CD` |
| jp `[SCC+]` | 있음 | 없음 | `CD` (프로텍션 활성) |
| jp `[a][SCC+]` | 있음 | 없음 | **`C9` = RET (해제)** |
| 비-jp `[SCC+]` | 있음 | 없음 | **`C9`** (이미 해제) |
| 비-jp 원본 | 없음 | 없음 | `21` |

- `[SCC+]` 패치는 원본의 SCC 검출 루틴 영역(0xB3400-0xB3518)을 **자체 로더 + 디스크 복사방지**로
  덮어썼다. 실패 경로는 `"THIS DISK IS NOT ORIGINAL.$"` 출력 후 `18 FE`(JR -2) **무한 루프**.
- 프로텍션 본체(Z80 `0xC22D`): DTA 설정(BDOS 1Ah) → DOS 벡터 `0xF323` 후킹 → **BDOS 2Fh
  (절대 섹터 접근)** 로 섹터 `0x0E` 접근 → 벡터 복원. 원본 디스크의 의도적 결함 섹터를 보는
  전형적 방식이라 **표준 .dsk 이미지로는 통과 불가**.
- `[a]` = 그 진입점을 `C9`로 바꿔 무력화한 판(+0xB3445 `7D`→`97`).
- ★**실기 SCC+ 테스트에는 `[a][SCC+]` 또는 비-jp `[SCC+]`를 쓸 것.** jp `[SCC+]`(무-a)는
  프로텍션에서 멎을 가능성이 높다. 코나미 원본 SCC 검출 루틴을 보고 싶으면 **jp 원본(무표기)**.

### SCC+ 창 미러(0xB900-0xBFFD) 사용 여부 — 전수 조사 결과 **미사용**
`[a][SCC+]` 전체에서 즉시 주소 로드/저장(`32/3A/21/11/01/22/2A` + 상위바이트 0xB8-0xBF)을
전수 수집한 뒤, SCC 드라이버 구간(0x11000-0x11400)으로 좁히면 4건뿐이고 그 중 실제 SCC 접근은:
```
0x011322  32 FE BF   LD (0BFFEh),A    ; 모드 레지스터 (창이 아님 — openMSX/KUC도 0xBFFE-0xBFFF는 창에서 제외)
0x011334  32 FE BF   LD (0BFFEh),A
```
나머지 2건(`01 86 BE`, `01 8E BE`)은 `C4 42 56`(CALL NZ) 경계와 겹친 오탐.
파형/FREQ/VOL 접근은 전부 `0xB800`,`0xB820`,`0xB840`,`0xB860`,`0xB880`,`0xB8AF` = **0xB8xx 이내**.

→ **S3b 표의 △(SCC+ 창이 2KB가 아닌 256B)는 이 게임군에서 실결함이 아님이 데이터로 확인됨.**
   레지스터 세트 자체가 256B이므로 미러만 누락된 것이고, 실제 소프트가 미러를 쓰지 않는다.
   (다른 소프트가 미러를 쓸 가능성은 남으므로 표의 △ 표기는 유지한다.)


## S8. ★결함 2건 발견 — 검출은 통과하나 Snatcher 1988의 카트 RAM 적재가 깨짐 (2026-08-18)

독립 감사에서 나온 지적을 openMSX 원본·게임 코드·자체 TB로 3중 확인한 결과, **검출 통과와
별개로** 실사용 단계 결함 2건이 확정됨. (검출만 보고 종결하면 놓치는 유형.)

### S8-1 (심각) RAM 모드에서 뱅크 레지스터 쓰기가 억제되지 않음

`MSXSCCPlusCart::writeMem()`는 **명시적 우선순위 + early return** 구조다:
```cpp
if ((address | 0x0001) == 0xBFFF) { setModeRegister(value); return; }   // 1순위
int region = (address >> 13) - 2;
if (isRamSegment[region]) { ... internalMemoryBank[region][address & 0x1FFF] = value; return; }  // 2순위 ★return
if ((address & 0x1800) == 0x1000) { setMapper(region, value); return; }  // 3순위
```
즉 **세그먼트가 RAM인 동안 그 세그먼트의 2KB 뱅크 창에 쓰면 그것은 데이터이고 뱅크
레지스터에 닿지 않는다.**
(주의: `MegaFlashRomSCCPlus.cc`의 "우선순위 없이 여러 영역이 동시에 반응한다"는 주석은
**다른 클래스** 것이다. SCC+ 사운드 카트리지에는 적용되지 않는다.)

우리 `konami_scc.sv:29-41`은 뱅크 기록 조건이 `cs & cpu_mreq & cpu_wr`뿐 — `en_ram`을 보지 않는다.

**Snatcher 1988이 정확히 이 시맨틱에 의존한다.** 로더(파일 0xB1812, 바이트 대조 완료):
```
CD ED C2   CALL 0C2EDh     ; mode <- 0x20  (RAM 쓰기금지)
79 / 32 00 90   LD A,C / LD (9000h),A   ; -> 의도대로 뱅크2 설정
CD FB C2   CALL 0C2FBh     ; mode <- 0x30  (전 세그먼트 RAM)
01 00 20 / 11 00 80 / CD 27 CC          ; 8KB를 0x8000-0x9FFF로 복사
                                        ;   -> 0x9000-0x97FF 를 관통한다
```
복사가 0x9000에 닿는 순간 우리 코어는 **데이터 바이트를 뱅크2로 래치**하여 CPU 밑의 8KB
창이 전송 도중 이동한다 → 카트 RAM 적재 붕괴. 8KB 페이지 4개가 각각 2KB 뱅크 창을 하나씩
품고 있어 **안전한 페이지가 없다**.

★검출 자체는 이 결함이 있어도 통과한다(쓰기·되읽기가 같은 새 뱅크를 보므로). 검출 통과를
근거로 종결하면 안 되는 이유.

**재현(TB D6)**: `mode=0x20`에서 `0x9000<-0x05` → 뱅크2=5 ✓ / `mode=0x30`에서 `0x9000<-0xAA`
→ 뱅크2가 **0xAA로 오염**. `0xB000<-0x55` → 뱅크3이 3에서 **0x55로 오염**. 현재 2 FAIL.

**수정안**: `konami_scc.sv:29`의 뱅크 case를 `~en_ram`으로 게이트 + `scc_req`에 `& ~en_ram`
추가 + `0xBFFE/0xBFFF` 디코드를 `mem_unmaped`에 포함(모드 쓰기가 RAM에도 기록되지 않도록).
**회귀 위험 낮음**: `sccDevice=0`(일반 SCC ROM 카트)은 `sccMode`가 항상 0이라 `en_ram`이 늘
0 → 거동 불변. 영향은 `CART_TYP_SCC2`/MFRSD 계열에 국한된다.

### S8-2 (심각) 뱅크 마스크/바운드 없음 → 할당 영역 밖 SDRAM 접근

`konami_scc.sv:5`의 `mem_size` 포트는 **선언만 되고 본문에서 미사용**(비교: `konami.sv:43`은
`mem_addr > rom_size` 바운드 체크 수행). `konami_scc.sv:63` `mem_addr = {bank_base, cpu_addr[12:0]}`
는 raw 8비트 뱅크를 그대로 쓴다. `msx_slots.sv:120` `ram_addr = base_ram + mapper_addr`에도
바운드가 없다.

openMSX `setMapper()`: `value &= mapperConfig.registerMask;` 후 `value < numBlocks`가 아니면
`isMapped=false`(읽기 0xFF/쓰기 무시). 128KB "expanded"면 `registerMask=0x0F` → **미러링**.

**실패 조건**: 뱅크 값 ≥ 0x10. 특히 **SCC+ 활성화에 bank3 bit7이 필수**이므로 `bank3=0x80|N`이
곧바로 `mem_addr = 0x100000` → `base_ram + 1MB`. `mode` bit4가 서 있으면 **쓰기까지** 나가
다른 카트/메인 RAM 영역을 오염시킬 수 있다.
SD Snatcher `[SCC+]`는 SCC 창(0xB8xx)만 쓰고 `0xA000-0xB7FF`를 건드리지 않아 실害는 관측되지
않을 가능성이 높지만, 잠재 결함으로 남는다.

**수정 시 주의**: `MAPPER_KONAMI_SCC`는 일반 Konami-SCC **ROM** 카트에도 쓰인다. 마스킹을
무조건 적용하면 전 SCC 게임의 주소 계산이 바뀐다 → [[feedback-vdp-timing-change-protocol]]
1항(공용 신호는 소비처 전수조사 후 수정)에 해당. S8-1과 **분리해서** 다루고, 필요하면
`sccDevice`/RAM 카트로 스코핑할 것.

### 상태
- S8-1: TB D6로 재현 확정. **미수정.**
- S8-2: 코드 경로 확인. **미수정.**
- S3(Compat 0xE0-0xFF deform 누출), S4(SCC+ 창 256B)는 S6/S7대로 **무해 확인됨**.


## S9. 교차검증 정정 및 S8-1 2차 확증 (2026-08-18)

### 정정 1 — 파일↔Z80 베이스 `0xA7200`은 **전역 상수가 아니다**
S6에 적은 베이스는 `0xC200-0xC31x` 블록(파일 0xB3400-0xB3520)에 **한정**해서만 참이다.
이 디스크는 표준 로더가 아니라 여러 단계로 서로 다른 주소에 적재되는 커스텀 포맷이라,
같은 파일의 `0x11300` 부근(SCC 드라이버)은 전혀 다른 로드 주소를 쓴다. S6 문장은 그 블록
한정으로 읽을 것.
(교차검증: 부트섹터 파일오프셋 0x36의 `CD 00 C2`, 그리고 직전 `LD DE,0xC200`으로 디스크 읽기
목적지를 C200으로 지정하는 코드 — 강한 정황. `CD 89 C2`가 파일 전체에서 유일 1건이고 정확히
0xB3470(=C270)에 위치.)

### 정정 2 — `[SCC+]` 패치가 검출을 "제거"한 것이 아니다
S6/S7에서 "패치판은 검출 루틴이 통째로 제거됨"이라 적었으나 부정확하다.
- `0x9800` probe(`7E 2F 77 BE`)가 사라진 것은 사실(원본 jp Disk1에만 1건).
- 그러나 파일 `0xB1A70` 부근에 **슬롯 순회 + 뱅크 write/readback 검증 + `0xBFFE` 토글**을
  갖춘 대등한 탐지 루틴이 **원본·패치판 양쪽에 존재**하며, 차이는 `0xBFFE` 쓰기 3곳이
  원본에서 `00 00 00`(NOP)로 무효화되어 있다는 점뿐이다.
  → 성격은 "검출 제거"가 아니라 **"원본에서 잠들어 있던 SCC-I 경로를 패치가 깨운 것"**.

`LD (BFFE),A` 건수: jp 원본 **1** / jp `[SCC+]` **20** / 비-jp 원본 **10** / 비-jp `[SCC+]` **20**.
★비-jp(영문) "원본"이 이미 10건을 가진 점에 주의 — 순수 무패치 원본이 아닐 가능성이 높다.
**코나미 원본 검출 루틴을 보려면 jp 원본(무표기)을 쓸 것.**

### 정정 3 — 검출 실패 시 동작
정지도 메시지도 없다. `C200`은 `CALL C209`(EXPTBL fast-path) → `CALL NC,C239`(전 슬롯 순회,
1차 슬롯 0→3, EXPTBL bit7로 확장 판정, 확장이면 서브슬롯 0→3을 `A+=4`로) → 첫 성공에서
`RET C` 조기 종료 → 이후 `JP C22D`(드라이버 LDIR 설치)는 **무조건** 실행. 부트 코드는 CY를
확인하지 않고 진행한다. 즉 카트가 없으면 **음원만 조용히 꺼진다**.

### ★S8-1 2차 확증 — SD Snatcher `[SCC+]`도 같은 결함에 걸린다
`0xB1ABF` 루틴과 그 호출자 `0xB1AA6`:
```
0B1ABF: 3E 20 / 32 FE BF     ; mode <- 0x20  (RAM 보호)
0B1AC4: 79 / 32 00 90        ; LD A,C / LD (9000h),A   -> 뱅크2 설정 (의도대로)
0B1AC8: 3E 3F / 32 FE BF     ; mode <- 0x3F  (전 세그먼트 RAM)
0B1ACD: C9

0B1AA6: 01 08 08             ; LD BC,0808h   (8회 루프)
0B1AA9: C5 / CD BF 1A        ; PUSH BC / CALL 위 루틴
0B1AAD: 69 61                ; LD L,C / LD H,C
0B1AAE: 22 00 90             ; LD (9000h),HL   ★RAM 상태에서 0x9000에 데이터 기록
0B1AB1: 22 02 90             ; LD (9002h),HL   ★
0B1AB4: C1 0C 10 F0          ; POP BC / INC C / DJNZ
```
**Snatcher 1988 로더(S8-1)와 동일한 "보호→뱅크설정→RAM전환→데이터접근" 패턴.**
`mode=0x3F`(bit4=전 RAM)에서 `LD (9000h),HL`은 데이터여야 하는데 우리 코어는 L을 뱅크2로
래치한다 → 창이 이동 → 뱅크 테스트 결과가 쓰레기가 된다.

→ **S8-1의 영향 범위는 Snatcher 1988 단독이 아니라 SD Snatcher `[SCC+]`를 포함한다.**
   메커니즘이 서로 다른 두 게임에서 각각 독립적으로 확인되었으므로 우연이 아니다.

### 해소 — `0xBFFE`가 256바이트 창 밖이라는 우려는 문제 아님
`0xBFFE/0xBFFF`는 SCC 창이 아니라 **모드 레지스터**이며 `konami_scc.sv:44`
`{cpu_addr[15:1],1'b0} == 16'hBFFE & sccDevice`로 **별도 디코드**된다.
openMSX도 동일하게 창에서 제외한다(`KonamiUltimateCollection.cc:93` "SCC+ range: 0xB800..0xBFFF,
**excluding 0xBFFE-0xBFFF**"). TB D2/D3가 `0xBFFE`·`0xBFFF` 별칭과 `0xBFFD` 비반응을 검사하며
통과 중. → S4(창 256B)는 여전히 무해.

### Disk 2/3
`[SCC+]` Disk2는 SCC 접근 코드 **전무**(Disk1이 상주시킨 드라이버에 얹혀감), Disk3은 6건인데
**파일오프셋·바이트가 Disk1과 완전히 동일** = 같은 상주 커널 이미지를 복제 배포. 새 주소 없음.
