# 인수인계 2026-10-14: Neon Horizon 타일 깨짐 (128.86 MHz 빌드에서만)

브랜치 `sdram128-study`, worktree `/home/sysop/data/MiSTer_build/sdram128`, nextz80(03f7653) 위.
push 안 함. 이 브랜치는 **128.86 MHz 단일 구조**로 간다(사용자 결정, 85.909 MHz와의 이중 리비전 없음).
앞 문서: `docs/handoff_20261013b_tdm_boot.md`(1-6절: 부팅 불일치 원인 두 개, RAM 정책, 보강, 컴파일).

## 0. 지금 풀 문제 (최우선)

**사용자 실기 보고:** FS-A1GT에서 MSXdev25 *Neon Horizon*(8 MB ASCII16-X 카트, MoonSound 사용)의
배경 타일이 깨진다. **거의 매번** 일어나고, **기존 릴리스 코어(85.9 MHz)는 매우 정상**이다. 다른 소프트는
큰 이상 없음. 스크린샷: `docs/evidence_20261014/board_neon_gt_{1,2}.png`(게임 화면, 타이틀).

"거의 매번 + 기존 코어 정상"이라 보드 타이밍 한계(무작위)보다 **128 MHz 브랜치의 결정적 차이**를 먼저
의심한다. 아직 원인은 모른다.

### 0.1 먼저 사용자에게 물을 것 (싸고 결정적)
1. 어느 rbf에서 봤나: `MSX1_20261014a_sdram128_7cd1475.rbf`인지 `..._20261014b_..._ae02602.rbf`
   (R800 캐시 틈 + ch2 큐 역압력 수정본)인지.
2. 128 빌드에서 **OSD MoonSound를 끄면** 사라지나. (MoonSound I/O 대기가 clk_sdram에 따라 달라지는 것을
   시뮬레이션에서 봤다, 0.3절)
3. 128 빌드에서 **Z80 전용 기종(FS-A1F/A1FX 팩)**으로도 깨지나. GT라면 R800/Z80 중 어느 쪽으로 도나.

### 0.2 이번 세션에서 고친 R800 결함 (c2c3c58, 단독 벤치로 재현)
- **캐시 무효화 1클록 틈**: TDM은 쓰기를 고른 다음 에지(ACT)에 줄을 무효화한다. 그 에지에 같은 주소 읽기의
  조회가 끝나면 옛 값이 적중으로 나갔다(LD (HL),A / LD A,(HL)). 수정 후 0/16, 대조군 TDM_MUT_DROPGAP 3/16.
- **ch2 큐 넘침**: R800이 ~14클록마다 쓰면 큐 두 칸이 찬다(쓰기 유실). `ch2_busy` -> msx.sv `sdram_busy`로
  페이스 CPU의 SDRAM 쓰기 창을 붙잡는다. 대조군 TDM_MUT_NOBUSY 넘침 검출.
- 이 둘이 Neon 증상의 원인인지는 **모른다**(0.1-1 답이 필요).

### 0.3 시뮬레이션 (FS-A1FX = Z80 전용 + MoonSound + Neon, 프리로드)

| 비교 | 결과 |
|---|---|
| 기존 vs TDM, MoonSound 켬, 2.5 s (`docs/evidence_20261014/neon_fs-a1fx_ms_*`) | **2.354 s까지 159,316 분기가 시각까지 같다.** 그 뒤 한 구간에서 TDM CPU가 12 us 빨리 지나가고, 이후 인터럽트 위치만 달라진다(경로 같음, 시각 다름). LATE 0, 틀린 읽기 0, BIOS 업로드 0 차이 |
| 프리로드 검증: GT DOS2 프리로드 vs 정상 업로드 700 ms 로그 | 18,236 분기 일치(대조군: 초기화 전 해제한 판은 2번째에서 갈림) |
| 진행 중: {기존, TDM} x MoonSound {켬, 끔}, 4 s, +iolog | 0.79 s까지 둘 다 일치. 0.4절 |

해석(**추정, 미증명**): 표준 속도 Z80에서 CPU 시간이 달라질 원인은 MoonSound I/O 대기뿐이다(msx.sv
`ms_io_pending`, clk_sdram 쪽 처리 시간에 따라 달라짐). 게임 시작부에서 MoonSound 웨이브 RAM에 샘플을
올리는 시점(2.35 s)과 맞는다. MoonSound를 끈 쌍이 2.354 s를 넘어 사이클까지 같으면 이 해석이 선다.
**시뮬레이션은 아직 게임 그래픽 구간까지 못 갔다**(2.5 s = 게임 코드 시작부).

### 0.4 진행 중이던 런 (세션 스크래치패드, 남아 있을 수도 사라졌을 수도)
`/tmp/claude-1000/-home-sysop-data-MiSTer-build-MSX1-MiSTer/5f215395-3f78-4837-8b99-bf485822b8a8/scratchpad/`
`nh_{old,tdm}_ms{0,1}.log` / `.io`, 프리로드 디렉터리 `nh_*/pre.*`. 비교:
`sim/fullsys/cmp_time.sh nh_old_ms0.log nh_tdm_ms0.log`. 다시 돌리려면 0.6절 명령.
**`.io`(+iolog)는 1.17 s까지 0바이트였다 -- 프로브가 동작하지 않는 것으로 보인다. 쓰기 전에 고칠 것.**

