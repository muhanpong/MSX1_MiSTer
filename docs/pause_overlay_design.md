# Pause 심벌 오버레이 — 상세설계 (A1)

기준 스펙: `docs/pause_overlay_spec.md` (2026-08-15 동결). 본 설계서는 스펙 S1–S4, C1–C5, V1–V3를
전부 충족하도록 A2(MSX1.sv 배선)·A3(debug_overlay.sv 렌더러+FSM+TB)가 그대로 구현 가능한 수준으로
확정한다. 모든 근거는 워크트리 `.claude/worktrees/ascii16x-flash` 기준 파일:라인 인용.

---

## 0. 핵심 결정 요약

1. **전 신호가 이미 CLK_VIDEO(=clk21m) 도메인** — CDC 불요 판정. 단 스펙 C1에 따라 2FF 단을
   그대로 두되 "파이프라인 겸 방어적 동기화"로 문서화 (§6).
2. **입력 이벤트 검출**: ps2_key[10]·ps2_mouse[24]는 **이벤트마다 토글** (소스 확인, §1) → XOR 검출.
   joy0/joy1은 [5:0] 전 비트 디지털(아날로그 없음, §2) → 6'h3F 전 비트 부등 비교.
3. **좌표계**: h_cnt 스케일이 VDP 모드에 따라 1 count/px(vdp18) vs **2 count/px(V9938)**로 다름 (§3).
   외부 모드 신호 추가 없이 **라인 폭 자기측정**(line_w = hblank 상승 시 h_cnt 래치)으로
   `wide = (line_w ≥ 384)` 도출, 심벌 X를 wide로 스케일. 신규 포트 6개로 억제 (C2/C3 충족).
4. **심벌**: 표시픽셀 좌표 고정 — 막대1 x∈[228,232), 막대2 x∈[236,240), y∈[28,43];
   검정 배경 박스 x∈[226,242), y∈[26,45] (임의 배경 위 가시성 보장). wide=1이면 x만 2배.
5. **상태기계**: 명시적 3상태 FSM과 등가인 **5비트 재장전 카운터**로 구현 (S2 그대로, §5).
   우선순위: pause OFF 클리어 > OSD 열림 상시재장전 > 입력 재장전 > vblank 감쇠.

---

## 1. 조사 ①: ps2_key[10] / ps2_mouse[24] 토글 시맨틱 (소스 확인, 추측 아님)

`sys/hps_io.sv` — HPS SPI 트랜잭션 종료 시점(`~io_enable`) 처리:

```
298:  if(~io_enable) begin
299:     if(cmd == 4 && !ps2skip) ps2_mouse[24] <= ~ps2_mouse[24];
300:     if(cmd == 5 && !ps2skip) begin
301:        ps2_key <= {~ps2_key[10], pressed, extended, ps2_key_raw[7:0]};
```

- **ps2_key[10]**: 키보드 이벤트 트랜잭션(cmd==5)이 완결될 때마다 **무조건 반전**(press·release·
  autorepeat 모두). 값이 아니라 "새 이벤트 도착" 표식. → 변화 검출 = 연속 샘플 XOR.
- **ps2_mouse[24]**: 마우스 패킷(cmd==4) 완결마다 반전. 동일 패턴.
- 예외: `ps2skip`(hps_io.sv:266, 367–368, 384–385) — HPS가 데이터 바이트 상위 8비트를 0xFF로
  보낸 트랜잭션은 토글이 억제된다(무효/스킵 패킷). 즉 **토글 = 유효 이벤트 1건**, 오탐 없음.
- 도메인: `always @(posedge clk_sys)` 블록 내부, clk_sys는 MSX1.sv:320에서 `clk21m` (§4).

## 2. 조사 ②: joy0/joy1 비트 구성 — 변화감지 마스크

- 선언: `MSX1.sv:213` `wire [5:0] joy0, joy1;` — hps_io의 32비트 joystick_0/1 중 하위 6비트만 수취
  (`MSX1.sv:330-331`). 아날로그 스틱 포트(joystick_l_analog 등)는 **미접속**.
