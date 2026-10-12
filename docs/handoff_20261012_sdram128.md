# 인수인계 2026-10-12: V9968 검토, SDRAM 128.86 MHz 연구, PCM 엔진 재구성

브랜치 `sdram128-study`, worktree `/home/sysop/data/MiSTer_build/sdram128`.
로컬 nextz80 `7b4cf67`에서 분기했고 **push하지 않았다**. 이 브랜치의 비트스트림은 PLL을
바꾼 **타이밍 연구용**이라 보드에 올리면 안 된다.

## 1. 출발점: V9958을 V9968로 대체할 수 있는가

`/home/sysop/data/V9968_Cartridge`(HRA! 원본)와 `/home/sysop/data/V9968_Cartridge_alexmoncks`
(geo3d를 더한 포크)를 검토했다. 결론은 **그대로 끼워 넣는 교체는 안 되고, 원래 스펙을
받으려면 SDRAM 컨트롤러를 다시 짜야 한다**는 것이다.

- **라이선스:** 저장소 최상위는 MIT지만 `src/v9968/*.v` 21개 중 20개의 헤더(Takayuki Hara,
  일본어판이 정본)에 ESE 계열 3조항이 있다: 소스 재배포 시 표시 유지, 바이너리 재배포 시 문서에
  표시 포함, **서면 허가 없이 판매·상업적 제품/활동에 사용 금지**. 지금 코어의 V9958
  (`rtl/video/VDP/*.vhd`, ESE VDP 계열) 20개 중 17개에 **같은 3번 조항이 이미 있다**. 그러니
  V9968은 새 종류의 문제가 아니라 지금 VDP와 같은 위치다(GPLv2와의 엄밀한 긴장은 이미 코어에
  있음). 무료 배포면 3번은 지켜지고, RBF 릴리스 문서에 HRA! 표시를 넣는 2번은 챙겨야 한다.
  (2026-10-12 처음에는 "허가가 선결 조건"이라 썼는데, 기존 VDP를 확인하지 않은 과장이었다.)
- **VRAM:** 256 KB(`vram_address[17:2]`), 32비트 폭, 바이트 마스크, 리프레시 출력. 카트리지에서는
  GW2AR-18 내장 SDRAM(32비트)에 연결된다. BRAM으로는 안 된다(지금 VRAM 128 KB가 M10K 128개,
  9/26 기준 451/553 사용).
- **요구 대역:** `vdp_vram_interface.v`에서 `h_count[3:0]` 16클록 주기에 슬롯 둘(1, 9), 즉
  85.909 MHz에서 **8클록마다 32비트 1회**. 화면과 스프라이트 읽기는 `ready`가 없는 하드 실시간.
- **영상:** 31 kHz 라인 더블 출력만 있다(2736클록/라인, 524라인). 15 kHz CRT 출력은 잃는다.
- **클록:** V9968은 85.909 MHz로 MiSTer `clk_sdram`과 같다.

### MSX1 코어 SDRAM의 사실
- `rtl/peripheral/sdram.sv`: 16비트, 85.909 MHz, CL2, 버스트 1, 접근마다 ACTIVE와 자동
  프리차지. 읽기 약 6클록, 쓰기 약 5클록(상태 머신을 읽고 추정).
- 채널: ch1 업로드/덤프/.sav, ch2 CPU(핸드셰이크 없음, 약 24클록 마감, 캐시 8192줄),
  ch3 플래시, ch4 OPL4 PCM.
- 맵은 `memory_upload.sv`가 0번지부터 채우는 동적 배치. 뱅크 = `addr[24:23]`(뱅크마다 연속
  8 MB), 칩 = `addr[26]`. FS-A1ST 3-3 팩은 약 2.6 MB, MoonSound 4 MB가 그 뒤에 붙는다.
  큰 플래시 카트 둘까지 붙여도 약 23 MB라 **뱅크 3(0x1800000-)은 사실상 비어 있다**(추정).
