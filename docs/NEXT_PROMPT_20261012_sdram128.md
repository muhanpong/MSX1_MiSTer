아래 내용을 다음 세션 첫 메시지로 붙여 넣는다.

---

MiSTer MSX1 코어의 SDRAM 128.86 MHz 연구를 이어서 해 주세요.

작업 위치는 worktree `/home/sysop/data/MiSTer_build/sdram128`, 브랜치 `sdram128-study`입니다
(로컬 nextz80 `7b4cf67`에서 분기, push 안 함). 이 브랜치의 비트스트림은 타이밍 연구용이라
보드에 올리면 안 됩니다.

먼저 읽을 것:
1. `docs/handoff_20261012_sdram128.md` (전체 상황, 결과, 남은 일)
2. `docs/pcm_engine_128mhz_plan.md` (PCM 엔진 재구성 계획과 진행 기록)

시작 전에 확인:
- `tools/sdram128/check_timing.sh`로 마지막 컴파일(c126c6c, PIPE 켜짐)이 주장하는 빌드인지와
  남은 실패 경로를 확인하고, 인수인계 3절이 비어 있으면 채웁니다.
- 손댄 뒤에는 `rtl/peripheral/SOUND/ymf278b_fpga/sim/run_pcm128_verify.sh`가 `RESULT PASS`여야
  합니다. 빠른 확인은 `quick` 인자.

다음 할 일 후보(인수인계 6절). 무엇부터 할지 사용자에게 물어보세요. 제 추천 순서:
1. 남은 PCM 경로(캐시 무효화 순회, 출력 포화, w_slot 인덱스 읽기, 캐시 태그 비교)
2. SDRAM TDM 컨트롤러 시제품(12클록 프레임, VRAM 뱅크 3, 버스트 2)
3. 클록 도메인 경계와 SDC 정리

규칙:
- Quartus는 동시에 하나만. `/home/sysop/data/intelFPGA_lite/17.0/quartus/bin` 사용.
  컴파일 뒤 `git checkout -- MSX1.qsf`.
- 커밋은 경로를 지정해서. push는 사용자 승인 후에만.
- 타이밍이 바뀌는 변경은 매 클록 lockstep으로 판정할 수 없습니다. 인수인계 4절의 판정 방식을
  따르세요.
- 숫자는 음성 대조군과 함께 보고합니다.
