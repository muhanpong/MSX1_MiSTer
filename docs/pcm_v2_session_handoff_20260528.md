# YMF278B PCM v2 — Session handoff (2026-05-28)

Continuation of `pcm_v2_session_handoff.md` (frozen at commit `669bfb8`).
Read that first for architecture map, build/deploy workflow, BASIC diagnostic
snippets, and earlier commit chain.  This document captures the timing
closure investigation done on 2026-05-28.

## TL;DR

- PCM 잡음의 **숨은 원인**: `clk_sdram` (86 MHz) **timing closure 실패**.
  현재 baseline에서 worst-case setup slack -11.343 ns, TNS -7580 ns.
- OSD/USB 키보드 둔화의 직접 원인이기도 함 (사용자가 이전부터 알고 있던 문제).
- 시뮬레이션 H3/H6/H8 모두 PASS → 시뮬과 실 동작 불일치가 **timing 실패의 metastability**로 설명됨.
- 이번 세션에 5개 커밋 적용 후 빌드 + 결과 확인 후, 다음 worst path가 무엇이냐에 따라 추가 split 또는 마무리.

## Commit chain (this session)

```
fb8ed1d  engine: pipeline Stage A→B chain via next_pos_r intermediate   ← HEAD, 미테스트
dd3098c  build: auto-generate worst-case timing report after compile
286d644  sdc: explicit false_path between emu_pll and pll_audio outputs
baa044a  engine: split process_eg into D1a/D1b for timing closure
1090d9b  engine: gate Stage B mem_rd_en on !mem_busy (P1.A')
597249a  engine: revert Stage B drop_next_valid (silence regression)    ← P0 revert
```

### `597249a` (P0 — silence regression revert)
이전 세션의 `drop_next_valid` fix가 silence 회귀를 일으켰음.  Stage B의 5번째 read
outstanding 중 stage_advance가 발생하면 read 요청이 lost 되는 데드락.  복구.

### `1090d9b` (P1.A' — bridge serialization)
`mem_busy` (`pcm_state != IDLE`)을 엔진까지 forward하고 Stage B의 `B_ISSUE` 전이
및 `mem_rd_en` 펄스를 `!mem_busy`로 게이팅.  late-valid leak 해결.  Stage A→B
late-valid leak 버그의 정공 fix.

### `baa044a` (process_eg pipeline split)
`process_eg` task를 D1a (rate + shift_v + sel_v + do_update) + D1b (phase + inc
+ 최종 vol update)로 분할.  결과적으로 worst path는 process_eg가 아니라
Stage A→B 체인이었으나 (아래 참조), 어쨌든 deeper pipeline 부담 분산됨.

### `286d644` (SDC false_path)
`sys/sys_top.sdc`의 `set_clock_groups -exclusive` 글로브 패턴이 Quartus 17.1에서
일부 PLL output을 매칭 못 하여 `audio_out|IIR_filter`의 `acx → intreg` 경로가
-23.69 ns로 timing됨.  `acx`는 HPS가 가끔 갱신하는 IIR 필터 계수라 cross-domain
sampling이 본질적으로 안전.  `set_false_path` 양방향 명시.  **결과: -23.69 paths
사라짐.**

### `dd3098c` (build automation)
`make build` 끝나면 자동으로 `quartus_sta -t report_paths.tcl` 실행:
- `output_files/MSX1.worst_setup.rpt` — top 10 path summary
- `output_files/MSX1.worst5_full.rpt` — top 5 cell/routing detail
- `output_files/MSX1.fmax.rpt`        — per-clock fmax
- `output_files/MSX1.timing_summary.txt` — 콘솔 친화 표
Makefile이 마지막에 summary 출력.  TimeQuest GUI 안 띄우고도 worst paths 추적 가능.

