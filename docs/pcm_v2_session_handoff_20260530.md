# YMF278B PCM v2 — Session handoff (2026-05-30)

Continuation of `pcm_v2_session_handoff_20260529.md`.  이 세션에서 **clk_sdram
86 MHz setup timing closure 완료** (+0.065 ns).  PCM 잡음 = timing 무관 100% 종결.

## TL;DR

- **Timing CLOSED**: worst slack **-2.63 → +0.065 ns** (이번 세션).  baseline
  -28.76 ns 대비 총 28.8 ns 회복.  Top 10 전부 양수.
- 이번 세션 적용:
  1. **opl4latch multi-cycle SDC** (-2.63 → -1.68)
  2. **EG split** — phase+inc_v를 D1a로 이동 (-1.68 → -0.72)
  3. **opl4latch -to 확장** `{*pcm_engine*}` (-0.72 → +0.065)
- 하드웨어 검증:
  - 부팅/OSD/키보드 = timing closure로 최고 속도 ✅
  - 카트리지 (ASCII16X, SCC) 정상 ✅
  - **PCM 잡음 그대로 → timing 완전 무관 100% 확정 ✅**
- PCM 시뮬 360+ PASS, 0 FAIL (EG split functional 등가성).

## Timing 진척 (전체)

```
빌드                       Worst slack
5/23 baseline              -28.76 ns
5/29 fb8ed1d (A→B split)   -9.11 ns
5/29 multi-cycle SDC(ch2)  -5.12 ns
5/29 next_pos_for_b split  -2.63 ns
5/30 opl4latch multicycle  -1.68 ns
5/30 EG split (phase→D1a)  -0.72 ns
5/30 opl4latch -to 확장    +0.065 ns ✅ CLOSED
```

## 이번 세션 변경 상세

### opl4latch multi-cycle SDC

CPU OPL4 register write 경로 (`opl4latch → pcm_engine` decode registers).
opl4latch는 ce_3m58_p cadence로 갱신 → 본질적 multi-cycle.  처음엔 `-to
{*pcm_engine*ram_regs*}`만 잡았는데 worst가 `reg_upd.tl`로 hop → `-to`를
`{*pcm_engine*}`로 확장.  `-from`이 opl4latch로 제한돼 있어 안전 (engine 자체
per-cycle state는 다른 launch register라 영향 없음).

```tcl
set_multicycle_path -setup -end 6 \
    -from [get_registers {*ymf278b_regs*opl4latch*}] \
    -to   [get_registers {*pcm_engine*}]
set_multicycle_path -hold  -end 5 \
    -from [get_registers {*ymf278b_regs*opl4latch*}] \
    -to   [get_registers {*pcm_engine*}]
```

### EG split (process_eg D1a/D1b)

D1b의 critical chain이 `eg_cnt → ShiftRight → eg_inc_rom → Mult(calc_attack)`
였음.  `eg_phase` + `eg_inc_rom`을 D1a로 옮겨 `d1a_pkt.inc_v`로 register.
D1b는 registered inc_v만 소비 → chain이 register 경계에서 시작.  결과 동일
(시뮬 360 PASS).

## PCM 잡음 — timing 트랙 완전 종결

세 번의 하드웨어 테스트에서 일관:
- timing -2.6 ns → -0.7 ns → +0.065 ns 회복 단계마다 OSD/키보드는 개선
- **PCM 잡음은 매번 그대로** — timing 완전히 닫힌 +0.065 ns에서도 동일

→ PCM 잡음은 timing/metastability와 **무관 100% 확정**.  다음 세션은 순수
로직 버그 추적.

## 다음 세션 — 트랙 B (PCM 잡음 root cause) 전념

핸드오프 5/28의 보류 시나리오:
1. **노트 변경 시나리오 testbench** (50프레임마다 wave/fn/keyon 변경) — 가장 유력
2. **multi-slot 동시 재생** (slot 0,5,10)
3. **12-bit 디코딩 검증** (yrw801 실데이터 형식)
4. **WAV dump 분석** (pcm_left/right → .wav → Audacity)
5. 하드웨어 정적 노트 vs 시뮬 동작 차이 격리

### timing 잔여 (선택, 우선순위 낮음)

- 남은 marginal path: `d2_pkt.pan → master_accum_left` (+0.065 ns).  여유
  더 필요하면 첫 타겟이지만 이미 closed라 불필요.

## 참조

- 직전 핸드오프: `docs/pcm_v2_session_handoff_20260529.md`
- timing 리포트: `output_files/MSX1.timing_summary.txt`, `MSX1.worst5_full.rpt`
- 메모리: `~/.claude/projects/.../memory/project_timing_failure.md` (CLOSED 표시)
- openMSX 참조: `rtl/peripheral/SOUND/ymf278b_fpga/reference/YMF278.cc`
