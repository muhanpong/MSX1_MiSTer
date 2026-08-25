# vgmplay × MoonSound (YMF278B/OPL4) 디버깅 — 세션 정리

작성: 2026-06-06. **검증된 사실**과 **가설(미검증)** 을 명확히 구분한다.

---

## ✅ 검증된 사실

### 1. OPL Timer-1 연속 틱 미동작 → vgmplay 즉시 freeze
- vgmplay-msx/sharksym은 `TimerFactory_Create`로 타이머를 고르고, 순서는
  **TurboR → OPL → Line → VBlank**. MoonSound 있는 비-TurboR MSX에선 **OPLTimer 선택**.
- OPLTimer는 OPL Timer-1 인터럽트로 재생 틱(`Update.Wait`가 `tick` 스핀)을 구동.
- 우리 OPL3 코어가 **Timer-1 연속 틱/IRQ를 못 내서** 첫 틱에서 무한 대기 → **즉시 freeze, 무음**.
  단발 overflow 검출은 됨(MBwave는 동작 — MBwave는 검출만 OPL, **재생 타이밍은 VDP**로 추정).
- **우회**: TimerFactory에서 `call nc,TimerFactory_CreateOPLTimer` 한 줄 주석 처리 → VDP(Line/VBlank)
  타이머 폴백. 빌드한 `vgmplay-noopl.com`은 즉시-freeze 안 함.
- 상태: **OPEN (우회만).** 근본 수정 = `timers.sv`/CDC의 연속 IRQ+status[6].

### 2. custom-PCM 업로드 방식 차이가 freeze를 가른다
- vgmplay은 샘플 데이터블록을 **Z80 `otir`** 로 reg 0x06(포트 0x7F, auto-increment)에
  **무페이싱 연속 출력**한다(바이트당 ~21 T-state ≈ 5.9µs, 갭 없음).
  → 우리 throttle-없는 CDC/ch4 경로를 압도.
- **pcmload**(`../moondrv/src/pcmload/pcmload.asm`)와 **MoonDriver**는 매 바이트
  **BUSY 폴링/소프트웨어 오버헤드**로 페이싱(~15µs+/byte) → 우리 하드웨어에서 멀쩡.
  즉 "PCM 업로드 자체"가 아니라 **업로드 페이싱**이 문제.

### 3. WAIT_n 흐름제어 + mem-write ack 지연 = 칩 BUSY throttle 재현 → 작은 업로드 해결
- `rtl/msx.sv`: MoonSound I/O(0x7E/7F/0xC4-C7) 접근 중 **WAIT_n으로 CPU hold**,
  `ms_io_ack` 돌아올 때까지(타임아웃 10비트=600 안전장치). `moonsound_en` 한정.
- `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_regs.sv`: reg 0x03~0x06 **쓰기**의 `io_ack`을
  **BUSY 클리어(`busy_cnt==0 && !pcm_cpu_mem_busy`)까지 지연**(읽기의 `pcm_rd_wait` 미러).
  `MEM_WRITE_DELAY` 28→1024(~12µs/byte) — 작은 값은 otir 5.9µs에 묻혀 페이싱 안 됨.
- **결과(하드웨어 확인)**: **ST02(28KB 업로드)가 freeze 없이 전곡(1.27초) 재생** (이전엔 즉시 freeze).
- 커밋: `WAIT_n`(msx.sv), `defer wave-memory write ack`(ymf278b_regs.sv).

### 4. 큰 업로드(ST04)는 업로드는 통과, freeze가 재생으로 이동
- ST04 = 22.3초, 데이터블록 6개 전부 t=0(총 ~161KB otir 업로드).
- 위 페이싱 빌드(MSX1_20260606)에서 **(b) 긴 무음 로딩(~2초, throttle 걸림) → 잠시 연주 → freeze**.
  즉 **업로드는 완료, freeze가 재생 단계로 이동**.
- ST04(>128K)는 vgmplay 매퍼 버퍼(128K) 초과 → **재생 중 디스크 스트리밍**.
- **freeze 시점이 업로드 길이에 비례**(ST02 0.17s→즉시, ST04 0.95s→1-2s, DDP 더 큼→3-4s)
  — 이전 빌드 데이터로 확인된 상관관계.

