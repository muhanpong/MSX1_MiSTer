아래 내용을 다음 세션 첫 메시지로 붙여 넣는다.

---

MiSTer MSX1 코어의 SDRAM 128.86 MHz TDM 연구를 이어서 해 주세요. 보고는 한국어로 해 주세요.

작업 위치: worktree `/home/sysop/data/MiSTer_build/sdram128`, 브랜치 `sdram128-study`
(push 안 함). 이 브랜치의 비트스트림은 타이밍 연구용이라 보드에 올리면 안 됩니다.

먼저 읽을 것:
1. `docs/handoff_20261013_sdram128_tdm.md` (전체 상황, 0절이 최우선)
2. `docs/sdram_tdm_design.md` (TDM 설계와 숫자)

현재 상황:
- TDM 컨트롤러(`rtl/peripheral/sdram_tdm.sv`)를 넣은 코어는 128.86 MHz 타이밍을 통과했습니다
  (33bdddd, +0.286 ns). 단독 벤치 `sim/sdram_tdm/run.sh`도 통과합니다.
- 그러나 fullsys에서 기존 컨트롤러와 부팅이 다릅니다. 해제 후 5번째 분기에서 갈리고
  TDM 쪽은 고유 PC 60개를 맴돕니다. `sim/fullsys/cmp_streams.sh`가 이를 판정합니다
  (증거 로그: `docs/evidence_20261013/`).

할 일 (순서):
1. 부팅 불일치 원인 찾기. 후보: fullsys 칩 모델 `sdram_big_tdm`, 표준 속도 CPU의 고정
   소비 마감(TDM 최대 287 ns), 6:1 클록. 인수인계 0절의 가르는 방법을 따르세요.
   통과 기준: `cmp_streams.sh <run.sh 로그> <run_tdm.sh 로그>`가 RESULT PASS.
2. 32MB 수용 테스트(VRAM 256 KB + 슬롯 2 + MoonSound + 큰 팩). 아직 안 했습니다.
3. 나머지는 인수인계 4절.

main 쪽: 로컬 nextz80은 origin 위로 rebase됐고 precheck가 통과했습니다(EXIT 0, 13 레코드
PASS). push는 사용자 답 대기입니다. 먼저 물어보세요.

규칙:
- Quartus는 한 번에 하나, 컴파일 뒤 `git checkout -- MSX1.qsf`.
  컴파일은 `tools/sdram128/compile.sh`.
- 빌드·push는 사용자의 명시적인 말이 있을 때만.
- 벤치는 PATH 앞에 `/home/linuxbrew/.linuxbrew/bin`(기본 verilator는 4.038).
- fullsys 한 판은 40분-1.5시간. 도는 중에 run.sh를 고치지 마세요.
- 숫자는 음성 대조군과 함께, 계측은 물리적으로 가능한 값인지 스스로 확인.
- 결과물은 SendUserFile로 보냅니다.
