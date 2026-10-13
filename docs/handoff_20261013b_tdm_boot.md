# 인수인계 2026-10-13 (오후): TDM 부팅 불일치 원인 두 개, 32 MB 수용

브랜치 `sdram128-study`, worktree `/home/sysop/data/MiSTer_build/sdram128`. push 안 함.
이 브랜치의 비트스트림은 타이밍 연구용이다. **보드에 올리지 말 것.**
앞 인수인계: `docs/handoff_20261013_sdram128_tdm.md`(0절의 질문에 대한 답이 이 문서).
설계 문서: `docs/sdram_tdm_design.md` 12-14절.

## 0. 결론

`docs/handoff_20261013_sdram128_tdm.md` 0절의 부팅 불일치는 원인이 **두 개**였고, 둘 다
TDM 컨트롤러 쪽이다. 칩 모델(`sdram_big_tdm`)과 6:1 클록은 원인이 아니다.

| | 원인 | 증상 | 수정 |
|---|---|---|---|
| 1 | ch1/ch3/ch4 ready를 **G 슬롯이 고를 때** 내림(요청 뒤 최대 ~14클록) | `memory_upload`가 이전 ready를 보고 다음 바이트를 내서, 대기 중인 바이트를 덮어씀. BIOS 04E6h가 00 -> 1290h OTIR가 S1990 레지스터 6에 엉뚱한 값 -> 5번째 분기에서 갈림 | ready를 **요청 에지에서** 내림 (b1b80f9) |
| 2 | 표준 속도 CPU 마감(요청 에지 E0+28) 안에 리프레시 프레임이 끼면 G 결정 3번을 지나침(33-34클록) | 33,332번째 분기에서 갈림: Z80 모드에서 JP 대상 F392가 F300으로(LATE 10회) | CPU 읽기가 대기 중이면 REFRESH 발행 전까지 리프레시 프레임을 취소 (3f26ad6) |

2를 고치면서 숨어 있던 버그 두 개가 같이 나왔다(3f26ad6): `rf_late`를 프레임 시작에서
지워 취소가 한도 없이 반복될 수 있었다(리프레시 간격 7.822 us, sdram_chk가 잡음), 32 MB에서
칩 1의 `rf_due[1]`이 영영 처리되지 않아 경계마다 "연기"하며 `rf_late`가 3에 붙어 있었다.

## 1. 숫자 (모두 음성 대조군과 함께)

### fullsys FS-A1GT DOS2 (기준 = run.sh 700 ms 로그, docs/evidence_20261013)

| 런 | BIOS 32 kB 업로드 비교 | ch1 덮어쓰기 | LATE | 분기 스트림 |
|---|---|---|---|---|
| run.sh (sdram.sv, 140 ms) | 0 바이트 차이 | - | 0 | (기준) |
| TDM, ready 수정 전 = `-DTDM_MUT_RDY` | **398 바이트** (첫 0x0000009) | 12,419 | 0 | 5번째에서 FAIL (원래 증상 그대로) |
| TDM, ready 수정 (b1b80f9) | 0 | 0 | **10** | 33,331까지 일치, 33,332에서 FAIL |
| 위 + 느린 ch2 진단 (같은 컨트롤러) | 0 | 0 | 10 | 느린 읽기 904건 전부 리프레시: `[R]` 25클록 878건(마감 안), `[RRR]` 37클록 26건(그중 Z80 일반 읽기 10건 LATE; 673.615 ms `f080 -> 00`이 F300 점프) |
| **TDM, 리프레시 취소 (3f26ad6)** | 0 | 0 | **0** | **46,026 분기 전부 PASS** (고유 PC 246, CPU 읽기 474,208회 동일) |
| CLKONLY=1 (sdram.sv를 6:1 클록으로) | | | 0 | 9,828 분기 PASS -> 클록은 원인 아님 |

3f26ad6: CPU 읽기 지연 최대 287.1 -> 163.0 ns(기준 sdram.sv 174.6), 최소 31.0 ns(캐시 적중 4클록),
T80s 일반 읽기 여유 최소 108.6 ns, 느린 ch2 읽기(>24클록) 0건. 로그: `docs/evidence_20261013/`
`fs_tdm_fixed_3f26ad6_*`, `fs_tdm_readyfix_diag_*`, `fs_tdm_mut_rdy_*`, `fs_clkonly_*`, `fs_*FS-A1WX*`.

### fullsys FS-A1WX (MSX2+, 3.58 MHz 전용, 600 ms, ready 수정 후)