- 지금 컨트롤러로는 V9968 32비트 1회에 약 12클록이 필요해 8클록 슬롯의 150%다. 불가능.

### 선택한 방향: SDRAM 클록 3/2배(128.863620 MHz) + 고정 슬롯(TDM)
- 128.86 MHz에서 V9968 슬롯 하나가 12클록. VRAM(뱅크 3 전용): ACT@0, READ@3, 데이터@6-7
  (CL3, 버스트 2). 다른 채널 둘이 다른 뱅크에서 겹쳐 들어간다(ACT@2/READ@5/데이터@8,
  ACT@6/READ@9/데이터@다음 0). 다른 채널 몫은 약 21.5 M회/s로, 지금 SDRAM 전체(약 14 M회/s)보다
  크다. 칩 정격(143-166 MHz) 안이고 CL3이 필요하다.
- 2배(171.8 MHz)는 칩 정격을 넘는다. 85.9 MHz TDM도 계산상 가능하지만 다른 채널 몫이 작다.
- 이 계산들은 데이터시트 대표값 기반이고 시뮬레이션하지 않았다.

## 2. 128.86 MHz 연구 빌드

| 커밋 | 빌드 | clk_sdram setup | 비고 |
|---|---|---|---|
| 26d85bb | PLL만 변경 | -2.739 ns, TNS -601 | PCM 약 700끝점(-2.74), SDRAM 컨트롤러 76(-1.43) |
| d4f74ac | 첫 묶음 | -2.366 ns, TNS -365 | **무효**: msx.sv가 CLK_HZ 85909090을 넘겨 PIPE가 꺼진 채 합성됨 |
| c126c6c | 두 묶음 + CLK_HZ 수정 | (3절 참조) | PIPE 상태 8개 합성 확인 |

- SDRAM 컨트롤러의 실패는 중재(`ch2_rq`->`SDRAM_A`)와 ch2 캐시 경로에 몰려 있다. TDM으로
  재작성하면 바뀌는 로직이다.
- SDRAM 핀 IO 제약은 SDC에 없다. 128.86 MHz에서의 핀 타이밍은 분석되지 않았다.
- `MSX1.sdc`의 PCM 멀티사이클은 v2 엔진 이름(`stage_a_reg`, `next_pos_r`)을 가리킨다.

## 3. 컴파일 c126c6c 결과

`tools/sdram128/check_timing.sh`: clk_sdram 7.760 ns, PIPE 상태 8/8, PCM MLAB 33 확인 후 측정.

| | 26d85bb (PLL만) | c126c6c (두 묶음) |
|---|---|---|
| clk_sdram 최악 slack | -2.739 ns | -1.882 ns |
| TNS | -601 ns | -44.2 ns |
| 실패 끝점 | 782 | 137 |

남은 실패 (최악순):
| 끝점 | 수 | 최악 | 비고 |
|---|---|---|---|
| pcm `eg_att_r` <- `w_dyn.env_vol` | 10 | -1.88 | EGPRE 안의 `calc_attack_step` 자체가 한 클록에 안 들어감. 함수 분할 필요 |
| sdram `c_wdata` <- `refresh_count` | 7 | -0.88 | 캐시 플러시와 리프레시 (TDM 재작성 대상) |
| pcm `w_sb`/`w_sa` <- `w_b0` | 9 | -0.40 | DECODE의 바이트 선택 |
| moonsound `pc_l/r_mul` <- `status` (clk21m -> clk_sdram) | 18 | -0.33 | 도메인 경계 |
| sdram ch2 캐시 (`ch2_saved_data`, `ch2_hit_r`) | 18 | -0.33 | TDM 재작성 대상 |
| pcm `sn_tl_next` <- `cur_slot` | 9 | -0.30 | 스냅샷 단계의 TL 계산 |
| pcm `w_word` <- `w_a0`, `rdaddr_reg`, `SL_DECODE` | 45 | -0.25 | 캐시 워드 선택 |
| pcm `cache_vld` <- `inv_idx` | 16 | -0.18 | 무효화 순회 |
| sdram `SDRAM_A`/`command` <- ... | 4 | -0.12 | 중재 |

