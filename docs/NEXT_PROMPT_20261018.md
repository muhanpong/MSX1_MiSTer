MiSTer MSX1 코어 sdram128-study 브랜치 작업을 이어서 해 주세요. 보고는 한국어로 해 주세요.

작업 위치: worktree `/home/sysop/data/MiSTer_build/sdram128`, 브랜치 `sdram128-study`(nextz80 위, push 안 함).
128.86 MHz 단일 구조. nextz80 비교용 worktree `/home/sysop/data/MiSTer_build/nz_3f09aaf`(3f09aaf, detached,
하네스 파일만 복사·미커밋).

먼저 읽을 것:
1. `docs/handoff_20261018_neon_kanji.md` (0절 표가 현재 상태, 3절이 진행 중이던 점검)
2. `.claude/skills/fullsys-measure/SKILL.md` 끝 두 절(128 MB 맵·프로브·지연 주입, VDP 재생)
3. 필요하면 `docs/handoff_20261014_neon.md`, `docs/handoff_20261013b_tdm_boot.md` 5-6절

현재 상황:
- 한자 D9h 회귀(실기 0-8/4096)는 원인(IORQ로 요청과 주소 선택이 동시에 바뀜 + 첫 에지 캡처 + SDC 6클록 예외)을
  시뮬로 재현하고 수정 B를 커밋함(7b27baf). 빌드·실기 확인 전.
- Neon Horizon 그림 깨짐은 미해결. 카트 읽기·VDP RTL·.sav는 배제됨.
- core_builder 세션의 의뢰로 스트로브 경쟁 점검(P1 쓰기 rnw, P2 쓰기 데이터, P3 FFFF 쓰기 글리치, P4 레지스터 읽기
  게이트)을 지연 주입 시뮬로 돌리던 중(하네스 3d9250c). 무효 조건: 주입 없음 PASS, INJ_ADDR(음성대조) PASS.

할 일 (순서):
1. 점검 결과 확인. 남아 있으면 스크래치의 rp128/, rpnz/ 로그를, 없으면 handoff 6절 명령으로 20판(주입 5종 x
   zspeed 0/3 x 두 트리)을 다시 돌림. 항목별 주입 전후 수치와 두 컨트롤러 비교를 core_builder에 보냄.
   실패가 재현되는 항목은 수정안만 제안(코드 수정 금지). 주입마다 "값이 달랐던 횟수"가 0이 아닌지 확인.
2. 시간이 되면 L1(opl4latch→pcm_engine -end 6: reg_addr 5클럭 지연 + 중간값 $random → 비트 일치, 200클럭이면 FAIL)과
   L2(NextZ80 advance 다음 1클럭 nz_a/nz_do $random → R800 팩 PASS, ph=1 고정이면 FAIL).
3. FFFF에 0Fh를 쓰면 페이지 0 인출이 RST 38로 빠지는 관찰(handoff 3절)은 별도 조사 거리 — 사용자에게 물어서.

규칙:
- 빌드·push·rbf 전달은 사용자의 명시적인 말이 있을 때만. Quartus는 한 번에 하나, `project_open`(quartus_sta -t 포함)
  뒤에는 `git checkout -- MSX1.qsf`.
- 실기 시험은 결론을 가를 때만, openMSX에서 양성·음성 대조 통과 후에. 보드 작업은 mister-super-expert 세션이 함.
- nextz80 브랜치는 건드리지 않음(core_builder 결정). 결과물 전달은 SendUserFile.
- 숫자는 음성 대조군과 함께. 주입·프로브는 넣은 직후 파형(+kwave)으로 의도대로인지 먼저 확인.
- 벤치는 PATH 앞에 `/home/linuxbrew/.linuxbrew/bin`(Verilator 5). `pgrep -f`/`pkill -f` 대신 `-x`와 /proc/<pid>/cmdline.