- 31,544 분기 **PASS**, LATE 0.
- T80s SDRAM 일반 읽기: 창 232.8 ns. 기준 지연 최대 139.7 ns / 여유 최소 93.1 ns,
  TDM 155.2 ns / 77.6 ns. 마감은 창 시작 W+30 clk_sdram = 요청 에지 E0+29(완료는 E0+28까지).

### sim/sdram_tdm (+stock: CPU처럼 E0+28에 바이트를 가져감)

- 수정 전 컨트롤러, 32 MB 맵: 읽기 ~800회에 LATE 8/16. 128 MB 맵(뱅크 교차) 0.
- 격자 위상 0-35 전부(CPU 0.25-1.25 MB, ch1이 같은 뱅크 0):
  수정본 **0/36 위상**, 완료 최대 E0+25. `-DTDM_MUT_RFSLOW`(취소 없음) **9/36 위상**, 132건, 전부 `RR`.
- `run.sh quick` PASS: 엔진 + 표준 속도 8작업 LATE 0, 음성 대조군 msens mbank mnoref mcap
  mcape mrdy mrfslow 모두 검출. 벤치가 놓친 이유: 채널 에이전트가 ready가 "떨어졌다 다시 오를
  때까지" 기다리는 완벽한 핸드셰이크였고(실제 소비자는 1 clk21m 펄스 + 2 clk21m 뒤 ready
  폴링), ch2 에이전트는 완료를 기다려 줬다(실제 Z80은 기다리지 않는다).

## 2. 32 MB 수용 테스트 (`sim/run_upload32.sh`, memory_upload 단독)

풀 크기 업로드(25 MB)를 fullsys로 돌리면 수십 시간이라(443 kB = 기계 91 ms = 벽시계 40분),
memory_upload만 진짜 팩 / 진짜 yrw801.rom / 8 MB 합성 카트로 돌리고 SDRAM 쓰기를 전부 센다.

| 구성 | 쓰기 바이트 | 최고 주소 | 24 MB 이상(VRAM 뱅크) |
|---|---|---|---|
| C1 FS-A1GT 4MB DOS2 + MoonSound + 슬롯 A/B 8 MB ASCII16X | 25,608,192 | 0x186BFFF (24.42 MB) | **442,368 B** |
| C2 같은 것, 슬롯 A만 | 17,219,584 | 16.42 MB | 0 |
| C3 FS-A1GT DOS2 + MoonSound, 카트 없음 | 5,160,960 | 4.92 MB | 0 |
| N1 대조군: C3에 상한 1 MB | | | 4,112,384 (검출) |
| C1의 기계를 FS-A1GT **2MB** DOS2로 | 23,511,040 | 0x166BFFF (22.42 MB) | 0 (여유 1.58 MB) |
| C1의 기계를 FS-A1GT **1MB** DOS2로 | 22,462,464 | 0x156BFFF (21.42 MB) | 0 (여유 2.58 MB) |

(쓰기 바이트 검산: C1에서 RAM 3 MB / 2 MB를 뺀 값과 정확히 같다.) 32 MB 보드에서 머신 RAM을
2 MB 이하로 묶으면 MoonSound + 8 MB 카트 둘이 들어간다. RAM 위치는 0x1010000(뱅크 2)이라
1 MB는 전부 행 비트 00, 2 MB는 마지막 64 kB(0x1200000-)만 행 비트 01이다. 단 카트는 여전히
슬롯 A 10 MB, 슬롯 B 16 MB까지 받으므로 RAM 상한만으로는 보장이 아니다: 업로드 상한 검사가 같이 필요하다.

C1 검산: 8+8 MB 카트 + 4 MB RAM + 432 kB(BIOS 등) + 2 MB ROM + 2 MB 웨이브 RAM = 25,608,192.
배치 순서: BIOS -> 슬롯 A ROM(0x10000) -> 슬롯 B ROM -> RAM 4 MB(0x1010000) -> 기타 ->
MoonSound(pcm_rom_base 0x146C000, 웨이브 RAM 끝 0x186C000).

의미:
- 32 MB 보드 + V9968(v_en=1) + 최대 구성이면 MoonSound 커스텀 웨이브 RAM의 마지막 432 kB가
  VRAM 뱅크에 들어간다. 게다가 `sdram_tdm`의 `ok()`는 v_en=1이면 뱅크 3을 G 슬롯에서
  **영원히 거절**하므로, 업로드 쓰기(ch1)가 그 주소에서 멈춘다(업로드가 끝나지 않음).
