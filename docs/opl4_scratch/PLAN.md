# OPL4 (YMF278B) from-scratch 재제작 계획

작성 2026-10-24. 대상 저장소: MSX1_MiSTer, 작업 기준 브랜치 V9968_Geo3D (worktree `~/data/MiSTer_build/sdram128`).
기존 구현: `rtl/peripheral/SOUND/ymf278b_fpga/` (OPL3 FM = gtaylormb `opl3`, PCM = `rtl/pcm/ymf278_pcm_engine2.sv`, "v3 sequential slot machine").

## 0. 왜 다시 만드나 (측정된 사실)

| 항목 | 현재 | 근거 |
|---|---|---|
| MoonSound 전체 ALM | 4,105 (M10K 15, DSP 0) | `output_files/MSX1_V9968.fit.rpt`, `ymf278b_top:u_moonsound` |
| 그중 PCM | 2,828 ALM | `ymf278_pcm_engine2:u_pcm` |
| 그중 FM (gtaylormb) | 1,032 ALM, M10K 14 | `opl3:u_opl3` |
| 참고: srg320 PCM | 약 960 ALM, 그러나 비트 오류 4건 + 동작 차이 다수 | `sim/golden_srg/README.md` |
| 메모리 쓰기 WAIT | 1024 clk_sdram (7.95 µs, 3.58 MHz에서도 걸림) | `rtl/ymf278b_regs.sv:82`. 실칩/openMSX는 약 28 마스터 클럭, BUSY 비트만 |
| 그 WAIT을 줄이면 | R800 OTIR 업로드에서 지연 ≤ 200이면 바이트 손실(107: 698/556 오류), ≥ 300 무손실 | 2026-10-24 fullsys 측정 `/data/_claude/tmp/msx1-handoff/ms_wdelay/` (mprobe, 음성 대조 포함) |
| 128.86 MHz 수렴 | PIPE 연구, 다단 땜질 (CHIT0, EGPRE2, 스냅샷 디스패치 ...) | `git log -- rtl/pcm` 30커밋 (2026-08 이후) |

128.86 MHz에서 44.1 kHz 한 프레임은 **2,922 클럭**이다. PCM 24슬롯이면 슬롯당 약 121클럭, FM 36 오퍼레이터까지 넣어도 시간이 남는다.
현재 엔진은 85.9 MHz의 72클럭 슬롯 창(1,948클럭 프레임)을 전제로 설계된 뒤 128 MHz로 끌어올려졌다. 시간 예산이 1.5배인데 면적을 줄이는 쪽으로 쓰지 못했다.

## 1. 목표 (게이트로 판정)

1. **비트 정확**: PCM은 openMSX `YMF278.cc` 포트(`sim/golden/ref278.cpp`)와 샘플 단위 일치, FM은 Nuked-OPL3와 일치(현행 수준 이상).
2. **드롭인**: `ymf278b_top`의 포트, I/O 의미(7Eh/7Fh, C4h-C7h, 상태/BUSY/타이머/ID, reg 0x02-0x06 메모리 접근, 헤더 재배치, DAMP, pseudo-reverb, LFO, F8h/F9h 믹스)를 그대로 유지. 새 PCM 엔진은 `ymf278_pcm_engine2`와 **같은 모듈 포트**를 갖는다(기존 벤치가 그대로 돈다).
3. **면적**: PCM ≤ 1,200 ALM, MoonSound 전체 ≤ 2,500 ALM (FM을 재제작할 경우). M10K는 현재 15개 이하, DSP ≤ 4.
4. **타이밍**: 128.86 MHz 단일 클럭 내부 경로는 SDC 예외 없이 통과. CDC는 문서화된 동기화기만.
5. **CPU에 보이는 시간**: 메모리 쓰기 BUSY는 **쓰기가 SDRAM에 실제로 반영된 시점**에 내린다(현행은 엔진이 쓰기를 *발행*할 때 내림: `ymf278_pcm_engine2.sv:1703,1722`, 그래서 `MEM_WRITE_DELAY`가 그 틈을 덮고 있다). 그 위에서 CPU WAIT은 openMSX 수준(약 0.83 µs = 107 clk). BUSY 상한은 구조적으로 보장(현행 v3의 장점 유지).
6. **메모리**: `sdram_tdm` ch4(16비트 워드 쌍 읽기, 가변 지연 1~40 clk)에서 출력이 지연과 무관.

비목표: 85.9 MHz 빌드 지원(128.86 MHz 전용), 15 kHz/ESE 빌드 전용 최적화.

## 2. 아키텍처 방향 (P1에서 확정)

- **시간 다중화 단일 데이터패스**: 슬롯 상태는 MLAB/M10K, 연산 자원은 덧셈기 1~2개 + 18x18 DSP 1개 + 시프터 1개. 슬롯당 고정 마이크로시퀀스(약 100클럭 예산, 여유 20%).
- **레지스터 파일**: 슬롯 레지스터는 현행처럼 per-byte MLAB(검증된 방식, reset 중 클리어, `reset_ms >= 24 clk` 전제). Quartus가 실제로 RAM으로 추론했는지는 **map 보고서 RAM summary**로만 판정.
- **메모리 접근**: 슬롯 창 앞부분에서 프리페치 요청, 데이터 도착은 핸드셰이크(블로킹). 헤더 페치/CPU 메모리 연산은 프레임 서비스 창에서 무조건 처리.
- **FM**: P6에서 결정. 선택지 (a) gtaylormb 유지, (b) 같은 시퀀서 위에 36 오퍼레이터 시분할(Nuked 대조). (b)는 면적 이득이 크지만 위험도 크다.

