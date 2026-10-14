MiSTer MSX1 코어 sdram128-study 브랜치에서 Neon Horizon 타일 깨짐을 이어서 풀어 주세요. 보고는 한국어로 해 주세요.

작업 위치: worktree `/home/sysop/data/MiSTer_build/sdram128`, 브랜치 `sdram128-study`(nextz80 위, push 안 함).
이 브랜치는 128.86 MHz 단일 구조로 갑니다(85.909 MHz 이중 리비전 없음).

먼저 읽을 것:
1. `docs/handoff_20261014_neon.md` (0절이 최우선: 문제, 시뮬레이션 결과, 다음 단계, 명령)
2. `docs/handoff_20261013b_tdm_boot.md` 5-6절 (RAM 정책, CPU 마감 보강, R800 수정, 컴파일 이력)
3. `.claude/skills/fullsys-measure/SKILL.md` (프리로드, 시각 기준 비교, 로그 유실 주의)

현재 상황:
- FS-A1GT 실기에서 MSXdev25 Neon Horizon(8 MB ASCII16-X, MoonSound)의 배경 타일이 거의 매번 깨집니다.
  기존 릴리스 코어(85.9 MHz)는 정상입니다. 원인은 아직 모릅니다.
- R800 경로 결함 두 개(캐시 무효화 1클록 틈, ch2 큐 넘침)는 고쳤고(c2c3c58), 그 rbf
  `MSX1_20261014b_sdram128_ae02602.rbf`를 드렸습니다. 이것이 원인이었는지는 미확인입니다.
- 시뮬레이션(FS-A1FX, Z80 전용, MoonSound 켬): 기존 vs TDM이 2.354 s까지 시각까지 같고, 그 뒤 MoonSound
  대기로 보이는 타이밍 차이만 있습니다(추정). 게임 그래픽 구간까지는 아직 못 갔습니다.

할 일 (순서):
1. 먼저 저에게 물어 주세요: 어느 rbf(20261014a/b)에서 봤는지, 128 빌드에서 OSD MoonSound를 끄면
   사라지는지, Z80 전용 기종(FS-A1F/A1FX)에서도 깨지는지.
2. `+iolog`(VDP/MoonSound I/O 값 기록) 프로브를 고치고 양성/음성 대조로 검증. 지난 판에서 0바이트였습니다.
3. 답에 따라 MoonSound 경로 또는 SDRAM 경로를 fullsys(`sim/fullsys/run_preload.sh`)로 게임 그래픽 구간까지
   기존 vs TDM 비교. 비교는 `sim/fullsys/cmp_time.sh`(로그 유실 구간 제외). 차이가 나면 원인 분석과 수정.

규칙:
- Quartus는 한 번에 하나, 컴파일 뒤 `git checkout -- MSX1.qsf`. 컴파일은 `tools/sdram128/compile.sh`,
  판정은 마지막 `TIMING PASS/FAIL` 줄(앞의 RESULT PASS는 "맞는 빌드"라는 뜻일 뿐). rbf는 그 뒤
  `quartus_asm MSX1 -c MSX1`, 타이밍 PASS일 때만.
- 빌드·push·rbf 전달은 제 명시적인 말이 있을 때만. 결과물은 SendUserFile로.
- 벤치는 PATH 앞에 `/home/linuxbrew/.linuxbrew/bin`(Verilator 5). fullsys TDM 판은 기계 1 ms당 십수 초.
- 숫자는 음성 대조군과 함께, 계측은 물리적으로 가능한 값인지 스스로 확인.
- `pgrep -f`/`pkill -f`에 자기 명령줄이 걸리지 않게(-x와 /proc/<pid>/cmdline 사용).
