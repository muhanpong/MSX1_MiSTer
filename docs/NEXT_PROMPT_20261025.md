# 다음 세션 시작 프롬프트 (2026-10-25)

```
~/data/MiSTer_build/sdram128 (worktree, 브랜치 V9968_Geo3D)에서 이어서 작업한다. 보고는 한국어, 커밋·주석은 영어,
push는 내가 요청할 때만. 먼저 읽을 것:
1. docs/handoff_20261025_v9968_geo3d.md (현재 상태, 열린 문제, 결정, 규칙)
2. 메모리 MEMORY.md (특히 long-sim-milestone, build-delivery-and-monitoring, v9968-oracle, sdram128 study)

첫 작업: 내가 보드에서 LRMMWR.ROM을 다이얼 None과 8.66 µs로 돌린 화면을 줄 것이다. 6개 시험의
[빠른 읽기 오류, 느린 읽기 오류, 겹침 횟수]를 해석하고, SUPER CAT·PRISM FLIGHT 글리치(R800 VDP 대기 < 3 µs)의
원인 추적 계획을 세워라. 시뮬레이션은 30분이 넘으면 초반 확인 지점과 자동 중단을 반드시 넣고, 걸릴 시간을 먼저 말해라.
Quartus는 같은 폴더에서 동시 실행 금지(시드 병렬은 별도 복사본), 모든 PASS는 음성 대조와 함께.
```