## 3. 단계

| 단계 | 내용 | 끝나는 조건 (게이트) |
|---|---|---|
| P0 사양 고정 | 현행 v3/v2의 "하드웨어 검증 의미론" 목록, openMSX와의 의도적 차이(eg_cnt 오프바이원, EG_OFF LFO, vib ÷12 절단)를 `SPEC.md`로 정리. 실제 소프트웨어 레지스터 트레이스(openMSX에서 MoonBlaster/vgmplay/OPL4 데모) 수집 | 사양 항목마다 테스트 시나리오 이름이 붙음 |
| P1 하네스 먼저 | `opl4-harness` 스킬의 게이트 전부가 **현행 엔진으로 PASS, 뮤턴트로 FAIL** | `harness.sh all` PASS + `harness.sh mutants` 전부 FAIL |
| P2 골격 | CPU 인터페이스, 레지스터 파일, 메모리 읽기/쓰기, 상태/BUSY | G-cpu, G-busy, G-reset |
| P3 데이터패스 | 스텝/보간/EG/LFO/팬/믹스 | G-golden(ref278 + golden_pcm.py) 전 시나리오 비트 일치 |
| P4 통합 | `ymf278b_top`에 연결, 기존 엔진과 CPU 가시 출력 lockstep, fullsys (OPL4 감지, vgmplay freeze, PCM 업로드) | G-lockstep, G-fullsys |
| P5 면적/타이밍 | Quartus map-only → fit, ALM/RAM 게이트, STA | G-resource, G-timing |
| P6 FM 결정 | (a)/(b) 중 선택, (b)면 Nuked 골든 | G-fm |
| P7 보드 | 결정적인 한 번: 체크리스트(아래) 녹음 비교 | 사용자 확인 |

각 단계는 별도 커밋. 엔진 교체는 `ifdef`가 아니라 qip 파일 교체로 하고, 기존 엔진은 lockstep 오라클로 저장소에 남긴다.

## 4. 오라클과 대조군

| 오라클 | 위치 | 용도 |
|---|---|---|
| openMSX YMF278.cc 포트 | `sim/golden/ref278.cpp` | PCM 샘플 비트 정확(실칩 대리) |
| 파이썬 모델 | `sim/golden/golden_pcm.py` | 시나리오별 비교(ref278로 자체 검증됨) |
| 현행 엔진 | `rtl/pcm/ymf278_pcm_engine2.sv` | CPU 가시 동작 lockstep, 회귀 기준 |
| Nuked-OPL3 | `sim/golden/fm/` | FM |
| openMSX 본체 | `~/data/openmsx_v9968` | BUSY/타이밍/소프트웨어 트레이스 |

**규칙**: 어떤 PASS도 그 게이트를 FAIL시키는 뮤턴트 없이는 보고하지 않는다. 숫자는 대조군과 함께 보고한다.

## 5. 알려진 함정 (이 프로젝트에서 실제로 밟은 것)

- 컴파일 실패가 이전 바이너리를 남겨 "ALL MATCH"가 나온 적이 있다 → 빌드 디렉터리 통째 삭제 후 빌드, 바이너리 없으면 FAIL.
- `ramstyle`을 붙인 배열이 generate 안에서 **경고 없이** 플립플롭이 됐다 → RAM summary로 판정.
- 고정 인덱스 디버그 읽기 포트가 RAM 추론을 깼다(경고 10999) → 디버그 포트는 별도 스냅샷 레지스터로.
- 레지스터 파일 클리어는 reset 길이에 의존(≥ 24 clk) → `run_stress.sh`의 reset_len=8 must-fail 케이스 유지.
- 골든 시나리오는 슬롯을 읽는 순간 근처의 레지스터 쓰기를 거의 만들지 않는다 → stress 벤치 필수.
- 시뮬레이션 stdout이 줄을 잃을 수 있다(`cmp_time.sh` 참고) → 결과는 파일로 남기고 파일에서 판정.
- Quartus 작업은 한 번에 하나. 보드 테스트는 비싸다: 시뮬레이션 양/음성 대조로 먼저 결론.

## 6. 보드 체크리스트 (P7)

1. MoonSound 감지 (BIOS/툴의 OPL4 ID, reg 0x02 ID 비트)
2. vgmplay OPL4 곡 3곡 (freeze 없음, 30분 연속)
3. MoonBlaster Wave 곡 1곡, 커스텀 PCM 업로드 포함 (업로드 시간 측정: 현행 대비)
4. FM+PCM 동시 곡 1곡, 레벨/팬 비교 녹음 (openMSX 녹음과 상관)
5. warm reset 직후 재생

## 7. 위험과 대응

| 위험 | 대응 |
|---|---|
| 면적 목표 미달 | P3 중간에 map-only로 슬롯 데이터패스만 측정, 1,200 ALM을 넘으면 직렬화 단계 추가 |
| 128 MHz 미수렴 | 데이터패스 1단 = 연산 1개 규칙, 조합 체인 깊이를 리뷰 체크리스트로 |
| BUSY 의미 변경으로 소프트웨어 회귀 | openMSX 트레이스 재생으로 BUSY 폴링 소프트웨어 확인 |
| 메모리 쓰기 대기 축소 시 손실/손상 재발 (f04eea9, 2026-06-12; 2026-10-24 R800 측정) | ack를 ch4 쓰기 완료에 묶는다. `ms_wdelay/mprobe_r`(R800 OTIR 1024바이트 + 읽어 비교)를 G-memwr 게이트로 편입, 지연 0 변형이 FAIL해야 함 |
