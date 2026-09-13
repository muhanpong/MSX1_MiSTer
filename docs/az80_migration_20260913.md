# T80pa/T80s → A-Z80 전환 상세 기록

시작 2026-09-13. 브랜치 `nextz80`(워크트리 readcache). 이 문서는 전환의 **모든 결정·결함·근거**를
시간순으로 남긴다. 요약이 아니라 재추적 가능한 기록이 목적.

## 0. 왜 A-Z80인가

| | T80 (v350, 퇴역 대상) | A-Z80 (Goran Devic 님) |
|---|---|---|
| 유래 | 문서 기반, 2001~, 커뮤니티 20년 | **다이 역공학** (Ken Shirriff 님 다이 판독 기반 PLA 추출) |
| T-state | 근사 | opcode별 M/T 행렬로 **정확** |
| WAIT | `T80.vhd` 자체가 깨짐 (T80pa는 CEN 차단으로 우회, T80s는 실WAIT 주입 — 21구성 상태대조로 무해 확인) | **정확** (저자 명시) |
| XF/YF | SCF/CCF 세트 실패 | **2세트 실패** (저자: "bus charge/discharge 부작용" — 어느 세트인지 미명시) |
| 클럭 | clk21m + CEN(클럭인에이블) | **실클럭 전용** — CEN 없음, 내부가 `~clk` 래치 |
| 라이선스 | 자유 | GPL 계열 (배포물 전체가 이미 오픈) |

★핵심 함정: **플래그 정확도 이득은 사실상 0임** (A-Z80도 XF/YF 일부 실패).
전환의 실제 가치는 **T-state 정확도 + WAIT 정확성**. 이걸 흐리면 판단이 오염된다.

전사(前史): T80pa의 CEN_p/CEN_n 위상쌍이 clk21m/2(10.74MHz) 천장의 원인이었고,
T80s(단상 CEN)로 21.48MHz 도달·실기검증 완료(`MSX1_20260913b_t80s.rbf`, Z80BENCH 600%).
즉 속도는 이미 해결됐고, A-Z80은 정확도 전환임.

## 1. 클럭 아키텍처 — CEN이 없는 코어를 넣는 법

A-Z80은 클럭인에이블 개념이 없다. 내부 래치가 `~clk`에 물려 있어(예: `data_pins.v`의
`dout`, `SYNTHESIZED_WIRE_1 = ~clk`) **반사이클 타이밍이 실재**한다. CEN으로 위장한
가짜 클럭을 주면 반사이클이 전부 깨진다. → 실클럭 생성이 유일한 길.