### `fb8ed1d` (Stage A→B split — 미테스트)
**이번 세션의 마지막 변경.**  Build 자동 리포트가 worst path를 정확히 지목:
```
From: pcm_engine|stage_a_reg.regs.oct[0]
To:   pcm_engine|stage_b_reg.addrs.b1[20]
```
체인: `oct/fn → calc_step → next_step_full → next_stepPtr → next_pos_calc
→ byte_addr (×3 multiply for 12-bit) → stage_b_reg.addrs`.

20+ LUT + DSP가 한 사이클 안.  Intermediate register `next_pos_r` /
`next_pos_for_b_r` / `next_stepPtr_r` 추가하여 2-cycle 파이프라인으로 분할.
`byte_addr ×6` 호출이 registered `next_pos_r`을 읽어 multiplier 체인이 register
경계에서 시작.  64-cycle 슬롯 윈도우에서 2 cycle만 사용 → 60+ cycle 슬랙.

**357/357 testbench 통과**.  하드웨어 + 새 timing 측정 대기 중.

## Timing 진척 (가장 중요한 metric)

| 빌드 | Worst slack | TNS |
|---|---|---|
| 5/23 baseline | -28.760 ns | -19430 ns |
| 5/27 (P0+P1) | -10.966 ns | -7227 ns |
| 5/28 (process_eg split + SDC false_path) | -11.343 ns | -7580 ns |
| 5/28 (+ Stage A→B split) | **?** (미빌드) | **?** |

5/28 빌드는 process_eg split이 worst path가 아니어서 별 효과 없었음.  Stage A→B
split이 실제 worst path를 건드림 → timing 큰 폭 회복 기대.  하지만 다음 worst가
어디일지 모름 — 빌드 결과 확인 필수.

### 가능한 다음 worst path 후보

1. **24-bit master_accum saturation** (D3) — `master_accum + left_sample`의
   24-bit signed adder + saturation 비교.  ~12 ns 가능성 있음.
2. **HF FSM의 wave * 12 계산** — wave 번호 (9-bit) × 12 multiply.
3. **CPU mem write/read decode** — `reg_addr` (8-bit) decode 후 ram_regs[slot]
   필드 update 로직.
4. **OPL3** — gtaylormb OPL3 core 자체.  외부 IP라 손대기 어려움.

## 시뮬레이션 결과 (가설 검증)

`tb_long_run.sv` (이번 세션 신규):
- **H3** ram_dyn.pos 누적: PASS (16-bit 12-sample 루프 정상 wrap)
- **H6** Stage B 64-cycle window: PASS (2400/2400 = 100% bytes_done)
- **H8** EG transition: PASS (EG_OFF → EG_SUS, EG_ATT cycles = 0 with AR=15)

**모두 PASS = 시뮬에서는 노이즈 재현 안 됨.**  하드웨어 잡음은 timing 실패로 인한
metastability/glitch라고 가설 강화.

## 알아낸 사실 (재확인 불필요)

- yrw801.rom은 SDRAM에 정확히 로드됨 (BASIC dump로 wave 0/1/5/10/50/100/200/300
  헤더 모두 일치 확인).
- CPU mem read path (reg 0x02-0x06) 정상.
- HF FSM의 header parsing 정확 (deterministic from same SDRAM data).
- Wave-rendering math (`byte_addr`, `decode_sample`, `next_pos_calc`, `calc_step`,
  `process_eg`) 모두 openMSX와 일치 — 코드 audit 완료.
- 단일 슬롯, 정적 노트 시나리오는 시뮬에서 완벽 동작.

## NEW2 관련 메모

- `OUT &HC6,&H05 : OUT &HC7,&H02` 로 BASIC에서 NEW2 직접 enable 가능 (PCM 포트
  활성화 전제 조건).  음악 player 실행 전 dump 테스트할 때 필요.
- `opl3_reg_shadow`에 `rst_n` 처리 없음 → 소프트 리셋해도 NEW2 안 풀림 (잡음
  원인은 아님, cleanup 거리).

## 디버깅 도구 메모

### 자동 timing 리포트 (이번 세션 신규)
```bash
make build  # 끝나면 timing summary 자동 출력
cat output_files/MSX1.timing_summary.txt
less output_files/MSX1.worst5_full.rpt  # cell-level detail
```

