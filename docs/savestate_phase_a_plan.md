# MSX1 코어 Savestate — Phase A 기획서 (2026-08-15 초안)

## 0. 목표와 비목표
**목표**: 카트리지 게임(비디스크·비MoonSound)의 플레이 상태를 OSD에서 저장/복원.
단일 슬롯, 파일 = `<게임명>.ss1` (SD의 savestates 폴더 관례).
**비목표 (Phase B로 이월)**: MoonSound 완전 복원(OPL3 위상/PCM 슬롯/SDRAM 웨이브 2MB),
디스크(FDD/Nextor) 게임 상태 정합, 멀티슬롯, 되감기.

## 1. 프레임워크 현실 (조사 완료)
- `sys/hps_io.sv`에 savestate 전용 버스 **없음**. 단 `ioctl_upload_req/ioctl_upload_index`
  (146-148행)로 **코어→HPS 파일 업로드** 경로 존재 → 저장 전송로로 사용.
  복원은 기존 ioctl download(신규 인덱스, FC 메뉴 항목)로.
- T80: `REG[211:0]` 읽기 출력 존재(IFF/IM/전 레지스터) → **저장은 무개조**.
  복원은 T80_Reg에 병렬 로드 포트 추가 필요(아래 WP1).

## 2. 상태 인벤토리 (Phase A 포함분)
| # | 블록 | 크기 | 취득 방법 |
|---|---|---|---|
| 1 | T80 전 레지스터+IFF/IM | 27B | REG 포트 (기존) |
| 2 | 메인 RAM (systemRAM) | 256KB | pause 중 BRAM 포트 뮤ックス로 순차 덤프 |
| 3 | VRAM lo/hi | 128KB | 동일 (VRA2/VRA3) |
| 4 | VDP 레지스터 R#0-46 + 팔레트 32B + 상태포트 어드레스 래치 | ~96B | **섀도우 방식**: MSX1 레벨에서 0x99/0x9A/0x9B 쓰기를 미러 (VHDL 무개조) |
| 5 | 매퍼 상태 (RAM매퍼 FC-FF, 카트A/B bankRegs, SCC뱅크) | ~32B | 섀도우 또는 기존 신호 인출 |
| 6 | PSG 레지스터 16B ×1 | 16B | 섀도우 |
| 7 | OPLL(ikaopll) 레지스터 | 64B | 섀도우 (내부 위상은 포기 — 복원 후 수 ms 과도음 허용) |
| 8 | SCC 파형 RAM+레지스터 | ~256B | SCC는 CPU 주소창에 매핑 → 섀도우 불요, 뱅크 상태만 |
| 9 | PPI/키보드 행선택/슬롯 셀렉터 | ~8B | 기존 신호 |
| 10 | 헤더(매직/버전/코어설정 해시/ROM 식별자) | 64B | 신규 |
**합계 ≈ 385KB** → ioctl 전송 ~1초 내.

### 명시적 제외 (헤더 플래그로 기록, 복원 시 경고)
- MoonSound: 레지스터 섀도우만 저장(옵션), 웨이브 RAM/엔진 상태 제외 →
  복원 후 해당 게임 음악 깨짐 가능 명시. Phase A에선 **MoonSound 활성 시 저장 차단**이 기본.