- `rtl/peripheral/az80_clkgen.sv`: clk_sdram(85.909090MHz)을 **24/16/12/8/4** 분주 →
  3.58/5.37/7.16/10.74/**21.477**MHz. `half_of()` 함수로 듀티 관리.
  분주비 변경은 **버스 유휴에서 하강엣지에 래치** — 글리치 없는 전환.
- `MSX1.sdc`: `create_generated_clock -divide_by 4` — 분주비가 가변이라 SDC로 표현
  불가하므로 **최속(/4)으로 선언**. 빠른 케이스를 제약하면 느린 케이스는 자동 포함.
  ★선언 전 첫 빌드는 worst −6.903ns / clk21m TNS −1412ns — az80_clk 플롭들이
  clk21m에 잘못 관계지어진 결과. **생성클럭은 반드시 선언부터.**
- 시뮬 `tb_az80_clkgen`: 5속도 주파수·듀티 + 전환 퍼징(최단 반주기 = /4 플로어 확인).

## 2. 결함과 수정, 시간순 전부

### 2-1. 브리지는 비문제를 풀었다 (제거됨)
az80_clk↔clk21m 스트로브 전달용 `az80_bridge.sv`를 만들었으나, 근거였던
`tb_az80_domain`의 "스트로브 유실"은 **TB 자체 버그**(`if (div4 == 2'd1)` — clk21m을
10.74MHz로 만들어놓고 잰 것; `div4[0]`이 정답). 수정 후 어떤 속도에서도 스트로브
비가시 구간 없음 → 브리지 qip 제외. ★첫 A-Z80 빌드의 "Can't fit"(ALM 70%인데
라우팅 폭주)도 브리지 제거로 해소.

### 2-2. 리셋 CDC (−13.599ns)
`reset`(FPGA_CLK2_50 계열)이 az80_clk 도메인에 직결 → 무관 도메인 worst-edge 페어링.
수정 = msx.sv에 **async-assert / sync-deassert** 싱크로나이저 + 첫 단으로의
`set_false_path`. az80_clk Fmax 20.57 → 22.10MHz.
```systemverilog
logic [1:0] az_rst_sync = 2'b11;
always @(posedge az80_clk, posedge reset)
   if (reset) az_rst_sync <= 2'b11; else az_rst_sync <= {az_rst_sync[0], 1'b0};
```

### 2-3. 피드스루 — 이 전환 최대의 결함 (빌드 2개 소모)
A-Z80은 실핀 재현이라 데이터버스가 `inout D` 하나. 래퍼가 di를 D에 싣고 do_도 D에서
읽으면 **d_to_cpu와 d_from_cpu가 CPU를 관통하는 조합 한 네트**가 된다.

- 빌드1: −8.349ns `ms_io_dout_lat(MoonSound) → SCC 웨이브테이블` — 서로 무관한 두
  블록이 CPU를 통해 연결. clk_sdram→clk21m 엣지 일치(요구 ~0ns).
- 시도1(실패): `assign do_ = wr_n ? 8'h00 : D;` — **기능적으론** 배타적(쓰기 중엔
  rd_n=1이라 di가 D에 안 실림)이나 **STA는 case analysis를 안 한다.** 두 mux를
  위상학적으로 걸어서 경로는 그대로 보고됨.
- 빌드2(ca97172): −8.125ns, 같은 경로 다른 끝점(`sdram ch2_saved_a0 → SCC datain`).
  경로 노드가 증거: `cpu_din[4] → az_di[4] → CPU|D[4] → CPU|do_[4]` (6 로직레벨).
  az80_clk Fmax도 20.08로 하락(피터가 이 경로들과 싸우느라).

**교훈: 트라이스테이트 핀 코어는 게이팅이 아니라 경계에서 단방향화가 정답.**

### 2-4. 단방향화 1차 시도 → 시뮬 회귀 → 유령 쓰기 발견
`data_pins.v`의 `dout`(이미 `~clk` 플롭)을 `D_out`으로 인출, `do_ = D_out`으로 교체
→ `tb_az80_bringup` FAIL: mem[80h]=00 (기대 37).

계측(쓰기마다 주소/데이터/oe 출력) 결과 **놀라운 원인**:
- **베이스라인도 리셋 중 유령 쓰기를 하고 있었다.** `control_pins_n.v`가
  `pin_control_oe=0`(리셋·버스그랜트) 동안 MREQ/IORQ/RD/WR를 `1'bz`로 띄움.
  Verilator 2-state는 z→0 → "쓰기 활성"으로 보임.
- 구 래퍼는 `do_ = D = di` 에코라 유령 쓰기가 **방금 읽은 값을 되쓰는** 우연한
  멱등으로 은폐됐음. 새 래퍼는 do_가 레지스터 출력이라 00을 써서 주소 0의
  `LD HL,0080` opcode를 파괴 → HL=0000 → 増상 전부 설명(mem[0]에 37이 쓰이고
  `LD A,(HL)`이 그걸 읽어 81h로 복사 → mem81만 37).
- ★실기에서도 위험한 실결함: Quartus도 내부 z를 정의하지 않음. **내 수정이 만든
  버그가 아니라 내 수정이 노출한 기존 버그.**

### 2-5. 최종 형태 (커밋 6697e64)
1. `data_pins.v` — `inout D` 폐지: `input D_in` / `output D_out`(=dout 플롭) /
   `output D_oe`(=bus_db_pin_oe). 내부버스 `db`의 트라이스테이트는 코어 안이므로 유지.
2. `z80_top_direct_n.v` — 위 3포트 + `ctl_oe`(=pin_control_oe) 인출.
3. `az80_wrapper.sv` —
   - **풀업 에뮬**: `assign mreq_n = ctl_oe ? mreq_n_pin : 1'b1;` (IORQ/RD/WR 동일).
     실보드의 풀업 저항을 mux로 재현. 유령 스트로브 원천 차단.
   - **do_ 홀드**: `dout`은 양방향이 공유하는 단일 래치(`we | re`로 로드)라 읽기가
     쓰기데이터를 덮는다. `D_oe` 창 안에서만 D_out을 내보내고 밖에서는 홀드:
     `always @(posedge clk) if (D_oe) do_hold <= D_out;`
     `assign do_ = D_oe ? D_out : do_hold;` — mux 입력이 둘 다 레지스터라 피드스루 불가.
4. 시뮬 3종 ALL PASS + **유령 쓰기 소멸**(도메인 TB wr:edges 3→2, 정확히 프로그램의
   쓰기 2발만 남음). 브링업 225클럭(실Z80 ~222T 대비 1.4%) 유지.

### 2-6. REG(211:0) 미제공 (의도)
T80은 레지스터파일 전체를 벡터로 노출(msx.sv dbg_* 약 20곳 사용). A-Z80은 레지스터가
내부 트라이스테이트 버스의 개별 reg_latch라 묶을 벡터가 없음. 20곳 전수감사 —
`booted`, `im2_tbl_hi`처럼 기능처럼 보이는 것 포함 전부 dbg 포렌식 확인 → `212'd0` 타이오프.

### 2-7. 그 외 이 과정에서 잡은 것
- `cpu_speed_q` 폭 `[1:0]` 선언 + `[2:0]` 구동 절단 — `-Wno-WIDTH`가 은폐.
- `rfrsh_n`/`rfsh_n` 오타 1글자 → 터보가드 전체 무력화(NOCE 2→203) — `-Wno-IMPLICIT`가 은폐.
  ★**-Wno- 플래그가 결함을 숨긴 2번째 사례. lint 예외는 빚이다.**
- MFRSD 21.5MHz 읽기손상 → `spi_divmmc.ready` 미배선(잠복) 노출 → `sd_pace_n` 추가.

## 3. 타이밍 여정 (수치 전부)

| 빌드 | worst setup | az80_clk Fmax | clk21m Fmax | 비고 |
|---|---|---|---|---|
| 선언 전 | −6.903 (TNS −1412) | — | — | 생성클럭 미선언 |
| 리셋 CDC 전 | −13.599 | 20.57 | — | reset 직결 |
| ca97172 | −8.125 | 20.08 | 21.84 | wr_n 게이트(무효), 피드스루 잔존 |
| **6697e64** | **−4.476** | **21.33** | **28.52** | 피드스루 소멸. 잔여=ch2_saved→dout |
| 3f66022 | −2.145 | 19.66 | 28.47 | MCP 적중(ch2→dout 소멸)했으나 az80_clk 악화 |
| 5fe9a3d | −2.698 | 19.27 | 28.67 | ★지정이 **조용히 무시됨** — 승격목록에 az80_clk 없음 |
| 5b6b9fd | −12.623 | 17.63 | 25.67 | 승격 성공(CLKCTRL_G2)했으나 **크로싱 skew −8.2로 악화** |
| e836e38 | (진행 중) | ? | ? | 경계 MCP 4클래스 |

요구: az80_clk ≥ 21.477MHz.

### 로터리의 정체 — az80_clk가 글로벌 클럭망 밖에 있었다 (5fe9a3d)
3f66022 빌드에서 ch2 위반이 사라지자 남은 worst가 코어 내부 반사이클(`ir|opcode →
apin_latch`, 예산 23.28ns)과 az80→clk21m 크로싱(**skew −3.59ns**)으로 바뀜. skew를
추적하니 fit.rpt "Global & Other Fast Signals"에:
`az80_clkgen|az80_clk ; FF_X71_Y30_N50 ; Fan-Out 409 ; Clock ; Global=NO`
— 클럭 부하 409개짜리 네트가 **일반 배선**으로 뿌려지고 있었음. 빌드마다 Fmax가
19.66/20.08/21.33/22.10을 오간 원인이 시드가 아니라 클럭 삽입지연 산포였던 것.
수정 = qsf `GLOBAL_SIGNAL GLOBAL_CLOCK` 고정. ★교훈: **레지스터 분주 클럭은 fit.rpt
글로벌 테이블부터 확인** — create_generated_clock은 STA 선언일 뿐 배선을 안 정한다.

★2차 함정(5fe9a3d): To를 `az80_clkgen:az80_clkgen|az80_clk`로 썼더니 **경고 없이 무시**
— sys_top 기준 실계층은 `emu:emu|az80_clkgen:...`이라 미매치. Global Signal 할당표에는
버젓이 실리면서 Fitter 승격 목록(Info 11178/11191)에는 없는 상태가 "무시됨"의 증거.
와일드카드 `*az80_clkgen*|az80_clk`로 교정. **판정은 할당표가 아니라 승격 Info와
Control Signals 표의 Global=yes로 할 것.**

### ch2_saved_* → dout MCP의 정당화 (3f66022)
clk_sdram과 az80_clk는 같은 PLL 분주라 0.001ns 엣지쌍 존재 → cpu_din mux 클라우드
전체를 0ns에 요구(−4.5ns). 그러나 실제 전송은:
정착 → pacer가 ready 인지(클럭드, ≥1 clk21m) → wait_n 해제(클럭드) → CPU는 nWAIT를
하강엣지에서 샘플한 뒤 **다음 하강엣지(1 T-state 뒤)에 소비**. /4에서 1 T-state=46.6ns.
→ `-setup -end 2`(예산 46.6ns), `-hold -end 1`. **ch2 읽기복귀에만 한정** — 다른
cpu_din 소스(clk21m)는 현행 페어링으로 통과하므로 넓히지 않는다.

### 크로스도메인 전수조사와 경계 MCP (e836e38)

글로벌 승격(5b6b9fd)은 성공했지만 **역효과**: 글로벌 트리 삽입지연(~4ns)이 az80_clk
런치에만 얹혀 az80→clk21m skew −8.2ns, worst −12.6. 인식 전환이 필요했다 —
**같은 PLL 그리드의 관련 클럭들은 엣지가 겹쳐서 STA가 크로스도메인에 ~0/23.3ns 창을
요구하는 게 숙명**이다. T80 시절엔 단일클럭+CE라 이 문제 자체가 없었고, 실클럭 CPU는
도메인 경계 전체에 버스 계약 기반 예외가 필수다.

quartus_sta로 5방향(az→21m/21m→az/intra/sdram→az/az→sdram) 위반 전수를 떠서
클래스가 5개뿐임을 확인:

| 클래스 | worst | 판정 근거 | 처방 |
|---|---|---|---|
| apin_latch→a8r_val | −12.6 | dbg 포렌식, 캡처조건이 IO읽기 내내(≥3T) 유효 | MCP2 |
| clk21m→dout | −6.3 | 읽기복귀: 런치≤T2, 소비=T3하강(≥1.5T=69.9ns), MCP2 예산 69.85 | MCP2 |
| **az80 내부→dout** | **−5.1** | sequencer/ir→내부 트라이스테이트 버스→dout 반사이클(23.28 예산에 ~28) | **SDC 불가, 물리** |
| clk_sdram→dout | −2.9 | ch2·MoonSound 전부 WAIT-페이스 읽기복귀 | 기존 MCP 일반화 |
| az80→speed_q | −1.5 | 분주 래치, 버스유휴 레벨안정+OSD시만 변경 | MCP2 |

★모든 MCP는 세터/홀드 = -end 2/-end 1. 홀드는 일치 엣지 유지라 양의 지연이면 자동 충족.
★남는 진짜 벽 = 코어 내부 반사이클 −5ns. 다음 수단 = LogicLock 영역(925 ALM 밀집 배치).

## 4. 검증 자산

- `sim/run_az80.sh` — ①clkgen 주파수/듀티/전환퍼징 ②bringup(DJNZ 루프+2스토어,
  225클럭) ③domain(5속도 × 도메인크로싱 + WAIT 최소폭) — A-Z80 게이트
- `sim/run_t80_state.sh` — REG 상태대조 오라클 (A-Z80은 REG 부재로 비적용;
  T80 계열 상호대조·WAIT 무죄 확정에 사용됨)
- `sim/run_t80_contract.sh` — 래퍼 간 버스 파형대조 (T80pa vs T80s에 사용)
- 실기: Z80BENCH·MFRSD/Nextor·GoFigure — T80s에서 확립한 절차 재사용 예정

## 5. 미결

- [ ] az80_clk Fmax ≥21.477 확보 (21.33에서 +0.15 필요; MCP 후 재측정 → 부족 시 시드)
- [ ] 실기: 부팅·Z80BENCH·MFRSD/VHD(21.5MHz에서 Nextor)·GoFigure·저속게임 회귀
- [ ] XF/YF 실증: ZEXALL을 실기/openMSX에서 (A-Z80 자체 실패 2세트의 정체 확인)
- [ ] `dbg_wait_ratio` 실측 (T80s 대비 A-Z80 T-state 정확화의 효과 정량화)
- [ ] 느린 장치(OPLL·SCC·FM-PAC) ÷1 실기 — 가드 창 하한 여유 0 문제는 T80s에서 이월
- [ ] busrq_n 상시 1 가정 문서화 (풀업 에뮬은 리셋 구간만 실효)

## 6. 교훈 모음 (다음 코어 교체 때 그대로 적용)

1. **CEN 없는 코어는 실클럭 + 생성클럭 선언부터.** 선언 전 타이밍 수치는 전부 무효.
2. **inout 핀은 경계에서 즉시 단방향화.** 게이팅으로 STA를 설득할 수 없다.
3. **트라이스테이트가 뜨는 컨트롤 핀은 풀업을 에뮬레이션**해야 한다. 실보드에는
   저항이 있고 FPGA 내부엔 없다.
4. **"수정 후 깨졌다" ≠ "수정이 원인"** — 에코 은폐처럼, 노출일 수 있다. 계측으로
   유령 쓰기의 존재부터 확인했기에 올바른 수정(풀업)에 도달했다.
5. 크로스도메인 위반은 **버스 프로토콜의 실제 계약**(WAIT 해제→T3 소비)으로 예산을
   유도한 뒤에만 MCP. 이름 패턴은 최소 범위로.
6. `-Wno-` 플래그 뒤에 결함이 두 번 숨었다. 새 모듈 추가 시엔 해당 플래그를 일시
   해제하고 한 번 훑을 것.
