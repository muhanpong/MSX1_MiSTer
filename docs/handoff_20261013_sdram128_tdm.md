# 인수인계 2026-10-13: PCM 128.86 MHz 통과, SDRAM TDM 컨트롤러, fullsys 부팅 불일치

브랜치 `sdram128-study`, worktree `/home/sysop/data/MiSTer_build/sdram128`. push 안 함.
이 브랜치의 비트스트림은 타이밍 연구용이다. **보드에 올리지 말 것.**
이전 인수인계: `docs/handoff_20261012_sdram128.md`(V9968 검토, 128.86 MHz 선택 이유).
설계 문서: `docs/sdram_tdm_design.md`(1-11절, 숫자는 여기에 다 있다).

## 0. 먼저 할 일: TDM 코어가 fullsys에서 부팅하지 않는다

타이밍은 통과했지만(33bdddd, +0.286 ns, 실패 0) **기능은 검증되지 않았다**.
같은 팩(FS-A1GT DOS2), 같은 700 ms로 기존 컨트롤러(run.sh, 85.909 MHz)와 TDM
(run_tdm.sh, 128.86 MHz, clk21m = clk_sdram/6)을 돌린 결과:

| | 기존 sdram.sv | sdram_tdm |
|---|---|---|
| 업로드 끝 | 135 ms | 91 ms |
| 700 ms까지 분기 | 46,026, 고유 PC 246 | 364,415, 고유 PC 60 |
| 끝 상태 | BIOS 진행(7b7f/7d60) | 7304/7987/feda/ffb1/ffbb를 맴돔 |
| CPU 읽기 지연 | 최소 34.9, 최대 174.6 ns | 최소 31.0, 최대 287.1 ns |

`sim/fullsys/cmp_streams.sh`: 해제 후 **5번째 분기**에서 갈린다.
기준 `126b 127a 1290 1292 0416`, TDM `126b 127a 1290 0416 7b61`.
1290 다음의 조건 분기가 다르게 갔다 = 부팅 직후 첫 메모리 읽기 값이 다르다.
로그: `docs/evidence_20261013/*.log.gz`.

원인 후보(아직 하나도 확인 안 함):
1. **fullsys 칩 모델 `sdram_big_tdm`**(tb_msx.sv 끝): 이번에 새로 썼다. 인덱스
   `{BA, row, A[8:0]}`(32 MB 맵), 쓰기 버스트 두 번째 워드, DQM 지연, 워드를 칩 에지
   다음 상승 에지에 내는 타이밍. TDM 단독 벤치(sim/sdram_tdm)의 sdram_chk.sv와 같은
   의미여야 한다.
2. **표준 속도 CPU의 고정 마감**: 부팅 초반은 Z80 3.58 MHz라 `cpu_paced=0`, 버스 가드가
   꺼져 CPU가 고정 시점에 데이터를 가져간다(msx.sv 600-700행). TDM 최대 287 ns가 그 마감을
   넘을 수 있다. 기존 컨트롤러의 마감은 sdram.sv 주석상 "약 24 클록 @85.9 = 279 ns".
3. **6:1 클록 자체**: clk21m과 clk_sdram의 위상, ch2 요청 에지 검출(2단 동기 없이
   ch2_req 상승 에지).

가르는 방법:
- 후보 3: 기존 sdram.sv를 6:1(128.86 MHz)로 돌린다. tb_msx.sv의 `ifdef TDM` 블록에서 클록만
  바꾸고 컨트롤러는 sdram.sv로 두는 변형(`-DTDMCLK` 같은 정의)을 만들면 된다.
  sdram.sv는 CL2라 실제 칩에서는 128.86 MHz가 안 되지만 sdram_big(CL2 모델)과는 맞는다.
- 후보 1/2: 첫 갈림 직전의 CPU 읽기를 찍는다(주소, sdram_dout, 그 읽기의 완료 시각 vs CPU가
  데이터를 래치한 시각). tb_msx.sv에 `rd_win`, `hs_done`, `sdram_hit` 관측이 이미 있다.