### 0.5 다음 단계 (제안 순서)
1. 0.1의 답을 받는다. MoonSound 끔으로 사라지면 MoonSound 경로(대기 타이밍, PCM 128 MHz PIPE 엔진,
   OPL3 /9 클록), 아니면 SDRAM 경로(카트 8 MB가 행 비트 01-11, ch3 플래시, 큐).
2. `+iolog` 고치기: 짧은 GT 판(50 ms)으로 VDP 쓰기 줄이 찍히는지 확인(양성), 포트 필터를 틀리게 한 판이
   0줄인지(음성).
3. 게임 그래픽 구간까지 fullsys: 기계 3-5 s 필요. TDM 판은 1 ms당 십수 초라 반나절. MoonSound 끈 쌍은
   사이클 비교(cmp_time), 켠 쌍은 VDP 값 순서열 비교.
4. 차이가 나오면 그 분기 직전의 CPU 읽기(RDL, LATE, SLOW)와 VDP 쓰기 값을 대조.
5. 실기에서 보드 타이밍 한계를 배제하려면: Memtest 코어로 그 보드를 130 MHz 안팎에서 점검.
   (출력 핀 setup 여유 +0.079 ns, 보드 지연은 가정값 0.3-0.7 ns)

### 0.6 명령
```
cd /home/sysop/data/MiSTer_build/sdram128
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH        # Verilator 5
S=<스크래치패드>; PX="/home/sysop/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack/MSX/Panasonic/Panasonic FS-A1FX.MSX"
R=<Neon .rom>      # 사용자 업로드 zip: MSXdev25_NeonHorizon_v1.0.rom (8 MB, ASCII16X = 매퍼 19)
FW=<fw.bin>        # sim/run_upload32.sh가 만든 것(yrw801 2 MB, 헤더 typ 8), OUT/fw.bin
MOONSOUND=1 EXTRA="+iolog=$S/x.io" OUT=$S/x sim/fullsys/run_preload.sh tdm "$PX" 4000 "$R" 19 "$FW" > $S/x.log 2>&1 &
sim/fullsys/cmp_time.sh $S/old.log $S/tdm.log          # 시각 기준 (로그 유실 구간 제외)
```

## 1. 이번 세션 커밋 (handoff_20261013b 6절 이후)

| 커밋 | 내용 |
|---|---|
| c2c3c58 | R800 캐시 틈 수정, ch2 큐 역압력(ch2_busy -> sdram_busy), 벤치 +r800wr |
| ae02602 | PCM PIPE 팬 표 조회 한 클록 앞으로(-0.504 ns 경로) |
| d956ddc | qsf SEED 9 (SEED 8 -0.042 ns, SEED 9 +0.057 ns, 실패 0) |
| 23dc698 | 문서 |
| 97de4d6 | fullsys `-DPRELOAD`, `sim/fullsys/run_preload.sh`, tb_upload32 `+dump` |
| (이 문서 커밋) | `sim/fullsys/cmp_time.sh`, tb_msx BR 줄 `#n`, `+iolog`(미검증), 스킬 갱신 |

rbf: `output_files/MSX1_20261014b_sdram128_ae02602.rbf`(md5 e3decc31..., setup +0.057 ns, SEED 9).

## 2. 하네스

| 명령 | 판정 |
|---|---|
| `sim/sdram_tdm/run.sh quick` | 엔진 28판(32/64/128 MB, 표준 속도 행 00/01, R800 쓰기) + 대조군 13개 |
| `sim/run_upload32.sh` | 32/64 MB 수용, RAM 정책 |
| `sim/fullsys/run_tdm.sh`, `run.sh`, `cmp_streams.sh` | 정상 업로드 fullsys, 순번 비교 |
| `sim/fullsys/run_preload.sh` | 업로드 건너뛰기(큰 카트, MoonSound) |
| `sim/fullsys/cmp_time.sh` | 시각 기준 비교(로그 유실 구간 제외). 같은 로그 PASS, 다른 기종 FAIL 확인 |
| `tools/sdram128/compile.sh` | 이제 `TIMING PASS/FAIL` 줄이 따로 있고 종료 코드가 따른다 |
| `rtl/peripheral/SOUND/ymf278b_fpga/sim/run_pcm128_verify.sh quick` | PCM 엔진 |

## 3. 주의 (이번 세션에서 배운 것)
- **시뮬레이터 로그가 가끔 수백 줄을 잃는다.** 한 줄에 타임스탬프 두 개가 흔적. 순번 비교는 가짜 갈림을
  낸다 -> cmp_time.sh. 한 번 속았다.
- **`pgrep -f`/`pkill -f`에 자기 명령줄 문자열이 걸려 셸이 죽는다**(exit 144). 프로세스 이름(-x)으로 찾고
  /proc/<pid>/cmdline으로 거를 것.
- **MSX1.qsf 끝에 줄바꿈이 없다**: `echo >> MSX1.qsf`가 주석 줄에 붙는다. SEED는 기존 줄을 sed로 바꿀 것.
- **타이밍 여유가 0.1 ns 안팎**: RTL을 조금 바꿔도 PCM 쪽 경계 경로(w_pl, w_word)가 튄다. 시드 재조정이
  필요할 수 있다.
- awk `NR==FNR` 패턴은 첫 파일이 비면 두 번째 파일까지 삼킨다(cmp_time.sh 첫 판이 0 vs 0 PASS를 냈다).
- 보드 금지 규칙은 사용자가 rbf를 요청해 실기 시험 중이다. 새 rbf는 사용자가 요청할 때만.