- 카트 둘 중 하나가 없거나 8 MB 미만이면 들어간다(C2 16.42 MB).
- 극단: 슬롯 A 저장소 10 MB, 슬롯 B 16 MB까지 받으므로 32 MB 보드는 VRAM이 없어도 넘칠 수 있다.
- MoonSound가 없으면 `pcm_rom_base` 기본값이 0x1800000(=24 MB, VRAM 뱅크 시작)이고 PCM
  카나리아(`msx.sv` CAN_ADDR, base+0x200000)가 그 근처를 읽는다. v_en=1이면 ch4 요청이 영원히
  거절된다(다른 채널은 영향 없음, PCM 브리지만 멈춤).

결정이 필요한 것(사용자): 32 MB 보드에서 V9968을 쓸 때 (a) memory_upload에 24 MB 상한을 넣고
넘는 구성을 거절/경고, (b) 64 MB 보드는 64 MB 모드(VRAM을 48 MB 이상으로), (c) VRAM 뱅크를
다른 방식으로 확보. 지금은 아무것도 바꾸지 않았다.

## 3. 데이터시트 (AS4C32M16SB Rev 1.0, -7)

tRC 63, **tRFC 63**, tRCD 21, tRP 21, tRRD 14, tMRD 14, tRAS 42 ns(최대 120 us), tWR 14,
tAC(CL3) 5.4, tOH 2.5, tIS 1.5, tIH 0.8 ns, tREFI 7.8 us. 설계 문서 숫자와 같다
(sdram_chk의 T_RFC 70 ns는 보수적인 값).

**tRAS lockout은 데이터시트에 없다.** "Read with AutoPrecharge 뒤 {tRP + BL} 동안 다른 명령
불가"뿐이다. 지금 프레임은 ACT a, READ a+3, BL2라 내부 프리차지가 a+5에 시작할 수 있고 tRAS
(42 ns = 6클록 -> a+6)를 1클록 못 채운다. tRC(ACT 간 9클록)는 지킨다. 미해결: 제조사 확인이
안 되면 READ를 a+4로(프레임 재탐색 필요) 옮기는 안.

## 4. 남은 일

0. (해결, 2026-10-13 밤) OPL3 클록이 `clk_sdram / 6` 고정이라 128.86 MHz에서 21.48 MHz로 돌았다
   (FM 1.5배). `msx.sv`의 `SDRAM_HZ` 하나에서 PCM CLK_HZ와 OPL3_DIV(=9)를 만든다. 측정: 기준 14.3184,
   수정 전 21.4777, 수정 후 14.3184 MHz. 이 브랜치는 128.86 MHz 단일 구조로 간다(사용자 결정,
   85.909 MHz와의 이중 리비전은 하지 않음).

1. **Quartus 컴파일 안 함**(사용자 지시 없음): b1b80f9, 3f26ad6의 타이밍 영향 미확인.
   `tools/sdram128/compile.sh`, 뒤에 `git checkout -- MSX1.qsf`.
2. 32 MB 수용 결정(2절).
3. 표준 속도 마감의 남은 위험: `B`(직전 G 슬롯을 다른 채널이 같은 뱅크로 씀)와 DQM 민감
   슬롯(행 비트 != 00). 실제 CPU 주소(0-2 MB)에서는 벤치 위상 36개 모두 0이지만, 최대 구성은
   RAM이 16-20 MB(행 비트 != 00)라 v_en=1에서는 G1이 늘 막힌다(V 읽기 뒤 민감). 해결안:
   큐 진입 앞당기기(캐시 조회와 병렬 발행, 취소 표시 필요), 다른 채널이 CPU 슬롯 앞의 읽기를
   못 잡게 예약 확장, 32 MB 맵을 2 MB 단위 mod-3 뱅크 교차로.
4. R800/터보(paced) 모드는 지연이 CPU 속도를 바꾸므로 분기 스트림 완전 일치를 기대할 수 없다.
   GT 700 ms 구간은 대부분 Z80이라 이 기준이 통했다.
5. 인수인계 4절 나머지: 핀 타이밍(출력 setup +0.079), V9968 연결, rebase.

## 5. 2026-10-13 밤: rebase, RAM 정책, CPU 마감 보강, 컴파일 (사용자 지시 1-4)