PCM에서 크게 남은 것은 `calc_attack_step` 하나이고, 나머지는 -0.4 ns 이내다.

## 4. PCM 엔진 재구성 (`docs/pcm_engine_128mhz_plan.md`)

PCM 엔진을 SDRAM 컨트롤러와 같은 128.86 MHz로 옮긴다. 불변 조건은 출력 샘플이 85.909 MHz
버전과 비트 단위로 같은 것.

- **1단계 e324b22:** 프레임 1948 / CPU 예약 44 / 헤더 가드 130을 `CLK_HZ`에서 계산(128.86 MHz에서
  2922 / 66 / 195). `rd_snum_q` 선언 위치 수정(50e246d 이후 lockstep이 iverilog에서 빌드되지
  않던 문제).
- **2단계 첫 묶음 d4f74ac:** `PIPE`(CLK_HZ > 100 MHz 또는 `PIPE_FORCE`)일 때 슬롯 데이터 경로에
  상태 8개 추가: ADV0, INTERP2/3, EGPRE, GAIN2, MUL1B, MUL2B, PANB. 슬롯당 +8클록.
- **2단계 두 번째 묶음 c126c6c:** PIPE일 때 디스패치를 스냅샷(`sn_*`)에서 한다. 직전 클록과
  슬롯이 같고 변경 출처(필드 MLAB 쓰기, 슬롯 레지스터 쓰기, 헤더 저장, SL_ACC, 리셋, 프레임
  경계)가 없었을 때만 유효. TL 램프 다음 값을 하나의 식(`tl_we_c`/`tl_next_c`)으로 정리.
  `msx.sv`의 MoonSound `CLK_HZ`를 128863620으로.

### 검증 결과
| 항목 | 결과 |
|---|---|
| 골든 85.909 MHz | 모든 시나리오가 모델과 일치 |
| 골든 128.86 MHz (프레임 2922 출력 확인) | 8개 시나리오 8,200프레임이 85.909 MHz와 바이트 단위로 같음 |
| PIPE=0 매 클록 lockstep 스트레스 | 64회 불일치 0, 변형 4종 32/32 |
| SNAPCHK (PIPE=1, 스트레스, 리셋 반복) | 64회, 디스패치 1,194,779회, 위반 0. `SN_MUT_NOCHG` 64/64 검출 |
| PIPE 강제, 85.909 MHz, 샘플 비교, 스트레스 없음 | 30/32 깨끗. sc_songchange24 2회는 슬롯 예산 초과 |

### 검증 방식에 대해 알게 된 것 (다음 사람이 같은 함정에 빠지지 않도록)
- 매 클록 lockstep은 상태를 하나만 추가해도 구조상 전부 불일치한다.
- `+samples`(엔진별 메모리, 샘플만 비교)는 타이밍이 그대로인 변경에서만 유효하다. 스트레스
  자극은 새 엔진의 내부 시점에 쓰기를 넣으므로, 타이밍이 바뀐 엔진과 기준 엔진에서는 같은
  쓰기가 다른 처리 시점에 떨어져 출력이 각자 정당하게 달라진다.
- 그래서 판정을 나눴다: 충돌 의미는 PIPE=0 매 클록 스트레스로 회로 동일성, 분할 정확성은
  128.86 MHz 골든 비트 일치, 스냅샷 의미는 SNAPCHK 단언.
- 85.909 MHz 프레임에 PIPE를 강제로 넣으면 24음에서 슬롯 예산을 넘는다. 기준 엔진도
  85.909 MHz, 24음, 지연 20에서 4프레임이 잘린다(`BUDGET` 줄).
