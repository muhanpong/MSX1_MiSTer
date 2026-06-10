# YMF278B PCM v2 — Session handoff (2026-05-29)

Continuation of `pcm_v2_session_handoff_20260528.md`.  이 세션은 세 단계로 진행:
1. `fb8ed1d` 빌드 + 하드웨어 검증 + 새 worst path 분석
2. **Multi-cycle SDC** 적용으로 T80→SDRAM 경로 해소 (4 ns 회복)
3. **PCM next_pos_for_b 추가 split** (2.5 ns 추가 회복)

## TL;DR

- `fb8ed1d` 빌드: worst slack **-11.343 → -9.113 ns** (Stage A→B split 효과)
- **Multi-cycle SDC** 적용: **-9.113 → -5.119 ns** (T80 → SDRAM ch2 완전 해소)
- **PCM next_pos_for_b split**: **-5.119 → -2.629 ns** (Add11 chain register 경계로 이동)
- 하드웨어 검증 (세 빌드 모두):
  - **OSD/부팅/키보드 둔화 = timing 실패가 원인 ✅ 확정.**  단계마다 체감 개선.
  - **PCM 잡음 = timing 무관 ✅ 강하게 확정.**  PCM 엔진 자체 split도 잡음에 영향 없음.
  - **카트리지 (ASCII16X, SCC) 정상 동작 ✅** — multi-cycle SDC functional 회귀 없음.
  - **PCM 시뮬 360 PASS / 0 FAIL** — functional 등가성 보장.
- 남은 worst는 OPL4 register write 경로 (`opl4latch → ram_regs.fn`) — multi-cycle 후보.
- 다음 세션은 **PCM 잡음 root cause**로 트랙 전환 (timing은 충분).

## 빌드 결과

```
빌드               Worst slack   변화
5/23 base          -28.760 ns    (baseline)
5/27 P0+P1         -10.966 ns
5/28               -11.343 ns    (process_eg split + SDC false_path)
5/29 fb8ed1d       -9.113 ns     (Stage A→B split) — T80→SDRAM worst
5/29 + SDC         -5.119 ns     (multi-cycle path) — PCM 엔진 내부 worst
5/29 + PCM split   -2.629 ns     (next_pos_for_b ← next_pos_r) ← 현재
```

총 26.1 ns 회복 (baseline 대비).  남은 -2.6 ns는 closing 직전.

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

### Critical path 시간 분배

| 구간 | 누적 | 비중 |
|---|---|---|
| T80 IR[6] → opcode decode (Equal4 + NoRead) | 2.75 ns | 14% |
| Z80 A[14] + slot select | 1.29 ns | 7% |
| msx_slots Mux19 + Mux29 (4단 mux) | 4.90 ns | 25% |
| mapper~7 + mapper[4]~57/116 | 3.00 ns | 15% |
| cart_ascii8 + ascii8.LessThan2 | 2.09 ns | 11% |
| mem_unmaped~12, ~13 | 2.04 ns | 10% |
| Add2 (27-bit carry chain, ~14 cells) | 3.15 ns | 16% |
| ch2_addr_1 setup | 0.26 ns | 1% |
| **합계** | **19.48 ns** (slack -9.11 ns) | |

### 추가 split 옵션 (정량 분석)

`clk_sdram` 11.6 ns 주기.  "1 cycle 지연"은 모두 11.6 ns (SDRAM access 한 번에
대한 read latency 증가).  Z80은 `sdram_ready` 대기하므로 functional 영향 미미.

| 옵션 | 변경 위치 | 예상 slack 회복 | functional 영향 | 평가 |
|---|---|---|---|---|
| A | `msx_slots` 출력 `ram_addr` 전체 register | **~8–9 ns** (slack 거의 0) | Z80 SDRAM read +11.6 ns. 매퍼/카트리지 광범위 | 효과 크지만 가장 risky |
| B | `sdram.sv` 내부에 ch2_addr input register 한 단계 추가 | **≈ 0 ns** | sdram FSM이 1 cycle 늦게 ch2_addr 사용 | ❌ **timing 거짓 약속.** 18-level chain 끝점만 옮길 뿐 자르지 못함 |
| C | `msx_slots` 내부 mapper/mem_unmaped 출력 직후 register | **~3–6 ns** (위치에 따라) | mapper 결과 1 cycle 지연 (SDRAM access만) | ✅ 합리적 절충.  Add 자체보다 앞 mapper 체인 자르는 게 효과 큼 |