**1. rebase.** `git rebase --onto nextz80 7b4cf67 sdram128-study`, 32커밋, 충돌 0. 옛 base의 28커밋은
모두 nextz80에 패치로 있었다(`git cherry` 0). 검증: (rebase 전 -> 후 차이) == (7b4cf67 -> nextz80 차이),
바이트 단위 동일. 백업 브랜치 `sdram128-study-prerebase-20261013`. 이제 nextz80(03f7653) 위.

**2. RAM 정책 (b304b10).** 32 MB 보드는 머신 RAM 매퍼 최대 2 MB(memory_upload가 128 x 16 kB로 자르고
매퍼는 2 MB에서 미러), 64 MB 이상은 4 MB. 64 MB 보드는 sdram_tdm `mode64`가 논리 24-32 MB를 물리
32-40 MB(뱅크 0 열 윗절반, 행 비트 그대로)로 옮겨 VRAM 뱅크를 피한다(일반 영역 32 MB).
측정(run_upload32.sh, 최대 구성): 32 MB 보드 22.42 MB(< 24), 64 MB 보드 24.42 MB(< 32).
벤치: b64 4/4 PASS, 대조군 mno64 검출(ch4 stuck at 0x18806d3).

**3. 보강 (722abff).** 행 비트 != 00인 CPU 주소(큰 RAM, 카트 ROM)의 표준 속도 마감:
- G1 읽기 예약(CPU 대기 중이고 행 비트 != 00이면 다른 채널은 G1을 읽기로 못 잡음)
- CPU 보류/위치를 요청 다음 에지부터 조합으로(한 클록 늦던 c2_hold/c2_l 때문에 뱅크를 뺏김)
- ch2 두 칸 큐: R800 쓰기(완료 핸드셰이크 없음) 뒤 12-18클록 만의 다음 요청이 대기 중인 쓰기를
  덮던 문제. 미스 읽기는 큐의 쓰기 뒤에 선다. 넘침은 ch2_ovf(벤치가 실패 처리).
- 시도했으나 뺌: 캐시 조회와 병렬 조기 발행 -- 36위상 x 행 00/01 어디서도 차이 0.

| 위상 36개, 32 MB 맵, V 동작, ch1 같은 뱅크 | 행 00 | 행 01 |
|---|---|---|
| 보강 전 | LATE 0/36 | **36/36, 1,030건** |
| 보강 후 | 0/36, 최대 E0+24 | **0/36**, 최대 E0+28 |
| `TDM_MUT_NORSV` | | 35/36 |
| `TDM_MUT_LATEHOLD` | | 3/36 |

벤치 수정: ch2 에이전트가 ready로 읽기 완료를 판단하던 것을 rdtog/hit로(앞선 쓰기의 ready를 자기
것으로 착각), 행 01 CPU 영역이 ch1 영역과 겹치던 것, 마감 대조군은 위상 3개 x 40만 클록.
`sim/sdram_tdm/run.sh quick`: PASS, 엔진 28판, 대조군 11개(msens mbank mnoref mcap mcape mrdy
mrfslow mno64 mrsv mlate mrdover) 모두 검출.

**4. 컴파일.**

| 컴파일 (`tools/sdram128/compile.sh`) | clk_sdram setup | 실패 끝점 | 비고 |
|---|---|---|---|
| e1ceb7a (rebase + ready + 리프레시 취소 + OPL3) | **+0.291 ns** | 0 | 33bdddd +0.286과 같은 수준 |
| 722abff (+ RAM 정책 + 보강 첫판) | -25.273 ns | 223 | 큐 레지스터 `ch2b_*`가 SDC `*sdram*ch2_*` 멀티사이클 밖, 조합 gmap |
| 29b9886 (이름 `ch2_b*`, ch2_hl 레지스터, m128/m64 레지스터) | -0.110 ns | 3 | 모두 `ch2_bv` 출발 |
| **7cd1475** (ch2_bv/ch2_rdwait를 결정 경로에서 뺌) | **+0.110 ns** | **0** | 무시된 SDC 0, PCM PIPE 10/10, MLAB 31/31 |

핀 STA(io_sta.tcl, 7cd1475 fit): 입력 setup +2.777, 출력 setup +0.079 ns(이전과 같음, IO 레지스터 고정).
교훈: `check_timing.sh`의 마지막 RESULT PASS는 "빌드가 128.86 MHz PIPE 연구판이 맞다"는 뜻이고
타이밍 통과가 아니다. 722abff는 -25 ns인데 PASS가 찍혔다 -> slack 줄을 반드시 볼 것(5절 끝의 남은 일).
비트스트림은 여전히 연구용이며 보드에 올리지 않는다.