- 첫 SNAPCHK 변형(헤더 저장만 제외)은 잡히지 않았다. 같은 클록의 필드 백필 쓰기가 덮는
  중복 경로였다. 음성 대조군은 효과가 있는 변형인지 먼저 확인해야 한다.

## 5. 하네스

| 명령 | 무엇을 판정하는가 |
|---|---|
| `rtl/peripheral/SOUND/ymf278b_fpga/sim/run_pcm128_verify.sh [quick]` | 4절의 검증 전체. 빈 결과, 빌드 실패, 음성 대조군 미검출을 실패로 처리하고 `RESULT` 한 줄과 종료 코드로 알린다 |
| `tools/sdram128/check_timing.sh` | 컴파일 결과가 주장하는 빌드인지(clk_sdram 7.760 ns, PIPE 상태 8개, PCM MLAB 33개) 확인한 뒤 실패 끝점을 모듈별로 집계. 음성 대조군(c126c6c 보고서 사본을 변조): 원본 PASS, PIPE 상태 0/8·7/8, 주기 11.641 ns, MLAB 0개 모두 FAIL. 실제 PIPE 꺼진 컴파일로는 아직 시험하지 않음 |
| `sim/lockstep/run_stress.sh` (`SAMPLES=1`) | 기존 스트레스. `SAMPLES=1`이면 샘플 비교, 비교 0회는 실패 |
| `tb_golden_pcm.sv` `CLK_HZ` 파라미터, `run_pcm_golden_vl.sh` `CLK_HZ`/`TAG` | 클록을 바꾼 골든 |
| `tb_lockstep_pcm.sv` `+samples`, `DUT_PIPE`, `SNAPCHK`, `BUDGET` | 위 판정들의 부품 |

벤치를 돌릴 때는 `PATH=/home/linuxbrew/.linuxbrew/bin:$PATH`(시스템 verilator는 4.038).

## 6. 남은 일 (순서 제안)
1. 3절의 남은 PCM 경로: `calc_attack_step`(-1.88)을 두 상태로, DECODE 바이트 선택(-0.40),
   `sn_tl_next`(-0.30), 캐시 워드 선택(-0.25), `cache_vld` 순회(-0.18).
2. SDRAM TDM 컨트롤러 시제품: 12클록 프레임, VRAM 뱅크 3, 버스트 2, PCM ch4는 워드 쌍 읽기
   (`wA0,wA0+1` / `wB0,wB0+1`), ch2 마감 보장. 단독으로 128.86 MHz 타이밍을 본다.
3. 클록 도메인 경계: clk21m(21.477) : 128.86 = 1 : 6. CPU 레지스터 쓰기 경로의 멀티사이클 재정의
   또는 핸드셰이크. PCM 출력 -> 오디오 믹서 도메인 확인.
4. SDC: v2 이름의 PCM 멀티사이클 정리, SDRAM 핀 IO 제약 추가.
5. V9968: 릴리스 문서의 HRA! 표시(조항 2), 원하면 HRA!에게 의사 확인, VRAM 읽기 마감(`vram_rdata_en`까지 허용 클록) 확인.

## 7. 규칙
- Quartus 작업은 동시에 하나만. 컴파일하면 `MSX1.qsf`의 버전 문자열이 바뀌니 커밋 전에
  `git checkout -- MSX1.qsf`.
- 이 호스트의 Quartus는 `/home/sysop/data/intelFPGA_lite/17.0`. `tools/buildgate/build.sh`는
  17.1 볼륨을 찾다 실패한다.
- 백그라운드 실행은 `(cd <절대경로> && ...)`처럼 같은 서브셸에서. `cd X && (A) & for ...`는
  `cd`가 반복문에 적용되지 않아 엉뚱한 트리를 빌드한 적이 있다.
- 숫자는 음성 대조군과 함께 보고한다.