- 비트 의미 (rtl/msx.sv:386):
  `joy_a = {~joy0[5], ~joy0[4], ~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]}`
  → **[0]=Right, [1]=Left, [2]=Down, [3]=Up, [4]=Trigger A, [5]=Trigger B**. 전부 모멘터리 디지털.
- **결정: 안전 마스크 = 전 비트 6'h3F** (아날로그·토글류 비트 없음 → 오탐 원천 없음).
  변화 검출 = `(joy0_q2 != joy0_q3) || (joy1_q2 != joy1_q3)` (§6의 파이프라인 단 사이 비교).

## 3. 조사 ③: h_cnt/v_cnt 스케일과 심벌 좌표 확정

### 3.1 debug_overlay 픽셀 카운터 (rtl/debug_overlay.sv:108–120)

- `h_cnt`: hblank 중 0으로 리셋, `ce_pix && !hblank`인 클럭마다 +1 → **비블랭킹 구간의 ce_pix 틱 수**.
- `v_cnt`: vblank 상승에서 0, 이후 "hblank 하강 && !vblank"마다 +1 → **가시 라인 번호** (모드 불문 1 count/라인).

### 3.2 ce_pix의 모드별 정체 (rtl/msx.sv:474)

```
assign ce_pix = vdp18 ? ce_5m39_n : ~DHClk_vdp;
```
- `vdp18 = (bios_config.MSX_typ == MSX1)` (rtl/msx.sv:458) — TMS9918 경로.
  `ce_5m39_n = ~clkdiv4[1] & clkdiv4[0]` (rtl/peripheral/clock.sv:45) = 4클럭 중 **1클럭 펄스**
  → h_cnt는 **1 count / 픽셀** (5.37MHz 도트).
- V9938/V9958 경로: `~DHClk`. DHClk는 vdp_ssg.vhd:211–245의 FF_VIDEO_DH_CLK — 도트당 4클럭
  (FF_DOTSTATE 00→01→11→10) 동안 1,0,1,0로 **매 클럭 토글하는 10.74MHz 구형파**.
  ~DHClk는 4클럭 중 2클럭 high → h_cnt는 **2 count / 픽셀** (512폭 하이레즈 도트 단위).

### 3.3 hblank 창 폭 (h_cnt 최종값 = line_w)

| 모드 | 근거 | 가시폭 (h_cnt counts) |
|---|---|---|
| vdp18, Border=No, 그래픽(SCR1/2/3) | vdp18_col_mux.vhd:179 `hblank_n_o <= hor_active_i` → 표시영역만 | **256** |
| vdp18, Border=No, 텍스트(SCR0) | 동일, 텍스트 표시폭 240 (vdp18_pack-p.vhd:41 last=239) | **240** |
| vdp18, Border=Yes | vdp18_hor_vert.vhd:164–168 hblank ⊤@-72, ⊥@-14; 카운터 -86..255(graph, pack-p.vhd:43-44) → 14(좌보더)+256+14(우보더) | **284** |
| V9938, Border=No | vdp.vhd:1258 `FF_HBLANK <= NOT WINDOW_X` → 표시 256도트 ×2 | **512** |
| V9938, Border=Yes | vdp.vhd:1200–1205 BWINDOW_X: H_CNT 200..1366 (CLOCKS_PER_LINE=1368, vdp_package.vhd:116) = 1167 clk ≈ 291.7도트 ×2 | **≈583** |

(msx.sv:476–482 `hblank_vdp_cor`는 V9938 hblank 해제를 도트 경계(DHClk&DLClk)로 정렬 — 위상 정렬일 뿐 폭 불변.
V9938 보더는 좌≈7도트/우≈29도트로 비대칭: 표시 시작 H_CNT≈228 (OFFSET_X=49, vdp_package.vhd:119 주석 기준 역산 ±1도트).)

### 3.4 스케일 자기측정과 좌표 확정