**최종 기능 확인 (7cd1475, fullsys FS-A1GT DOS2 700 ms vs sdram.sv 700 ms):** cmp_streams **46,026 분기 PASS**
(고유 PC 246, CPU 읽기 474,208회 동일), BIOS 업로드 차이 0, LATE 0, 느린 ch2 읽기 0, CPU 읽기 지연 최대 163.0 ns
(기준 174.6), T80s 일반 읽기 여유 최소 108.6 ns, clk_opl3 14.3184 MHz. 722abff도 같은 결과.
로그: `docs/evidence_20261013/fs_tdm_7cd1475_FS-A1GT_700ms.log.gz`, `compile_7cd1475.txt`.

### 남은 일 (다음 세션)
1. 실기는 아직이다(연구용 비트스트림, 보드 금지 유지). 128 단일 구조를 실제 릴리스로 삼을지는 사용자 결정.
2. 출력 핀 setup +0.079 ns가 빠듯하다: SDRAM_CLK를 PLL 출력(위상 조절)으로.
3. tRAS lockout(3절): 데이터시트 미보장. READ를 a+4로 옮기는 프레임 재탐색 또는 제조사 확인.
4. 32 MB 보드 업로드 상한 검사(카트 10/16 MB 극단에서 24 MB 초과 가능), MoonSound 없을 때
   pcm_rom_base 기본값 24 MB(VRAM 뱅크).
5. V9968 연결(v_en=1): VRAM 포트, 리프레시 슬롯. 벤치는 V를 이미 돌리고 있으나 fullsys는 v_en=0.
6. fullsys로 R800 쓰기 많은 부팅(ch2 큐가 실제로 쓰이는 경우)을 한 번 더: GT는 대부분 Z80 구간.

## 6. 2026-10-14 새벽: 실기 보고 -- Neon Horizon(GT) 타일 깨짐

7cd1475 rbf를 FS-A1GT에서 돌린 결과, 다른 소프트는 큰 이상이 없는데 MSXdev25 Neon Horizon(8 MB
ASCII16-X 카트, MoonSound 사용)의 배경 타일이 깨졌다. 단독 벤치에 "R800 쓰기 뒤 0-12클록 안에 다음 요청"
에이전트(+r800wr)를 넣자 두 가지가 재현됐다(c2c3c58):
1. **캐시 무효화 틈**: 슬롯이 쓰기를 고른 다음 에지(ACT)에서야 줄을 무효화하는데, 그 에지에 같은 주소 읽기의
   캐시 조회가 끝나면 큐는 비어 있고 c_we는 아직 0이라 옛 값이 적중으로 나간다(LD (HL),A / LD A,(HL)).
   수정: 무효화 예정 에지에는 같은 줄 적중 금지. 틀린 값 0/16판, 대조군 TDM_MUT_DROPGAP 3/16판.
2. **ch2 큐 넘침**: R800이 ~14클록마다 쓰면 한 뱅크에서 프레임당 한 슬롯보다 빨라 두 칸이 찬다(쓰기 유실).
   수정: 새 출력 ch2_busy -> msx.sv sdram_busy, 가드가 페이스 CPU의 SDRAM 쓰기 창을 붙잡는다(표준 속도 무관).
   대조군 TDM_MUT_NOBUSY 넘침 검출.
긴 시험(시드 8 x 60만 클록 x 32/128 MB x 간격 2종): 32/32 PASS, ch2 약 100만 회, 틀린 값 0, 넘침 0.
run.sh quick PASS(대조군 13개). fullsys GT 700 ms(c2c3c58): 46,026 분기 PASS, LATE 0.

타이밍: c2c3c58 -0.504(PCM w_pl <- w_regs.pan) -> ae02602에서 팬 표 조회를 한 클록 앞으로(PIPE만,
run_pcm128_verify quick PASS) -> SEED 8 -0.042(pcm w_word <- rdaddr_reg) -> **SEED 9 +0.057 ns, 0**.
rbf `MSX1_20261014b_sdram128_ae02602.rbf`(md5 e3decc31...) 사용자에게 보냄. 실기 재시험 대기.
**이 두 결함이 Neon Horizon 증상의 원인인지는 아직 증명되지 않았다**(게임을 fullsys로 돌리지 않음:
8 MB 카트 + MoonSound 업로드만 시뮬레이션 1.5초 이상, 벽시계 약 10시간).