- 판정은 `sim/fullsys/cmp_streams.sh <old.log> <tdm.log>`가 RESULT PASS일 때만 통과.
  대조군: 같은 로그끼리 PASS, 지금의 TDM 로그는 FAIL(검증함).

한 판에 벽시계 40분-1.5시간(업로드가 대부분). run.sh가 도는 중에 run.sh를 고치지 말 것.

## 1. 이번 세션에서 한 일 (커밋 순)

| 커밋 | 내용 |
|---|---|
| 0f5cd07 | check_timing.sh 음성 대조군(보고서 사본 변조) |
| 99aac4e, 4cd2115, efddce8 | PCM 엔진 나머지 경로: EGPRE2, CHIT0, TL 스냅샷 입력, 순회 w-1, inv_tag 한 번 읽기, 비브라토 표, 출력 2클록, 순회 지우기 지연. **128.86 MHz +0.180 ns** |
| f780df5 | MLAB을 이름 목록(31개)으로 검사, Quartus 바쁨 검사(pgrep -x), compile.sh FROM=fit |
| 541b801 | V9968 라이선스: 지금 VDP(ESE 계열)와 같은 3번 조항. 새 장애물이 아님 |
| fd06f4d | SDC: v2 PCM 멀티사이클 9쌍 삭제, OSD 트림 -> MoonSound false path |
| ce3410d | TDM 프레임 solver(DQM == A[12:11]이면 V + 일반 2 = 0개) |
| 272f912, 738b145 | sdram_tdm + sdram_chk 모델 + tb_tdm 벤치, v_en, 리프레시 연기, CPU 뱅크 예약 |
| 7de0ebe | 코어 연결(MSX1.sv), SDC 예외를 sdram_tdm:sdram으로, 무시된 SDC는 게이트 FAIL |
| 91a87c3 | fullsys run_tdm.sh, 수요/CPU 지연 계측 |
| d2efe8d, a253d77, 33bdddd | 파이프라인(원-핫, 후보 선계산, 캐시 비교 단, 출력 레지스터 단), 읽기 캡처를 핀 STA대로 하강 에지로 |
| 15453b0 | CPU 지연 계측 단위 수정(ns를 1000으로 나눴었다) |
| 4ef5472 | 설계 문서 8-11절 |

## 2. 하네스

| 명령 | 판정 |
|---|---|
| `rtl/peripheral/SOUND/ymf278b_fpga/sim/run_pcm128_verify.sh [quick]` | PCM: 골든 두 클록 바이트 일치, PIPE=0 스트레스, SNAPCHK, PIPECHK 6종 + 변형 6종 |
| `sim/sdram_tdm/run.sh [quick]` | TDM 단독: 32/128 MB x 시드 x 부하, 칩 타이밍 검사, 음성 대조군 SENS/BANK/NOREF/CAP/CAPE |
| `tools/sdram128/compile.sh` (`FROM=fit`) | 합성 -> 합성 검사(PIPE 10, MLAB 31 이름, 10999 없음, PLL) -> fit -> STA -> 전체 검사(무시된 SDC 0 포함) |
| `quartus_sta -t tools/sdram128/io_sta.tcl <out>` | SDRAM 핀(분석 전용, `sdram_io.sdc`) |
| `tools/sdram128/tdm_solve.py` | 프레임 배치 탐색 |
| `sim/fullsys/run_tdm.sh <pack> <ms>` | fullsys TDM. `run.sh`는 기존 컨트롤러 |
| `sim/fullsys/cmp_streams.sh <old> <tdm>` | 두 fullsys 런의 분기 스트림 일치 |

## 3. 숫자 (상세: docs/sdram_tdm_design.md)

- 코어 타이밍 33bdddd: clk_sdram +0.286 ns, 끝점 0.
- 핀 STA(보드 0.3-0.7 ns 가정): 출력 setup +0.079 / hold +2.512, 입력 setup +2.777 / hold +6.852.
  입력 hold는 손 계산(약 1.3 ns)과 다르다: 멀티사이클 hold 기준 에지를 확인할 것.