### TimeQuest GUI (libpng 필요)
```bash
quartus
```
Tools → TimeQuest → Update Timing Netlist → Reports → Report Timing
Console: `report_timing -setup -npaths 5 -detail full_path`

### iverilog 시뮬
```bash
cd rtl/peripheral/SOUND/ymf278b_fpga
for tb in tb_pipeline_scaffold tb_cpu_reg_decode tb_hf_fsm tb_integration \
          tb_bridge_realism tb_decode_12bit tb_pan_lr tb_eg_roms tb_cpu_mem \
          tb_long_run; do
    iverilog -g2012 -o /tmp/$tb.vvp \
        rtl/pcm/ymf278_pcm_alu.sv rtl/pcm/ymf278_pcm_eg_step.sv \
        rtl/pcm/ymf278_pcm_engine.sv tb/$tb.sv
    vvp /tmp/$tb.vvp | grep "==="
done
```

### BASIC PCM dump (NEW2 enable 포함)
```basic
5 OUT &HC6,&H05 : OUT &HC7,&H02   ' NEW2 enable
10 DATA &H0000,&H000C,&H003C,&H0078,&H0258,&H04B0,&H0960,&H0E10,-1
20 READ H : IF H<0 THEN END
30 PRINT HEX$(H);":";
40 OUT &H7E,&H02 : OUT &H7F,&H01
50 OUT &H7E,&H03 : OUT &H7F,0
60 OUT &H7E,&H04 : OUT &H7F,H\256
70 OUT &H7E,&H05 : OUT &H7F,H AND 255
80 OUT &H7E,&H06
90 FOR I=0 TO 11 : PRINT " ";HEX$(INP(&H7F)); : NEXT
100 PRINT : GOTO 20
```

## 다음 세션이 해야 할 것

### 즉시 (commit `fb8ed1d` 빌드 후)

1. **`make build deploy` 돌려서 새 worst slack 확인**.  Timing summary 자동 출력됨.
2. 하드웨어에서:
   - OSD/키보드 둔화 개선됐는지 (slack 회복 정도에 비례)
   - PCM 잡음 변화 (잡음이 아닌 진짜 음원이 들리기 시작하면 timing이 주원인이었음)
3. `output_files/MSX1.timing_summary.txt`에서 새 top 10 path 확인:
   - 여전히 stage_a/b 계열이면 → 더 분할 필요
   - 다른 모듈 (master_accum, HF, OPL3 등)이면 → 그쪽 점검
   - slack 닫혔으면 → 잡음 추적 모드로 복귀

### 잡음이 여전히 있고 timing은 닫혔다면

이번 세션에 보류한 후보 시나리오들:
1. **노트 변경 시나리오** — 50프레임마다 wave/fn/keyon 변경 testbench (가장 유력)
2. **multi-slot 동시 재생** — slot 0,5,10 활성화
3. **12-bit 디코딩 검증** — yrw801 실데이터 형식 시뮬
4. **WAV dump 분석** — pcm_left/right를 .wav로 저장 후 Audacity

기타 정리거리:
- `opl3_reg_shadow`에 `rst_n` 추가 (NEW2 누수 fix)
- Agent 4의 pos shift (`next_pos` → `stage_a_reg.dyn.pos`): cosmetic이지만 잘 처리

### 빌드 자동화 보강 아이디어 (선택)

- `make build` 후 worst slack을 grep해서 닫혔는지 자동 판정
- CI 스타일로 testbench도 함께 실행

## 참조

- 이번 세션 이전 핸드오프: `docs/pcm_v2_session_handoff.md`
- 8-agent 리뷰 시점 task list: `docs/pcm_v2_task_list_post_8agents.md`
- openMSX 참조 구현: `rtl/peripheral/SOUND/ymf278b_fpga/reference/YMF278.cc`
- 메모리: `~/.claude/projects/.../memory/project_timing_failure.md`