- SDRAM 가변영역(ASCII16X flash 8MB, MegaRAM): 제외. flash 게임은 저장 차단(감지: is_ascii16x).
- VDP 내부 카운터/스프라이트 파이프라인: 복원을 **vblank 경계에 정렬**해 자연 재동기.
  커맨드 엔진 실행 중(CE=1) 저장 차단 (S#2 폴링으로 대기).

## 3. 아키텍처
### 3.1 저장 시퀀스 (save engine FSM, clk21m)
1. 트리거: OSD `T[45] Save State`
2. **정지 프로토콜**: msx_pause 세트 → 2프레임 대기(비디오/오디오 파이프 드레인)
   → 게이트 검사: `sd_rd|sd_wr|sd_ack` idle 8프레임 이상, flash FSM idle, VDP CE=0,
   MoonSound 브리지 idle(ms_io_pending=0). 하나라도 실패 시 저장 거부+OSD 메시지.
3. 덤프: 헤더 → T80 REG → 섀도우들 → RAM 256KB → VRAM 128KB 순으로
   내부 시퀀서가 BRAM을 읽어 ioctl_upload로 스트리밍.
4. msx_pause 해제(원래 pause 상태 보존).

### 3.2 복원 시퀀스
1. FC 메뉴 `Load State` → ioctl download로 버퍼링하며 검증(매직/버전/ROM 식별자 일치).
   불일치 시 전량 거부(부분 적용 절대 금지).
2. msx_pause 세트 → RAM/VRAM 기록 → 섀도우값을 실 레지스터에 재주입
   (VDP/PSG/OPLL/매퍼: 내부 쓰기버스 뮤ックス — 각 블록의 기존 CPU-write 경로 재사용)
3. T80 복원: **WP1 로드포트**로 REG 주입 (RESET과 동시에 load_en, PC/SP/IFF 포함)
4. vblank 경계까지 대기 → msx_pause 해제.

### 3.3 T80 로드포트 (WP1 — 유일한 서드파티 개조)
T80_Reg.vhd에 쓰기 포트(레지스터 파일은 이미 RAM형) + T80.vhd에 PC/SP/IFF/IM
동기 로드 입력. 개조량 ~60줄. 대안(RAM 부트스트랩 스텁 주입)은 스텁 자리의
원본 바이트 복원 불가 문제로 **기각**.

## 4. FDD/HDD 리스크와 Phase A 정책 (핵심)
| 리스크 | 내용 | Phase A 정책 |
|---|---|---|
| R1 전송 중 스냅샷 | sd_* 핸드셰이크의 HPS측 상태는 저장 불가 → 복원 시 탈조 | 게이트에서 sd idle 강제 (3.1-2) |
| R2 미디어 정합성 | 복원된 RAM의 FAT 캐시/열린 파일이 현재 마운트 이미지와 불일치 → **이후 쓰기가 FS 파괴** | **마운트된 쓰기가능 이미지 존재 시 저장/복원 자체를 차단** (img_mounted && !img_readonly). 디스크 게임은 Phase A 대상 외임을 OSD 메시지로 명시 |
| R3 flash .sav 연동 | 상태 복원과 dirty-bitmap .sav 분기 | flash 카트 감지 시 차단 (2절) |
| R4 저장 파일 자체 | .ss1 기록 중 전원 차단 → 부분 파일 | 헤더에 길이+CRC, 복원 시 검증 |
Phase B에서 R2 완화(이미지 해시 동봉 + 불일치 시 read-only 강제 마운트) 후 디스크 게임 개방.

## 5. OSD/UX
- `T[45] Save State`, FC `Load State` (savestates/<코어>/<게임>.ss1)
- 거부 사유는 pause 심벌 오버레이 인프라 재사용해 코드 표시(예: 심벌 옆 소형 문자)
  — Phase A는 최소한 "저장됨/거부" 2상태 표시.

## 6. 공수/리스크 산정
| WP | 내용 | 공수(세션) | 리스크 |
|---|---|---|---|
| WP1 | T80 로드포트 | 1-2 | 중 — CPU 개조, 회귀는 전 게임에 파급. TB 필수 |
| WP2 | 섀도우 레지스터망 (VDP/PSG/OPLL/매퍼) | 1 | 저 |
| WP3 | save/restore 시퀀서 + BRAM 뮤ックス | 1-2 | 중 — RAM 포트 뮤ックス가 크리티컬패스 부근 |
| WP4 | ioctl 전송(업로드/다운로드) + 헤더/CRC | 1 | 저-중 (upload_req의 HPS측 지원 실증 필요 — 최우선 스파이크) |
| WP5 | 재주입 버스(각 블록 write 경로 뮤ックス) | 1 | 중 |
| WP6 | 게이트/차단 정책 + OSD | 0.5 | 저 |
| WP7 | 검증: TB(시퀀서/CRC/T80 로드) + 실기 매트릭스 | 1-2 | — |
**합계 ≈ 6-9 세션.** 최우선 스파이크 = WP4(ioctl_upload가 이 코어 HPS main에서
실제 파일로 떨어지는지 30분 실증 — 안 되면 전송로를 sd_* 가상디스크 방식으로 전환).

## 7. 실기 검증 매트릭스 (Phase A 완료 조건)
1. Neon Horizon / Xevious / Zanac-EX: 플레이 중 저장→리셋→복원→이어하기 정상
2. 저장 직후/복원 직후 오디오 과도음 1초 내 정상화
3. 거부 케이스: MoonSound 게임, flash 카트, (디스크 마운트 시) — 명확한 거부 동작
4. 손상 .ss1(절단/CRC오류) 복원 시도 → 거부 + 기존 상태 무변화
5. 복원 30회 반복 내성 (메모리 누적/탈조 없음)
6. savestate 미사용 시 전 게임 무영향 (핵심 회귀 조건)

## 8. 미결/후속 결정
- ss1 포맷 버저닝 정책 (코어 업데이트 간 호환 포기 선언 여부)
- pause 심벌 오버레이(별도 진행 중)와 표시 영역 조정
- Phase B: MoonSound 상태(웨이브 SDRAM 동봉 → 상태 ~3MB), 디스크 해시 정합, 멀티슬롯