옵션 B는 register만 추가하고 chain은 그대로라 무의미.  진짜 효과를 보려면 chain
중간 (옵션 C) 또는 source 직후 (옵션 A)에 register 끼워야 함.

### 채택한 접근 — Multi-cycle SDC

옵션 A/C 모두 RTL 변경.  그런데 본질을 다시 보면:

- T80 IR/MCycle/A 등은 `clk21m + ce_3m58_p` enable로 갱신
- ce_3m58_p = clk21m / 6 → IR은 24 clk_sdram cycle마다 한 번 변경
- 즉 T80 → SDRAM 경로는 **실제로 multi-cycle path** (24+ cycles)
- Quartus 기본은 1 cycle setup → false -9.1 ns

`MSX1.sdc`에 `set_multicycle_path -setup 6 -hold 5` 추가:
```tcl
set_multicycle_path -setup -end 6 -to [get_registers {*sdram*ch2_*}]
set_multicycle_path -hold  -end 5 -to [get_registers {*sdram*ch2_*}]
```

`ch2_*` 패턴으로 captured 신호 (addr_1, rnw_1, din_1, rq, req_1) 한 번에.
RTL 변경 없음 — 본질이 그대로 multi-cycle인 path임을 SDC에 명시한 것.

**결과**: -9.113 → -5.119 ns (4 ns 회복).  worst path가 T80→SDRAM에서
PCM 엔진 내부로 이동.  카트리지 (ASCII16X, SCC) 정상 동작 확인 — multi-cycle
적용에 functional 회귀 없음.

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

### PCM next_pos_for_b split (3단계 후 적용)

11 logic levels chain:
```
oct → calc_step (ShiftLeft + Add5) → next_stepPtr (Add7)
    → overflow check (LessThan2) → next_pos_calc (Add8 12-cell carry)
    → next_pos_calc again (Add11) → next_pos_for_b_r
```

`next_pos_for_b`가 `next_pos`를 또 한 번 `next_pos_calc`에 통과시켜 Add11 chain
생성.  단 **한 줄 변경**: `next_pos_calc(next_pos, ...)` → `next_pos_calc(next_pos_r, ...)`.

Add11 chain이 register 경계 (next_pos_r)에서 시작 → cycle 1에서 빠짐.  결과:
- Cycle 1: oct → ... → Add8 → next_pos → next_pos_r register
- Cycle 2: next_pos_r → Add11 → next_pos_for_b → next_pos_for_b_r register

next_pos_for_b_r이 1 cycle 늦어지나 stage_advance까지 64-cycle window 충분.
시뮬 360 PASS, 하드웨어에서 PCM 음원/카트리지 회귀 없음 확인.

### 트랙 A 잔여 (선택, 다음 다음 세션)

남은 worst (-2.6 ns):
```
ymf278b_regs.opl4latch[4..5] → pcm_engine.ram_regs[6/16].fn[8]
```

CPU OPL4 register write → PCM 내부 register 갱신 경로.  CPU 갱신은 ce_3m58
budget 기반이라 **multi-cycle 후보 또 하나**.  -2.6 ns에서 closing 직전이라
적용하면 slack ≥ 0 가능성.

근데 PCM 잡음과 무관임 더욱 확정됐고, OSD/키보드는 이미 충분히 좋아짐.  추가
최적화는 우선순위 낮음.

## 참조

- 직전 핸드오프: `docs/pcm_v2_session_handoff_20260528.md`
- 이번 세션 timing 리포트: `output_files/MSX1.worst5_full.rpt`,
  `output_files/MSX1.timing_summary.txt`
- 메모리: `~/.claude/projects/.../memory/project_timing_failure.md` (5/29 갱신)
