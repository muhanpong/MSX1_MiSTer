MiSTer MSX1 코어 sdram128-study 브랜치 작업을 이어서 해 주세요. 보고는 한국어로 해 주세요.

작업 위치: worktree `/home/sysop/data/MiSTer_build/sdram128`, 브랜치 `sdram128-study`(nextz80 위, push 안 함).
128.86 MHz 단일 구조. 사용자 보드는 128 MB.

먼저 읽을 것:
1. `docs/handoff_20261020_reqs.md` (0절 표가 현재 상태, 1절이 원인 판정 순서, 5절이 배운 것)
2. `.claude/skills/fullsys-measure/SKILL.md` 끝 세 절(128 MB 맵·프로브·지연 주입, 부팅 위상·행 비트, STA 짝)
3. V9968 작업을 하게 되면 `docs/handoff_20261012_sdram128.md` 1절과 `docs/sdram_tdm_design.md`

현재 상황:
- 한자 D9h(수정 B 7b27baf)와 Neon Horizon 배경 깨짐(요청 단일 표본 ch2_req_s, b1b2d7f)은 실기에서 해결됨.
  배포 후보 rbf: `output_files/MSX1_20261019b_sdram128_481569a.rbf` (md5 170441aa520a33084a922efc8e70da32,
  Quartus 17.0.2 + tools/sdram128/compile.sh, SEED 10, TIMING PASS, buildgate 미경유).
- 남은 확인: 사용자 보드 전원 사이클·긴 플레이(복원한 진행 세이브), core_builder의 17.1 buildgate 재fit.
- V9968 + geo3d는 아직 RTL에 없음. sdram_tdm의 V 포트는 MSX1.sv에서 v_en=0으로 묶여 있음.

할 일 (사용자에게 우선순위를 먼저 물을 것):
1. 사용자·mister-super-expert의 추가 실기 결과가 오면 판정. 깨짐이 다시 보이면 (d) 고정 위상 표본(에지 2 enable)
   또는 2플롭으로 준안정까지 닫는 안을 core_builder와 맞춘다.
2. core_builder 17.1 재fit 결과가 오면 relations.tcl·field_race로 교차 확인.
3. nextz80 합치기 전 정리 목록(handoff 3절 3): sdram.sv에도 같은 구조가 필요한지, 32/64 MB 기한 상수, PCM w_word 파이프.
4. V9968(+geo3d) 통합 계획 — 사용자가 다음 단계로 정하면.

규칙:
- 빌드·push·rbf 전달은 사용자의 명시적인 말이 있을 때만. Quartus는 한 번에 하나, `project_open`(quartus_sta -t 포함)
  뒤에는 `git checkout -- MSX1.qsf`. 이 기계는 Quartus 17.0(`/home/sysop/data/intelFPGA_lite/17.0`)뿐이고
  tools/buildgate/build.sh의 Q 경로는 다른 기계(17.1) 것 — 바꾸려면 사용자 승인.
- 컨트롤러 RTL을 바꾸면 `tb/mkshim*.py`로 `sim/fullsys/gen/` 사본부터 다시 만든다.
- 시뮬 PASS는 레지스터 간 경쟁을 증명하지 못한다: STA(field_race.tcl, relations.tcl)로 재고, 판별은 실기로.
- 실기 시험은 결론을 가를 때만. 보드 작업은 mister-super-expert 세션이 함.
- nextz80 브랜치는 건드리지 않음. 결과물 전달은 SendUserFile, core_builder에는 SendMessage(번들은 base64 조각 + md5).
- 숫자는 음성 대조군과 함께. 주입·프로브는 넣은 직후 자체 검사 줄로 의도대로인지 먼저 확인.
- 벤치는 PATH 앞에 `/home/linuxbrew/.linuxbrew/bin`(Verilator 5). `pgrep -f`/`pkill -f` 대신 `-x`와 /proc/<pid>/cmdline.