- SDRAM 수요(기존, R800 부팅): 0.12-0.15 M/s, 가장 바쁜 100 us 1.0 M/s, CPU 읽기 캐시 적중 81-85%.
  일반 슬롯 하나(10.74 M/s)로 충분 -> 32 MB 모드도 대역은 된다.

## 4. 남은 일 (순서 제안)

1. **0절의 부팅 불일치** (최우선. 이게 풀리기 전의 TDM 숫자는 의미가 없다).
2. CPU 지연: 표준 속도의 실제 소비 마감을 재고, TDM 최대(287 ns)와 비교.
3. 32 MB 수용 테스트: VRAM 256 KB(24 MB 이상 뱅크 3) + 슬롯 2 카트 + MoonSound + 큰 팩.
   memory_upload에 VRAM 영역 상한이 없다(v_en=0이라 지금은 예약도 없음). 상한 검사를 넣고
   최대 구성 팩을 fullsys에 올려 lookup_RAM 배치를 확인. **아직 아무것도 안 했다.**
4. 핀 타이밍: 출력 setup +0.079가 빠듯. SDRAM_CLK를 PLL 출력(위상 조절)으로 바꾸는 안.
   sdram_io.sdc를 프로젝트 SDC에 넣을지 결정.
5. tRAS lockout: 모든 READ가 의존(ras_lockout = READ 수). AS4C32M16SB 데이터시트 확인.
6. V9968 연결: VRAM 포트, 리프레시 슬롯(칩이 VRAM과 같을 때 V 슬롯 2개를 비움), v_en=1.
7. 이 브랜치를 rebase된 nextz80 위로: `git rebase --onto nextz80 7b4cf67 sdram128-study`
   (옛 해시 7b4cf67 기준. nextz80은 rebase로 해시가 바뀌었다).

## 5. main 쪽 (nextz80)

- 로컬 nextz80은 origin/nextz80 위로 rebase 완료(ahead 28, behind 0, 2026-10-12).
- precheck(rebase된 트리): `EXIT 0`, 13 레코드 모두 PASS(slotsram, midi, toplevel,
  unconnected는 새로 돌림, 나머지는 같은 파일 해시 스탬프). 로그는 세션 스크래치패드에 있었다.
- **push는 사용자 답 대기**: `git push origin nextz80`(fast-forward). 그다음 stash
  `rsrv-fullsys-stubs-20261006` 삭제, README 커밋 3개(백업 브랜치 nextz80-local-20261006의
  1a91422, 74ea56c, 7a30f26)를 origin README(14f139d)와 손으로 합치기.
- main 체크아웃의 미추적 파일: `docs/handoff_20261006_status.md`, `docs/NEXT_PROMPT_20261006.md`.

## 6. 규칙 (이번에 다시 확인된 것)

- 사용자에게는 한국어로 보고(상태 한 줄까지).
- Quartus는 한 번에 하나. 컴파일 뒤 `git checkout -- MSX1.qsf`(STA만 돌려도 바뀐다).
- 빌드/push는 사용자 말이 있을 때만. 이 브랜치 비트스트림은 보드 금지.
- **모델은 측정을 따라야 한다**: 읽기 캡처를 두 번 틀렸고, 모델이 실제보다 데이터를 일찍
  내서 둘 다 통과했다. 핀 STA가 잡았다. 시뮬이 통과해도 STA/하드웨어 숫자와 맞는지 볼 것.
- **계측은 스스로를 증명해야 한다**: CPU 지연 첫 측정이 max 0.2 ns(단위 오류)였는데 바로
  알아채지 못했다. 최소/최대가 물리적으로 가능한 값인지 확인.
- **타이밍 통과는 기능 통과가 아니다**: 0절.
- Verilator `--timing`의 함정: 절차 코드의 초기화 선언, 지연을 가진 프로세스, fork 안 task의
  대입이 모두 오래된 값을 냈다(sdram_chk.sv 주석). 모델은 지연 없이 짠다.