- **line_w 래치**: hblank 진입 순간의 h_cnt (h_cnt≠0 && hblank 조건으로 라인당 1회 캡처).
- **wide = (line_w ≥ 11'd384)** — 위 표에서 vdp18 계열(240~284)과 V9938 계열(480~583)을
  완벽 분리. 384 비교는 `line_w[10] | (line_w[9]&line_w[8])` 1 ALM.
- **X 좌표 (표시픽셀 px 단위, h_cnt = px << wide)**:

| 요소 | px 범위 | h_cnt (vdp18) | h_cnt (V9938) |
|---|---|---|---|
| 배경 박스 | [226, 242) | [226,242) | [452,484) |
| 막대 1 (좌) | [228, 232) | [228,232) | [456,464) |
| 간격 | [232, 236) | — | — |
| 막대 2 (우) | [236, 240) | [236,240) | [472,480) |

  판정식: `px = h_cnt >> wide` 후 상수 비교 (또는 등가로 h_cnt를 `상수<<wide`와 비교 — 구현 자유).
- **Y 좌표 (v_cnt, 모드 공통)**: 배경 박스 **[26, 45]**, 막대 **[28, 43]** (16라인 높이 = 스펙 ~16px).
- 스펙 S3 검증:
  - Y 28..44 밴드 내 (막대 28..43 ✓; 박스 상단 26은 여유 2라인 — 최악 vcrop 20라인에도 26>20 생존 ✓).
  - X 우측 사분면(표시픽셀 192..255) 내 ✓: 막대 228..239.
    - Border=Yes(vdp18)일 때 h_cnt 원점이 좌보더로 14px 이동 → 막대는 표시영역 기준 214..225
      = 여전히 우사분면, 우보더에서 30px 이상 안쪽 (보더 불확실성 회피 ✓).
    - V9938+Border: 좌보더 ≈7도트 → 표시 기준 ≈221..232 ✓.
    - SCR0 텍스트(240px): 막대2가 236..239로 마지막 유효열 239에 정확히 안착 ✓ (박스 우측 240..241은
      hblank 게이트로 자연 클리핑, 막대 무손실).
  - 기존 패널과 비겹침 ✓: 패널 h_cnt < 66 (debug_overlay.sv:123 PW=66), 심벌 h_cnt ≥ 226 (최소 모드 기준).
    참고: PW=66은 vdp18 화면에서 66px, V9938 화면에서 33px 폭에 해당(2 count/px) — 어느 쪽이든 비겹침.
  - OSD 중앙박스: OSD는 세로 중앙(≈라인 56 이후) 배치이므로 y≤45 심벌과 비겹침. 또한 OSD는
    다운스트림(sys_top의 osd 모듈, 스케일 후단)에서 합성되므로 겹쳐도 OSD가 위에 그려질 뿐 무해.

## 4. 조사 ④⑤: 배선 경로와 클럭 도메인

- `assign CLK_VIDEO = clk21m;` — **MSX1.sv:609**. PLL outclk_1 = 21.477270MHz (MSX1.sv:383).
- hps_io는 `.clk_sys(clk21m)` — **MSX1.sv:320** → ps2_key(11b, MSX1.sv:211), ps2_mouse(25b, :212),
  joy0/joy1(:213), status(:210) 전부 clk21m 도메인 레지스터 출력.
- `OSD_STATUS`: emu 입력 포트(MSX1.sv:172) ← sys_top.v:1817 ← osd 모듈 출력(sys_top.v:1378).
  osd.v:21,74–75에서 `always@(posedge clk_sys)` 레지스터. sys_top의 clk_sys는 HPS_BUS[36]을 통해
  코어의 clk_sys와 동일 네트 (hps_io.sv:187 `assign HPS_BUS[36] = clk_sys;`, sys_top.v:1722 언패킹)
  = **clk21m**. → OSD_STATUS도 clk21m 도메인.
- `msx_pause`: **MSX1.sv:456** `wire msx_pause = nvbak_dma_active | dump_active | (status[43] & OSD_STATUS) | pause_toggle;`
  — 모든 항이 clk21m 레지스터(pause_toggle: MSX1.sv:440–445)의 조합 OR. clk21m 도메인 조합 신호.
- debug_overlay 인스턴스: **MSX1.sv:646–684** `u_overlay`, `.CLK_VIDEO(CLK_VIDEO)`.

**결론: 신규 6개 입력 전부 소스 도메인 == 소비 도메인 == clk21m == CLK_VIDEO. 진짜 CDC는 존재하지 않는다.**

## 5. 신호 배선표 (A2 작업 명세)

MSX1.sv `u_overlay` 인스턴스(646행)에 아래 6포트 연결 추가. **이외 MSX1.sv 변경 없음**
(CONF_STR 불변, T[44] 시맨틱 불변 — C3 충족).

| debug_overlay 신규 포트 | 폭 | MSX1.sv 연결 | 소스 도메인 | 성격 |
|---|---|---|---|---|
| `pause_in`     | 1 | `msx_pause` (MSX1.sv:456) | clk21m (조합 of regs) | 레벨 |
| `osd_in`       | 1 | `OSD_STATUS` (포트 :172) | clk21m (osd.v:74) | 레벨 |
| `key_tgl_in`   | 1 | `ps2_key[10]` (:211) | clk21m (hps_io.sv:301) | 이벤트 토글 |
| `mouse_tgl_in` | 1 | `ps2_mouse[24]` (:212) | clk21m (hps_io.sv:299) | 이벤트 토글 |
| `joy0_in`      | 6 | `joy0` (:213) | clk21m (hps_io) | 레벨 벡터 |
| `joy1_in`      | 6 | `joy1` (:213) | clk21m (hps_io) | 레벨 벡터 |

## 6. CDC 계획

**판정: clk21m == CLK_VIDEO (MSX1.sv:609)이므로 메타스테이빌리티 관점 CDC 불요.**
단, 스펙 C1이 2FF를 요구하므로 다음과 같이 구현·문서화한다:

- 6개 입력 모두 debug_overlay 내부에서 기존 스타일(debug_overlay.sv:46–52 참조) 그대로
  `_q1 → _q2` 2단 레지스터 통과. 동일 클럭이므로 이는 **순수 2사이클 파이프라인**으로 동작
  (기능 영향: 이벤트 반응이 2 clk21m ≈ 93ns 지연 — 프레임 단위 타이머에 무의미).
- 변화/엣지 검출은 `_q2`와 3단째 `_q3`(prev) 사이에서 수행:
  - `osd_fall = osd_q3 & ~osd_q2` … (아래 FSM은 레벨 재장전 방식이라 실제로는 불사용, 참고용)
  - `input_evt = (key_q2^key_q3) | (mouse_q2^mouse_q3) | (joy0_q2!=joy0_q3) | (joy1_q2!=joy1_q3)`
- **다중비트(joy) 부등 비교가 안전한 이유 = 동일 클럭 도메인이기 때문** (비트 간 스큐로 인한
  중간값 샘플링이 원리적으로 불가). 만약 향후 CLK_VIDEO가 clk21m과 분리되면 joy 비교는
  소스 도메인 토글화 또는 그레이/핸드셰이크로 재설계해야 함 — 코드 주석에 명기할 것 (A3).
- vblank/hblank는 이미 CLK_VIDEO 동기 신호(기존 코드가 동기 사용 중) — 추가 처리 없음.

## 7. 상태기계 (스펙 S2 그대로)

개념 FSM (모두 CLK_VIDEO, 프레임 틱 = vblank 상승 = `!vblank_prev && vblank`, C5 — 기존
debug_overlay.sv:89–92 패턴 재사용):

```
상태: HIDDEN / SHOW_OSD / SHOW_TIMED(cnt=18..1)

HIDDEN     --(pause_q2 & osd_q2)--------------------> SHOW_OSD
HIDDEN     --(pause_q2 & input_evt)-----------------> SHOW_TIMED(18)
SHOW_OSD   --(osd_q2 하강, pause 유지)---------------> SHOW_TIMED(18)   // S2: 닫힘 → 18프레임
SHOW_OSD   --(~pause_q2)----------------------------> HIDDEN           // 즉시 소멸
SHOW_TIMED --(input_evt | osd_q2 재상승)-------------> 재장전/SHOW_OSD  // S2: 재표시
SHOW_TIMED --(frame_tick, cnt=1→0)------------------> HIDDEN           // 0.3s@60Hz 소멸
SHOW_TIMED --(~pause_q2)----------------------------> HIDDEN           // 즉시, 타이머 클리어
```

**구현 등가형 (권장)** — 상태 레지스터 없이 5비트 카운터 `hold_cnt[4:0]` (초기값 0) 하나:

```
우선순위 if-else (매 CLK_VIDEO):
  1) if (!pause_q2)                  hold_cnt <= 0;          // pause OFF → 즉시 소멸+클리어
  2) else if (osd_q2)                hold_cnt <= 18;         // OSD 열림 = 상시 재장전
                                                             //  → 닫힘 순간 자동으로 18부터 감쇠
  3) else if (input_evt)             hold_cnt <= 18;         // 입력 이벤트 재장전
  4) else if (frame_tick && |hold_cnt) hold_cnt <= hold_cnt - 1;

symbol_on = pause_q2 && (osd_q2 || |hold_cnt);
```

등가성: (2)가 OSD 열림 내내 18을 유지하므로 "OSD 1→0 엣지 → 18프레임 표시"가 별도 엣지 검출
없이 성립. `symbol_on`의 `pause_q2 &&` 게이트가 pause OFF 즉시 소멸을 조합적으로도 보장
(카운터 클리어는 다음 클럭이지만 표시는 당 클럭부터 꺼짐).

렌더 합성 (debug_overlay.sv:157 always_comb 확장):
```
in_sym  = symbol_on && !hblank && !vblank && (v_cnt in [26,45]) && (px in [226,242))
bar     = (v_cnt in [28,43]) && (px in [228,232) || px in [236,240))   // px = h_cnt >> wide
if (in_sym) {R,G,B}_out = bar ? 8'hFF,FF,FF : 8'h00,00,00;
```
기존 `in_panel` 블록과 **완전 독립** if (S4). 영역 비겹침 확인 §3.4. `en`(status[48]) 미사용.
주의: 기존 `drew_this_line`(debug_overlay.sv:112,118,129)은 세트되는 곳이 없는 사문 플래그 —
건드리지 말 것(무침습 원칙).

## 8. ★양방향 불변식표 (스펙 '필수 산출' 전 모드)

표기: 심벌⊕=표시, ⊖=비표시. 모든 행은 "그 모드에서 이것이 성립해야 하고, 성립하지 않으면 버그"의
양방향(충분⇔필요) 계약이다.

| # | 모드/시나리오 | 기대 거동 (⇔ 역방향 위반 시 버그) |
|---|---|---|
| I1 | 리셋 직후 (FPGA 로드/코어 리셋) | hold_cnt 초기값 0, 심벌⊖. 단 리셋 중에도 pause 조건(예: status[43]&OSD 열림)이 참이면 ⊕ — 심벌은 pause 상태의 충실한 미러이며 리셋에 별도 게이트 없음. 픽셀 경로는 통과(무변조). |
| I2 | pause OFF, 정상 플레이 | 항상 ⊖. `{R,G,B}_out == {R,G,B}_in` 비트 동일 (in_sym=0 → 변조 0). 키/마우스/조이 연타에도 ⊖ (input_evt는 pause_q2 게이트 하위). |
| I3 | pause ON + OSD 열림 | 상시 ⊕ (osd_q2 레벨). OSD가 열려 있는 한 프레임 경과 무관 유지. hold_cnt는 18 고정 재장전. |
| I4 | OSD 닫힘 직후 (pause 유지, 예: T[44] 수동 pause) | 닫힘 순간부터 18 frame_tick 동안 ⊕ 유지 후 ⊖. NTSC 60Hz ≈ 0.30s. |
| I5(※게이트 해제로 개정, 스펙 C3 각주 참조) | 0.3s 경과 후 (pause 유지, 무입력) | ⊖. pause 상태·오디오 뮤트·ce 게이트 등 기존 경로 일절 불변(오버레이는 읽기 전용 탭). |
| I6 | 입력 연타 (pause ON, OSD 닫힘) | 각 이벤트(키 press/release 각각, 마우스 패킷, joy 비트 변화)마다 18 재장전 → 연타 동안 연속 ⊕, 마지막 이벤트 후 ≈0.3s에 ⊖. ps2skip 패킷은 재장전하지 않음(§1). |
| I7 | OSD 재열림 (SHOW_TIMED 중 또는 ⊖ 상태에서) | 즉시 ⊕ (레벨 조건, 엣지 불요). 닫으면 다시 I4. |
| I8 | unpause 순간 (어느 상태에서든) | 즉시 ⊖ (당 클럭 조합 게이트), hold_cnt 클리어. 특례: status[43](Pause on OSD)만으로 pause된 경우 OSD 닫힘=unpause이므로 18프레임 잔상 없이 즉시 ⊖ — 스펙 S2 "pause OFF → 즉시 소멸"이 우선. |
| I9 | status[48]=0 (디버그 패널 OFF) | 심벌 기능 완전 정상 (자체 enable, S4). 패널 픽셀은 일절 출력되지 않음. |
| I10 | status[48]=1 (패널 ON) 조합 | 패널(좌상단, h_cnt<66)과 심벌(우상단, h_cnt≥226) 동시 표시, 영역 비겹침 → 상호 간섭 0. |
| I11 | 50Hz PAL | 18 frame_tick = 0.36s — 스펙 명기 허용 오차. 그 외 거동 동일 (frame 기준 설계라 주파수 파라미터 없음). |
| I12 | vcrop ON (최악 20라인 크롭) | 막대 y 28..43, 박스 y 26..45 → 상단 20라인 크롭에도 전체 생존·표시 (26>20). vcrop OFF: 동일 좌표 그대로 ⊕. |
| I13 | 스캔더블러/HQ2x 경로 | 오버레이는 video_mixer(MSX1.sv:686) 상류에서 픽셀 변조 → 스캔더블·스무딩이 심벌에도 동일 적용, 위치/비율 불변. HQ2x의 에지 스무딩은 외곽 1px 코스메틱 영향만. |
| I14 | vdp18(MSX1 머신) 각 화면모드 | SCR1/2/3(256px): 막대 px 228..239 ⊕. SCR0(240px): 막대2가 열 236..239로 표시폭 내 ⊕ (박스 우측 여백만 클리핑). |
| I15 | V9938/V9958(MSX2 머신·status[42]) | line_w≥384 → wide=1 자동 감지, h_cnt 2배 스케일 보정으로 화면상 동일 위치·폭 ⊕. |
| I16 | Border 옵션 on/off (status[41]) | line_w 256↔284 (512↔583) 변화하나 좌표는 h_cnt 가시원점 기준 고정 → 보더 ON 시 심벌이 표시영역 기준 좌로 14px(V9938 ≈7px) 이동할 뿐 항상 우사분면·표시영역 내 ⊕. |
| I17(※동일 개정 적용) | 일반 게임(비pause) 장시간 구동 | 픽셀 경로 무변조(I2), 신규 로직은 기존 신호에 write 없음 — V3① "일반 게임 무영향"의 설계 근거. |

## 9. ALM 추정 (예산 ≤150, C4)

| 구성요소 | 내용 | 추정 ALM |
|---|---|---|
| 동기/파이프라인 FF | (1+1+1+1+6+6)비트 ×3단 = 48 FF | ~24 (FF 패킹) |
| 이벤트 검출 | XOR 2개 + 6b 부등비교 2개 + OR | ~8 |
| hold_cnt | 5b 카운터 + 우선순위 제어 | ~6 |
| line_w 래치 + wide | 11b 레지스터 + 캡처 게이트 + ≥384 판정 | ~7 |
| 좌표 비교기 | px 시프트 + X 상수비교 4개(11b) + Y 비교 2개(8b) | ~22 |
| 픽셀 먹스 확장 | in_sym/bar → RGB 24b 먹스 추가단 | ~12 |
| **합계** | | **~79 ALM** (예산 53%) |

크리티컬 패스: 모든 비교기는 레지스터드 신호(h_cnt, v_cnt, line_w, hold_cnt) 입력 →
1단 조합 후 video_mixer로. CLK_VIDEO=21.5MHz(주기 46.5ns)라 여유 극대. 신규 로직은
clk_sdram(85.9MHz) 크리티컬 도메인과 무관 — C4 충족.

## 10. 리스크와 완화

| 리스크 | 영향 | 완화 |
|---|---|---|
| R1. V9938 h_cnt 2 count/px 미보정 시 심벌이 화면 중앙 좌측에 절반 크기로 표시 | 위치/크기 오류 | line_w 자기측정 wide 스케일 (§3.4). TB에 line_w=512 시나리오 포함 권장 |
| R2. V9958 R25/R26 수평 스크롤·마스크로 WINDOW_X 폭 변동 → line_w 요동 | 심벌 수px 흔들림 (코스메틱) | 좌표가 가시원점+상수라 폭 변동에 둔감. wide 문턱 384는 240~284/480~583 양 군집 중앙 — 오판정 여지 없음 |
| R3. joy 다중비트 비교가 "CDC"로 오해되어 향후 클럭 분리 시 오탐 | 잠재 버그 | §6 명기: 동일 도메인 전제 조건을 A3가 코드 주석으로 박제 |
| R4. OSD 열림 중 HPS가 키 이벤트를 코어로 전달하지 않는 펌웨어 동작 변화 | 없음 (OSD 열림 중엔 레벨 표시) | symbol_on이 osd_q2 레벨 우선이라 무영향 |
| R5. 검정 박스가 스펙 S1(막대 2개)에 없는 추가 요소 | 스펙 해석 | 임의 배경(흰 화면) 위 가시성 보장용 최소 확장. 리뷰(A4)에서 이견 시 박스만 제거해도 나머지 설계 불변 |
| R6. SCR0(240px)에서 박스 우측 2px 클리핑 | 코스메틱 | 막대는 무손실(§3.4). 허용 |
| R7. line_w 미초기화 첫 프레임 | 첫 1~2라인 심벌 오위치 | line_w 초기값 256 선언 + 어차피 pause 전 표시될 일 없음 (hold_cnt=0) |
| R8. 기존 경로 회귀 (한 always_comb 안에 로직 추가) | 최악=심벌 이상(스펙 배경 명기) | in_sym 게이트가 pause_q2를 포함 → 비pause 시 문자 그대로 무변조 (I2). in_panel 블록 뒤 독립 if로 배치 |

## 11. 검증 게이트 이행 지침 (A3용 요약)

- **V1 TB (iverilog, 병합 전제)**: CLK_VIDEO 자유 주파수, vblank/hblank 인공 생성(라인당 h 가시
  256틱, ce_pix=매클럭 1펄스 vdp18형). 시나리오: ①OSD 1→0 후 정확히 18 frame_tick 유지·19번째 소멸
  ②SHOW_TIMED 중 key/mouse/joy 각 1이벤트 재장전 ③unpause 즉시 소멸+카운터 클리어 ④OSD 재열림 즉시
  표시 ⑤pause OFF 중 입력 연타에도 불표시. 관측은 계층 참조(`dut.symbol_on`, `dut.hold_cnt`) +
  심벌 좌표 픽셀 샘플 병행. (선택) line_w=512 주입으로 wide 스케일 확인.
- **V2 리뷰 렌즈 대응 근거**: 토글 시맨틱 §1 (hps_io.sv:299,301 인용), status[48]=0 동작 I9,
  CDC §6 (불요 판정+2FF 유지), joy 아날로그 부재 §2.

## 12. 구현 분담 (재확인)

- **A2 (MSX1.sv)**: §5 표의 6포트 연결 1블록 추가만. 다른 행 불변. diff ≈ 8줄.
- **A3 (debug_overlay.sv)**: 포트 6개 추가, §6 동기단, §7 카운터+렌더, §3.4 좌표 상수, §11 TB.
  기존 코드 수정 없음(추가만). `default_nettype none` 유지.