### 5. 메모리 맵 (런타임)
| 메모리 | 위치 |
|---|---|
| yrw801 ROM + custom RAM (PCM 샘플) | **SDRAM ch4** (`pcm_sdram_addr→ch4`, `pcm_rom_base+mem_addr`) |
| FW 팩(yrw801 원본) | **DDR3 0x2000000** (부팅 소스, 부팅 때 SDRAM으로 복사) |
| 부팅 yrw801 로드(2MB) | **SDRAM ch1** (`upload_active→ch1`) — **정상 동작**(sustained 쓰기 자체는 안 깨짐) |
| MSX 메인 RAM | **BRAM(온칩)** — SDRAM 아님 |
| 카트리지 ROM/RAM | SDRAM ch2 |

### 6. reg-0x06 read는 NEW2 필요 (테스트 방법론 노트)
- wave/PCM 파트 접근 전 **NEW2(OPL3 reg 0x105 bit1)를 켜야** 함:
  `OUT&HC6,5:OUT&HC7,3` (NEW+NEW2). 안 켜면 cold에서 0 반환.
- NEW2 켜면 reg-0x06 읽기가 정확(yrw801[0]=0x40). **읽기 경로는 정상으로 보임.**
- vgmplay은 곡 시작에 NEW2를 켬(`D0 p1 r05=03`) → 읽기 정상.

### 7. 도구/소스
- `../vgmplay-msx`(upstream okei), `../vgmplay-sharksym`(fork, MMC/SD+wave-number-mapping).
  둘 다 **Glass**(`tools/glass.jar`, Java) `make`로 빌드. 산출물 `bin/vgmplay.com`(32512B).
- 진단 빌드: `vgmplay-noopl.com`(OPL타이머 스킵), `vgmplay-hb.com`(noopl+화면 하트비트).
- 테스트 VGM: `vgm_test/`(vgmrips MoonDriver Demo, Strikers 1945). 8.3 리네임 사본+배치: `vgm_test/sdcard/`.
- sharksym은 ROM 데이터블록을 **FixUpWaveHeaders(헤더 byte0 |= 0x20 = startAddr bit21=+0x200000)** 로
  RAM 재배치 + `MapWaveNumber` 리맵.

### 8. ICS2115(IGS PGM) 비교 (docs/ics2115_analysis.md, ics2115_vs_ymf278b.md)
- ICS2115 = **voice당 캐시(채널 키잉, 상호 eviction 불가) + miss시 stall** → read budget 자체가 없음.
  우리는 고정 read-budget 스케줄링(드롭). → 교훈: **per-slot 버스트라인 캐시**가 read 드롭 해법.
- 호스트 쓰기 분리(FIFO + 별도 채널)가 sustained-write 해법 (ICS 레지스터 FIFO 모델).
- ★주의: 캐시는 BRAM+FSM이어야(거대 조합클라우드는 SDRAM IOB 패킹 깨뜨림 — 기존 교훈).

---

## ❓ 가설 (미검증 — 사실로 취급 금지)
- **ST02 음색 오류 원인**: 읽기는 정상으로 보이므로, **업로드 재배치(샘플 주소 vs 헤더 bit21 일치)
  또는 custom-wave(≥384) 재생 경로** 의심. 미확정. → custom RAM 덤프(NEW2 켜고) openMSX 대조 필요.
- **ST04/큰파일 재생 freeze 원인**: 스트리밍(>128K 버퍼 초과)으로 추정하나 미확정.
- **MD06(큰 yrw801-only) freeze**: custom-PCM 업로드 없음 → 별개. 스트리밍 vs 재생 rate-race 미확정,
  WAIT_n 빌드로 재테스트 안 함.
- (폐기) "sustained ch4 쓰기 volume이 컨트롤러 손상" — 페이싱 발견으로 약화됨.
- (폐기) reg-0x06 read off-by-one / cold-read 하드웨어 버그 — **테스트 프로그램이 NEW2 누락이었음**.

---

## 📋 Task 목록 (TaskCreate)
1. OPL Timer-1 연속 틱 (즉시 freeze) — OPEN(우회)
2. 작은 custom-PCM 업로드 rate-race — **FIXED ✅**(WAIT_n+deferred ack, ST02 검증)
3. 큰 업로드(ST04/DDP) — 업로드는 페이싱으로 통과, 재생 freeze 남음(=스트리밍 추정)
4. 큰 yrw801-only(MD06) freeze — 원인 미확정, WAIT_n 재테스트 필요
5. WAIT_n 빌드 타이밍 — MSX1_20260606에서 +0.359ns로 양호(대체로 해소)
6. custom-PCM 음색 오류 — OPEN, 원인 미확정(읽기 아님)

## 배포본
`MSX1_20260606.rbf` = WAIT_n + deferred mem-write ack(MEM_WRITE_DELAY=1024) + FW재배치 + custom RAM zerofill.
worst setup +0.359ns. (192.168.1.86 배포됨.)
