# YMF278B PCM v2 — Session handoff (2026-05-29)

Continuation of `pcm_v2_session_handoff_20260528.md`.  이 세션은 `fb8ed1d`
(Stage A→B split) 빌드 + 하드웨어 검증 + 새 worst path 분석으로 마무리.

## TL;DR

- `fb8ed1d` 빌드 성공.  Worst slack **-11.343 → -9.113 ns** (약 2.2 ns 회복).
- 하드웨어 검증 결과:
  - **OSD/부팅/키보드 둔화 = timing 실패가 원인 ✅ 확정.**  체감 개선 분명.
  - **PCM 잡음 = timing metastability 가설 ❌ 기각.**  잡음 그대로, 볼륨만 살짝.
- 새 worst path가 PCM 엔진에서 빠지고 **T80 → SDRAM ch2_addr_1** 경로로 이동.
- 추가 timing split은 functional risk가 커서 보류.  다음 세션은 PCM 잡음 root
  cause로 트랙 전환 권장.

## 빌드 결과

```
빌드        Worst slack   변화
5/23 base   -28.760 ns    (baseline)
5/27 P0+P1  -10.966 ns
5/28        -11.343 ns    (process_eg split + SDC false_path)
5/29        -9.113 ns     (Stage A→B split, fb8ed1d) ← 현재
```

Top 10 path 전체가 같은 패턴:
```
From: T80:u0|IR[6]~DUPLICATE  (또는 MCycle[1])
To:   sdram|ch2_addr_1[26]
```

PCM 엔진은 worst 10 밖.  Stage A→B split 성공.

## 새 worst path 분석 (T80 → SDRAM ch2_addr)

18 logic levels 체인:

```
T80|IR[6]                       Z80 opcode 비트
  ↓ Equal4~0, ~3                IR 값 비교 (opcode match)
  ↓ mcode|NoRead~0              microcode 결과
  ↓ A[14]~1                     Z80 address bus A14 계산
  ↓ MSX|slot[0]~4               slot select
  ↓ msx_slots|Mux19~3, ~4       slot mapper mux
  ↓ msx_slots|Mux29~19, ~20     2단 mux
  ↓ msx_slots|mapper~7
  ↓ msx_slots|mapper[4]~57, ~116
  ↓ msx_slots|cart_ascii8~1     ASCII8 cartridge mapper
  ↓ msx_slots|ascii8|LessThan2~5  range check
  ↓ msx_slots|mem_unmaped~12, ~13
  ↓ msx_slots|Add2~146..~96     27-bit signed add (carry chain 14 cells)
  ↓
sdram|ch2_addr_1[26]            target register
```

`ch2_addr_1`은 sdram 내부에서 `ch2_req` rising edge에 `ch2_addr`를 latch.
그 입력 `ch2_addr` ← `msx_slots.ram_addr` (조합 출력) ← 18-level 체인.

### 추가 split 옵션 (모두 functional 영향)

| 옵션 | 변경 위치 | 영향 범위 |
|---|---|---|
| A | `msx_slots`에서 ram_addr register stage 추가 | Z80 read path 1 cycle 지연.  wait state/마퍼 동작 광범위 영향. risky |
| B | `sdram.sv`에서 ch2_addr input register 한 단계 추가 | 비교적 작은 범위.  ch2 bandwidth 약간 감소 |
| C | `msx_slots` 내부 27-bit Add만 register stage로 분리 | mapper 결과 1 cycle 지연.  Z80 timing 영향 가능성 |

이번 세션에서는 모두 보류.  -9.1 ns에서 더 줄여봤자 PCM 잡음과 무관 (확인됨)이고
Z80 read path 회귀 위험만 큼.  잡음 진짜 원인 추적이 우선순위 높음.

## 가설 갱신

| 가설 | 상태 |
|---|---|
| OSD/키보드 둔화 ← timing 실패 | ✅ 확정 (2.2 ns 회복 후 체감 개선) |
| PCM 잡음 ← timing metastability | ❌ 기각 (2.2 ns 회복했는데 잡음 그대로) |
| PCM 잡음 ← 로직 버그 (12-bit decode / multi-slot / 노트 변경 / master_accum) | 다음 트랙 |

## 다음 세션이 해야 할 것 (트랙 B 전환)

핸드오프 5/28의 "잡음이 여전히 있고 timing은 닫혔다면" 시나리오로 진입:

1. **노트 변경 시나리오 testbench** (가장 유력)
   - 50프레임마다 wave / fn / keyon 변경
   - Stage A→B latch + EG transition 조합 시 race 의심
2. **multi-slot 동시 재생** — slot 0,5,10 활성화
3. **12-bit 디코딩 검증** — yrw801 실데이터 형식 시뮬
4. **WAV dump 분석** — `pcm_left`/`pcm_right`를 .wav로 저장 후 Audacity
5. **하드웨어에서 BASIC 정적 노트 시나리오** — 시뮬과 하드웨어 동작 차이 격리
   확인.  시뮬은 PASS, 하드웨어는 잡음인 시나리오를 구체적으로 reproducer.

### 트랙 A 잔여 (선택, 다음 다음 세션)

- 옵션 B (sdram.sv ch2_addr input register) — 가장 낮은 risk, 다음 timing
  closure 시 첫 후보
- `output_files/MSX1.timing_summary.txt` 자동 비교용 grep 추가도 좋음

## 참조

- 직전 핸드오프: `docs/pcm_v2_session_handoff_20260528.md`
- 이번 세션 timing 리포트: `output_files/MSX1.worst5_full.rpt`,
  `output_files/MSX1.timing_summary.txt`
- 메모리: `~/.claude/projects/.../memory/project_timing_failure.md` (5/29 갱신)
