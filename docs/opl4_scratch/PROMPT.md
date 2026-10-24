# 시작 프롬프트 (새 세션에 그대로 붙여 넣기)

```
MSX1 MiSTer 코어의 OPL4(YMF278B) PCM 엔진을 처음부터 다시 만든다. 보고는 한국어, 커밋과 코드 주석은 영어.

작업 위치: ~/data/MiSTer_build/sdram128 (worktree). 새 브랜치 opl4_scratch를 V9968_Geo3D에서 만든다.
push는 내가 요청할 때만. Quartus는 한 번에 하나만 (pgrep -x로 확인). 큰 출력은 /data/_claude/tmp/<세션이름>/.

먼저 읽을 것:
1. docs/opl4_scratch/PLAN.md (계획, 목표 수치, 단계, 함정)
2. .claude/skills/opl4-harness/SKILL.md (게이트와 규칙) — 이 작업의 모든 판정은 이 스킬의 게이트로 한다
3. docs/pcm_engine_v3_design.md (현행 엔진의 설계와 보존해야 할 의미론)
4. rtl/peripheral/SOUND/ymf278b_fpga/sim/golden/RESULTS.md, sim/lockstep/README.md, sim/golden_srg/README.md

이번 세션 범위는 P0과 P1만이다:
P0. docs/opl4_scratch/SPEC.md를 쓴다: 현행 엔진이 지키는 CPU 가시 동작과 하드웨어 검증 의미론,
    openMSX와의 의도적 차이, 각 항목을 검증할 시나리오 이름. 근거는 파일:줄로.
P1. 하네스를 새 엔진 없이 완성한다:
    - harness.sh all 이 현행 엔진으로 HARNESS PASS (resource는 PCM_ALM_MAX=3000 MS_ALM_MAX=4200으로 대조 실행,
      기본 예산으로는 FAIL이 나와야 정상)
    - 뮤턴트를 최소 6개 만든다 (보간, EG, LFO, 팬, 헤더 백필, 루프 경계). 전부 golden에서 잡혀야 한다.
      안 잡히는 뮤턴트가 있으면 그 동작을 덮는 시나리오를 추가한다.
    - memwr 게이트의 음성 대조(MEM_WRITE_DELAY 0)가 FAIL하는 것을 한 번 보인다.
    - CPU 가시 동작(상태 비트, BUSY 길이, reg 0x02/0x06 메모리 읽기·쓰기, ID 감지) lockstep 게이트를 새로 만든다:
      현행 엔진 대 openMSX YMF278B 동작 기준. 이 게이트도 뮤턴트로 FAIL을 보인다.
새 엔진 RTL은 이번 세션에서 쓰지 않는다. P1이 끝나면 P2 설계 초안(슬롯당 마이크로시퀀스, 자원 배정,
128.86 MHz에서 2,922클럭 프레임 예산표)을 docs/opl4_scratch/DESIGN.md로 제안하고 멈춘다.

보고 형식: 게이트 줄 그대로 + 각 PASS의 대조군 + 실행하지 않은 것. 숫자는 대조군 없이 보고하지 않는다.
```

## 다음 세션용 (P2 이후)

```
docs/opl4_scratch/{PLAN,SPEC,DESIGN}.md와 opl4-harness 스킬을 읽고 P2(골격: CPU 인터페이스, 레지스터 파일,
메모리 연산, 상태/BUSY)를 구현한다. 새 엔진은 rtl/pcm/ymf278_pcm_engine3.sv, 포트는 ymf278_pcm_engine2와 같게.
ENGINE="... ymf278_pcm_engine3.sv" harness.sh 로 판정. 게이트를 바꿀 필요가 생기면 먼저 현행 엔진으로 새 게이트를
PASS시키고 뮤턴트로 FAIL을 보인 뒤에 바꾼다. 단계가 끝날 때마다 커밋, Quartus fit은 P5에서만.
```
