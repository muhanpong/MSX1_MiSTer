# OPL4 PCM 재제작 — 지켜야 할 동작 사양 (P0)

작성 2026-10-24, 기준 커밋 b90a9d4 (브랜치 opl4_scratch). 새 엔진은 아래 항목을 **그대로 지키거나, 바꾸면 그 항목의 게이트를 의도적으로 바꾼다**.
경로 약어: `E` = `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv`, `R` = `.../rtl/ymf278b_regs.sv`,
`T` = `.../rtl/ymf278b_top.sv`, `A` = `.../rtl/pcm/ymf278_pcm_alu.sv`, `M` = `rtl/msx.sv`,
openMSX = `~/data/openmsx_v9968/src/sound/` (`YMF278B.cc`, `YMF278.cc`, `YMF262.cc`).

검증 수단 (모두 `.claude/skills/opl4-harness/scripts/harness.sh`):

| 게이트 | 무엇 | 시나리오/뮤턴트 위치 |
|---|---|---|
| `oracle` | golden 모델 자체가 "openMSX + C절의 차이"인지: ref278(openMSX 포트)에 C절 플래그를 다 켜면 모든 시나리오에서 모델과 바이트 일치, 플래그 하나라도 빼면 시나리오가 달라짐 | `sim/golden/ref278.cpp` (`REF_OMSX=1 REF_DEV=...`) |
| `golden` | 슬롯 출력 샘플, 128.86 MHz(PIPE 경로), SDRAM 지연 1·20, 비트 일치(지연 0, ±1도 불허) | `sim/golden/gen_pcm_testdata.py`의 `sc_*` 21개 + `sc_songchange24`(24보이스, 지연 1만), 모델 `golden_pcm_omsx.py` |
| `load` | 무거운 부하(24보이스 + 한 프레임 96회 쓰기)를 지연 6·10·20에서 비트 일치. **현행 엔진은 FAIL**(H4) | `sc_songchange24` |
| `mutants` | golden이 실패할 수 있음 | `mutants/make_engine2_mutants.py` 20개 |
| `cpuvis` | CPU 가시 동작, 접근 하나하나를 openMSX 모델과 같은 클럭에서 비교 | `sim/cpuvis/` (op 스크립트 `cpuvis_ops.py`, 모델 `cpuvis_check.py`), 뮤턴트 `mutants/make_cpuvis_mutants.py` engine2 16개 / engine3 32개. 판정한 검사 키 목록이 엔진별 기준(`sim/cpuvis/checks_baseline.txt` engine2, `checks_baseline_engine3.txt` engine3, 각 2627개)과 같아야 함. 엔진이 "CPU write queue overflow"를 내면 FAIL |
| `reset` | 레지스터 파일 리셋 쓸기: cpuvis warm reset을 엔진의 최소 길이로 돌리면 PASS, 그보다 짧으면 FAIL이어야 함. engine2 24 clk / 16 clk, engine3 240 clk / 239 clk(정확히 1개 실패: 마지막에 쓸리는 7Fh) | `sim/cpuvis/cpuvis_ops.py` `G-RESET` 블록, `RESET_LEN` |
| `busylat` | H12: cpuvis를 SDRAM 쓰기 지연 150·300 clk(`WLAT`)으로 돌려 트리는 PASS, engine3의 "쓰기가 포트를 떠날 때까지 BUSY"를 없앤 뮤턴트(`--busylat`)는 FAIL. 읽기 지연은 6 그대로(H13) | `run_cpuvis.sh` `WLAT`, `tb_cpuvis.sv` `+wlat`, `cpuvis_check.py` `HOLDS_WRITE` |
| `stress` | MLAB 레지스터 파일: 슬롯 읽기 순간의 쓰기, warm reset, reset 길이 | `sim/lockstep/run_stress.sh` (자체 뮤턴트 4개 + reset_len=8) |
| `memwr` | fullsys R800 OTIR 1024바이트 업로드 + 읽어 비교. fullsys 생성 소스(`prep.sh` 출력)를 매 실행 시험 트리에서 새로 만들고, `GEN`이 트리 밖이거나 파일 목록이 트리 밖을 읽으면 FAIL. PASS 줄에 트리 커밋(`git status --porcelain`이 비어 있지 않으면 +dirty, 추적 안 된 파일 포함), 생성 소스 해시, 엔진+regs 해시, 빌드가 읽은 W 안 소스 전부(top 포함)의 해시. 로그 줄의 `MEM_WRITE_DELAY`는 실효값(engine3면 top의 107). 엔진이 "queue overflow"를 내면 FAIL. `ENGINE`/`REGS` 파일이 트리 밖이면 0 errors여도 FAIL(대조군은 오류 수를 그대로 보고) | `assets/mprobe_r.hex`, 대조 `MEM_WRITE_DELAY 0`, 엔진 뮤턴트(reg 6 주소 증가 없음), 다른 트리의 `GEN` |
| (모든 게이트) | `XFAIL="gate=<정규식>"`: 그 사유로 FAIL하면 `GATE <이름> XFAIL`(실행은 통과), PASS하면 XPASS, 다른 사유로 FAIL하면 FAIL. engine2 기본값은 `load`(sc_songchange24 지연 6·10·20 셋 다)와 `resource`(오래된 fit 보고서) | `harness.sh` 머리 |
| `resource` | fit 보고서 ALM과 M10K(PCM ≤ 6, MoonSound ≤ 20; 열은 머리줄의 "M10Ks"로 찾음). 보고서가 MoonSound RTL보다 오래됐거나, map 보고서가 없거나, `u_pcm`의 모듈이 시험 중인 엔진이 아니면 FAIL. 타이밍은 보지 않는다(PASS 줄에 "timing not judged"); 보고서 경로는 실제 경로로 풀어 트리 밖이면 표시 | — |

아래 표의 "검증" 열은 그 항목을 덮는 시나리오(`sc_*`, cpuvis op 블록 이름 `C-*`/`D*`)와 그 항목이 깨지면 잡히는 뮤턴트(`mut_*`)다.

## A. CPU 가시 동작 (MoonSound 포트)

| ID | 동작 | 현행 근거 | openMSX 근거 | 검증 |
|---|---|---|---|---|
| C-PORT | 7Eh = wave 레지스터 선택, 7Fh = wave 데이터, C4h/C6h = FM 뱅크 0/1 선택, C5h/C7h = FM 데이터, C4h/C6h 읽기 = 상태 | R:217-260, 286-318 | YMF278B.cc:69-199 | cpuvis 전체 |
| C-NEW2 | NEW2(FM 105h bit1)=0이면 7Eh/7Fh **쓰기**는 무시(BUSY도 안 섬), **읽기**는 정상 동작 | R:223, 256-258; T:105 | YMF278B.cc:142, 175-178, 77-81 | cpuvis C-NEW2; `mut_new2_gate` |
| C-ID | NEW2를 세운 뒤 첫 상태 읽기에 02h 한 번(장치 ID). 상태 읽기가 소비 | R:166-169, 307-312; M:1765-1782(직접 상태 경로, 읽기 시작 시점 값 고정) | YMF262.cc:1103-1110, 1474-1480 | cpuvis C-ID; `mut_sig_noclear`. 재무장 규칙은 D5 |
| C-STATUS | 상태 = FM 상태 \| LD<<1 \| BUSY. BUSY = 마지막 접근의 지연이 남음 **또는** 엔진 CPU 메모리 연산 진행 중 | R:131-141 | YMF278B.cc:206-212 | cpuvis C-BUSY, C-LD; `mut_st_noload` |
| C-BUSY | 접근별 BUSY 길이: FM 선택/쓰기 56, wave 선택/쓰기 88, 메모리 읽기(래치 3..6) 38, 메모리 쓰기(래치 3..6) 1024. 새 접근은 카운터를 **덮어씀**(짧아질 수 있음) | R:64-83, 219-252, 284 | YMF278B.cc:14-32, 145-162, 184-192, 81-91 | cpuvis C-BUSY; `mut_wr_busy_short`. 단위·메모리 쓰기 값은 D1, D2 |
| C-LD | 래치 08h..1Fh(웨이브 번호)에 쓰면 LD 10000 | R:228-229 | YMF278B.cc:149-151, 39 | cpuvis C-LD; `mut_ld_none`, `mut_st_noload` |
| C-REG2 | reg 2 읽기 = `001` + 쓴 값 bit4:0 (wavetblhdr, 메모리 타입, 메모리 접근 모드) | E:1723; T:268 | YMF278.cc:777-778, 708-714 | cpuvis C-REG2; `mut_id_bits`, `mut_tblhdr_bits` |
| C-LATCH | 7Eh 읽기는 FFh | R:274-277 | YMF278B.cc:74-75 | cpuvis C-REG2; `mut_latch_rd` |
| C-REG3 | reg 3 읽기는 bit5:0만(위 2비트 0) | E:1546 | YMF278.cc:716-727 | cpuvis C-REG3; `mut_reg3_nomask` |
| C-MEMW | reg 3/4/5 = 주소 A21..0, reg 6 쓰기 = 그 주소에 쓰고 +1 | E:1680-1705; R:236-241 | YMF278.cc:733-748 | cpuvis C-MEMW; `sc_memhit`(재생 중 캐시된 워드에 쓰기); memwr |
| C-MEMR | reg 6 읽기 = 그 주소의 바이트, 읽은 뒤 +1 | E:1686, 1702, 1716-1721; T:268-271 | YMF278.cc:759-786 | cpuvis C-MEMR; `mut_rd6_noinc`. 반환값의 출처는 D7 |
| C-SLOTRD | 08h..F7h 읽기 = 마지막으로 쓴 바이트(필드 4 bit5 포함). 헤더 로드가 채운 필드 5-9는 헤더 값 | E:1514-1553 | YMF278.cc:756, 788-789, 610-615 | cpuvis C-SLOTRD, C-HDR; `mut_f4_enc`, `mut_hdr_nobackfill` |
| C-PLAIN | 00h..07h, F8h..FFh는 쓴 값 그대로 읽힘(reg 3 마스크 제외) | E:1530-1548 | YMF278.cc:756, 788-789 | cpuvis C-MIX |
| C-FMRD | FM 데이터 포트 읽기 = 래치 주소(원래 값, 뱅크 포함)에 마지막으로 쓴 값. OPL2 모드(105h bit0=0)에서는 뱅크 1 쓰기가 뱅크 0에 들어가고 105h만 예외 | R:100-108, 245-247, 314-317 | YMF262.cc:1025-1042 | cpuvis C-BUSY(C5h), C-OPL2; `mut_fm_rd_remap` |
| C-RESET | warm reset: 래치, BUSY/LD, 슬롯 레지스터, 메모리 주소 클리어. 레지스터 파일 클리어는 reset이 **engine2 24 clk, engine3 240 clk 이상** 유지돼야 함(MSX 리셋 rst_hold는 63 clk21m = 378 clk) | E:1423-1438; R:154-165 | YMF278.cc:829-848; YMF278B.cc:57-67 | cpuvis D9 블록; stress(reset_len=8은 반드시 실패) |
| C-HOLD | 메모리 쓰기(래치 3..6)는 CPU를 BUSY가 풀릴 때까지 WAIT (M의 WAIT_n 핸드셰이크) | R:236-241, 192-197; M:1728-1797 | 없음(openMSX는 CPU를 잡지 않음) | cpuvis(ack 검사); memwr; `mut_memw_nohold`. D2 |
| C-DROP | WAIT 타임아웃으로 빠져나온 CPU의 다음 wave 접근은 버리되 ack는 줌; FM 포트는 항상 통과 | R:205-216 | 없음 | **미검증** (H3) |

## B. 하드웨어에서 검증된 소리 의미론 (golden이 지키는 것)

모든 프레임 의미론은 "프레임 N의 레지스터 쓰기는 프레임 N-1 동안 들어와 프레임 N부터 적용"이다(`tb/tb_golden_pcm.sv` 머리말).

| ID | 동작 | 현행 근거 | openMSX 근거 | 검증 |
|---|---|---|---|---|
| S-FRAME | 한 프레임 = CLK_HZ/44100 클럭(128.86 MHz에서 2,922), 24슬롯 순차, 프레임 끝 CPU 예약 구간 | E:105-122, 515-522 | YMF278.cc:506-562 | golden 전체(128.86 MHz) |
| S-SKIP | EG_OFF이고 에지 없는 슬롯은 건너뜀(메모리 접근 없음, LFO도 안 진행: I2) | E:613-618, 772-780 | YMF278.cc:517-522 | golden 전체 |
| S-STEP | 피치 = calc_step(oct, fn, vib); vib는 ÷12를 0 방향 절단(I3) | A:12-23; E:799-834 | YMF278.cc:300-315, 552-555 | `sc_pitchbend`, `sc_square16`, `sc_lfo` |
| S-POS | 위치 진행과 루프: end는 헤더의 2의 보수, 끝을 넘으면 loop로 | E:228-239, 836-870 | YMF278.cc:463-472 | `sc_tri12_loop` 외; `mut_loop_end_gt`, `mut_loop_to_zero` |
| S-FMT | 8/12/16비트 디코드, 12비트 니블 순서는 openMSX 순, 홀수 시작 주소 16비트 | A:216-252; E:872-1003 | YMF278.cc:427-461 | `sc_single8`, `sc_tri12_loop`, `sc_square16`, `sc_odd16` |
| S-INTERP | s[pos]와 s[pos+1]의 16비트 분수 선형 보간 | A:132-142; E:1005-1023 | YMF278.cc:524-526 | 전 시나리오; `mut_interp_frac8`, `mut_interp_off` |
| S-EG | 키온은 항상 포락선 재시작(AR=15면 즉시 DEC/SUS), attack 지수형 `(~env*inc)>>4`, AR=15로 바뀌면 attack 정지, DEC→SUS는 env ≥ DL, SUS/REL은 0x280에서 OFF, 키오프는 OFF·REL이 아니면 REL | E:497-513, 1025-1098; eg_step 패키지 | YMF278.cc:331-425, 564-579, 669-679 | `sc_single8`, `sc_multi`, `sc_eg_dl`; `mut_eg_rel_d2r`, `mut_eg_dl_gt` |
| S-DAMP | DAMP: env < DL(4)이면 rate 48, 아니면 63 | A:283-294 | YMF278.cc:262-298 | `sc_eg_damp`; `mut_eg_nodamp` |
| S-PRVB | pseudo-reverb: env ≥ DL(6)이면 rate 20 | A:283-294 | YMF278.cc:262-298 | `sc_eg_damp`; `mut_eg_noprvb` |
| S-GAIN | env(+AM)와 TL은 **따로** 0x280에서 무음 클립, 두 단 곱 | E:1100-1150 | YMF278.cc:527-537, 483-489 | 전 시나리오 |
| S-TL | TL 즉시 로드(필드 3 bit0) 또는 보간: TL 값이 커지는(소리가 작아지는) 쪽은 27샘플에 1스텝, 작아지는 쪽은 13.5샘플에 1스텝(9샘플 주기 3위상 중 1/2) | E:1619-1658 | YMF278.cc:335-349, 637-646 | `sc_tlramp`; `mut_eg_tlramp2` |
| S-LFO | 슬롯별 lfo_cnt, 속도 표; 필드 4 bit5=1이면 LFO 정지·카운터 0; AM은 진행 전 값 | E:552-554, 1093-1096; A:54-105 | YMF278.cc:300-329, 351-353, 658-665 | `sc_lfo`, `sc_lfo_reset`; `mut_lfo_speed`, `mut_lfo_noreset` |
| S-PAN | 팬 표 0..15, 필드 4 bit4(DO1 출력) = 무음(pan 8) | E:1152-1172, 1562; A:179-210 | YMF278.cc:539-547, 648-656 | `sc_pan_mix`, `sc_tri12_loop`; `mut_pan_right7`, `mut_pan_do1` |
| S-MIX | reg F9h PCM 믹스 레벨 {1, 3/4, 1/2, 3/8, 1/4, 3/16, 1/8, 0}, 포화 전 합에 적용. F8h는 FM 믹스(T의 fm_mix_gain) | E:720-735, 1398-1407; A:113-126; T:427-445 | YMF278.cc:491-504; YMF278B.cc:164-168 | `sc_pan_mix`; `mut_mix_f9`. FM 쪽은 **미검증** |
| S-SAT | 24비트 누산, pcm_vol 시프트(T가 고정 2'd1: -12 dB), 16비트 포화, 프레임당 pcm_valid 1회 | E:720-735; T:357-374 | 없음(openMSX는 float 믹서) | 전 시나리오(TB는 pcm_vol=3) |
| S-HDR | 헤더 로드는 **필드 0(웨이브 번호 하위) 쓰기**에서만. 필드 1(bit8/FN)은 로드 안 함. 베이스 = wave×12, wave ≥ 384이고 reg2 bit4:2 ≠ 0이면 bank×512K + (wave-384)×12 | E:1229-1231, 1582-1593 | YMF278.cc:594-609, 624-628 | `sc_pitchbend`, `sc_wavehi`, `sc_tblhdr`; `mut_hdr_tblhdr` |
| S-BACKFILL | 헤더 바이트 7-11 → 필드 5-9. 웨이브 번호 **뒤에** CPU가 쓴 필드는 덮지 않음(dirty mask: openMSX의 동기 백필과 같은 결과) | E:213-219, 1440-1497 | YMF278.cc:610-615 | `sc_lfo`, `sc_eg_dl`, `sc_eg_damp`, `sc_lfo_reset`; `mut_hdr_nodirty`, `mut_hdr_nobackfill` |
| S-STALL | 헤더를 기다리는 슬롯은 옛 헤더로 소리 내지 않고 멈췄다가 새 헤더로 시작 | E:614-618, 772-797, 1271-1281 | (openMSX는 즉시 로드) | `sc_dirdep_good`, `sc_dirdep_bad` |
| S-RETRIG | 재트리거 두 출처: 필드 4 키온 에지, 키온 중 필드 0 쓰기. 키온이 아닐 때 필드 0 쓰기는 위치만 0 | E:1595-1617 | YMF278.cc:616-621, 669-673 | `sc_multi`, `sc_relwave`, `sc_dirdep_*`; `mut_wave_noposrst` |
| S-MEMHIT | 재생 중 CPU가 캐시된 워드에 쓰면 다음 읽기는 새 값 | E:354-391, 664-711, 963-970 | YMF278.cc:882-894 | `sc_memhit` |
| S-LAT | 출력은 SDRAM 읽기 지연과 무관 | E:937-977 | — | golden을 지연 1과 20에서 같은 기준으로 |
| S-BOUND | CPU 메모리 연산은 늦어도 다음 프레임 예약 구간에서 처리(BUSY ≤ 1프레임, 구조적) | E:115-122, 1187-1191, 1233-1270 | — | cpuvis D8 창(지연 + 1프레임 + 64 clk 안에 BUSY 해제) |

## C. openMSX와의 의도적 차이 (소리)

골든 모델(`golden_pcm.py`, `golden_pcm_omsx.py`)이 이 차이를 그대로 흉내 낸다. 새 엔진이 하나를 없애면 모델과 해당 시나리오를 같은 커밋에서 바꾼다.

**플래그** 열이 있는 항목은 `ref278.cpp`의 `REF_DEV` 플래그로 실행 가능하다. `oracle` 게이트가 "ref278 + 플래그 전부 = golden 모델"(22개 시나리오 바이트 일치)과 "플래그 하나를 빼면 시나리오가 달라짐"을 요구하고, ref278이 죽거나 짧은 출력을 내면 FAIL이다(2026-10-24: 빼면 달라지는 시나리오 수 I1 2, I2 1, I4 8, I5 1, I7 9, I8 1, I9 1, I11 11). 2026-10-24 적대적 검토(msx1-handoff) 전에는 이 대조가 게이트에 없었고, ref278과 모델은 19개 중 11개 시나리오에서 달랐다.

**이 게이트가 증명하는 것은 "모델 = openMSX + 이름 붙은 차이"까지다.** 차이가 옳다는 증명은 아니다. 플래그는 시나리오가 맞을 때까지 맞춘 것이고, I1·I4·I11 어느 것도 하드웨어 녹음 근거가 없다(근거는 엔진 줄과 openMSX 처리 순서뿐). 특히 I11은 11개 시나리오를 바꾼다. 성격 열: **미검증** = RTL과 openMSX 중 어느 쪽이 칩과 같은지 모름, **RTL 결함** = openMSX 쪽이 실칩에 맞다는 근거가 있음, **openMSX 지름길** = openMSX 쪽이 실칩과 다를 근거가 있음.

| ID | 플래그 | 차이 (성격) | 근거 | 보이는 시나리오 (ref278 플래그를 뺐을 때 달라지는 것) |
|---|---|---|---|---|
| I1 | `I1` | **미검증.** EG 단계 순서: 프레임 f의 레지스터 쓰기·키 이벤트가 EG 단계 f(eg_cnt = f)에 이미 반영되고, 단계가 그 프레임 샘플 **앞**에 온다. 키온·키오프 프레임은 EG가 안 움직인다. openMSX는 샘플 **뒤**, 쓰기 **전**에 단계를 밟는다(그래서 "eg_cnt 오프바이원"으로 보였다) | E:139-146; YMF278.cc:331-333, 506-562 | `sc_songchange24`, `sc_lfo_off` |
| I2 | `I2` | **미검증.** EG_OFF 슬롯은 LFO도 진행 안 함(openMSX는 모든 슬롯 진행) | E:613-618, 552; YMF278.cc:349-351 | `sc_lfo_off` (P1의 "`sc_lfo_reset`에서 보임"은 틀렸다: 그 시나리오는 이 차이를 건드리지 않음) |
| I3 | — | 비브라토 ÷12를 0 방향으로 절단. openMSX `/`도 0 방향이라 **결과 차이 없음**(ref278 플래그 불필요) | E:439-469, 822-829; YMF278.cc:300-315 | — |
| I4 | `I4` | **미검증.** 슬롯이 샘플 **전**에 위치를 진행(새 스텝/비브라토가 한 샘플 빨리 반영). 위치 리셋(키온·키오프 중 웨이브 쓰기)이 있는 프레임은 진행 없이 pos 0. openMSX는 샘플 출력 **뒤** 진행 → `sim/golden_srg/README.md`의 "floor" | tb_golden_pcm.sv 머리말; YMF278.cc:549-559 | `sc_square16`, `sc_pitchbend`, `sc_odd16`, `sc_lfo*`, `sc_wavehi`, `sc_silence` |
| I5 | `I5` | **미검증**(TB 일정에 묶임). F9h 믹스는 정수 곱/시프트(내림), openMSX는 float 볼륨(이 시나리오들에서는 결과 같음). 그리고 F9h 쓰기는 **그 프레임의 출력**부터 적용(슬롯 쓰기보다 한 프레임 빠름). 이것은 TB가 프레임 f+1 레지스터를 프레임 f 동안 쓰는 일정과 엔진의 프레임 끝 믹스가 합쳐진 결과다. F9h를 다른 레지스터처럼 다음 프레임에 반영하는 엔진은 `sc_pan_mix` 7프레임에서 golden FAIL → 그 엔진은 이 플래그를 끄고 모델을 같이 바꾼다 | E:720-735; A:113-126; YMF278.cc:491-504 | `sc_pan_mix` |
| I6 | — | 헤더 로드 지연(서비스 창/스톨) — 소리 결과는 dirty mask와 스톨로 openMSX와 같게 맞춤. CPU가 LD가 풀리기 전에 필드 5-9를 읽으면 옛 값이 보일 수 있음(H4) | E:1233-1281 | `sc_dirdep_*`; cpuvis는 LD 해제 후에만 읽음 |
| I7 | `I7` | **openMSX 지름길.** openMSX는 활성 슬롯이 하나도 없으면 `generateChannels`가 `advance()`까지 건너뜀(eg_cnt, TL 보간, LFO 정지). 바로 그 줄에 `// TODO update internal state, even if muted`(YMF278.cc:509)가 있다: 에뮬레이터의 생략이지 칩 동작이 아니다. RTL은 항상 진행하고, 칩에 더 가까운 쪽은 RTL일 가능성이 크다. 모든 시나리오가 무음 프레임 0으로 시작하므로 EG 위상이 거의 모든 곳에 영향 | YMF278.cc:508-513; E:132-150 | `sc_silence` 외 8개 |
| I11 | `I11` | **미검증.** 키온·키오프·키온 중 웨이브 쓰기(재트리거)는 그 슬롯 차례에, **그때의** 레지스터로 처리. openMSX는 쓰는 순간 처리하므로 같은 프레임에 키온 **뒤에** 쓴 AR/DL 등은 그 키온에 안 먹는다 | E:1595-1617; YMF278.cc:616-621, 669-673 | `sc_multi`, `sc_eg_dl`, `sc_dirdep_*` 등 11개 |
| I8 | `I8` | **RTL 결함(보드 배선), 드묾.** reg 2 bit1(메모리 타입)은 저장·읽기만 하고 주소 배치는 mode 0 그대로(RAM이 0x200000부터). openMSX의 MoonSound 배선(MSXMoonSound.cc:30-90 `setupMemPtrs`)은 mode 1에서 RAM이 /MCS6..9 = 0x380000부터 512kB이고 0x200000-0x37FFFF는 비어 있다(읽기 0xFF, 쓰기 무시). openMSX도 "MoonSound에서는 보통 쓰지 않는다"고 적는다. 빈 영역을 읽은 값(0xFF)은 하드웨어 미검증. 3차 검토(msx1-handoff) 전에는 ref278도 이 비트를 무시해서 시나리오가 없었다 | E:1670-1678; YMF278.cc:850-870; MSXMoonSound.cc:30-90 | `sc_memtype1` (모델 대 I8을 뺀 ref278: 600프레임 중 418프레임이 다름; ref278끼리 I8 켬/끔: 410, msx1-handoff 측정) |
| I9 | `I9` | **RTL 결함.** 소리 메모리: openMSX는 0-2MB가 ROM이라 reg 6 쓰기를 무시하고(`writeMem`, YMF278.cc:882-894), 2MB 이상 RAM에만 쓴다. RTL은 ROM 영역도 쓴다: yrw801 이미지가 SDRAM에 있고 `msx.sv` ch4 브리지(M:1857-1897)는 주소를 보지 않고 모든 쓰기를 넘긴다 → 2MB 아래에 쓰는 소프트웨어는 ROM 샘플을 (다음 로드까지) 망가뜨린다. `sc_memhit`은 0x1000·0x2000에 쓰므로 이 결함 위에서만 재생이 바뀐다(I9를 빼면 400프레임 중 380프레임이 다름) | YMF278.cc:872-894; M:1857-1897 | `sc_memhit` |
| I10 | — | EG_DEC에서 env를 0x3FF로 클램프(openMSX는 클램프 없음, DL ≤ 0x3E0이라 결과 동일) | E:1073-1081; YMF278.cc:380-389 | — |

## D. openMSX와의 CPU 가시 차이 (cpuvis 모델 플래그)

`sim/cpuvis/cpuvis_check.py`의 `DEVIATIONS`가 이 표의 실행 가능한 형태다. 게이트는 모든 플래그를 켠 모델과 RTL이 접근마다 일치하고, **각 플래그가 op 스크립트의 관측 1개 이상을 바꾸는지**(= 스크립트가 그 차이를 실제로 건드리는지)를 요구한다. 2026-10-24 측정: 판정한 검사 717개 0 실패, 판정 못 한 검사 0개. 다음 접근이 기대 BUSY/LD 창 안에서 시작하는 33개(전부 연속 메모리 접근)는 하강 시점 대신 "창이 열리기 전에 BUSY/LD가 내려가지 않음"만 본다(`busy-held`/`ld-held`; P1 첫 보고 때는 이 33개를 판정 없이 통과로 셌다, `mut_memrd_nobusy`가 이 검사에 걸린다). 게이트는 판정 수 1528 이상(P2 이전 717), 미판정 0을 요구하고(`CPUVIS_MIN_CHECKS`, `CPUVIS_MAX_UNJUDGED`), 판정한 검사의 키(`op<n> <종류> <포트> <검사>`) 목록이 `sim/cpuvis/checks_baseline.txt`와 같아야 한다. 개수만 맞춘 채 검사를 빼거나 종류를 바꾸면 FAIL(대조: 기준의 `busy` 하나를 `busy-held`로 바꾸면 "1 missing, 1 new"). 새 엔진이 ack 시점을 바꿔 창이 움직이면 목록이 정당하게 바뀌므로, 그때는 차이를 검토해 기준을 새로 커밋한다. 키 목록은 검사 **내용**(판정 식)을 고정하지 않는다: 그것은 cpuvis 뮤턴트가 지킨다. 플래그별 의존 검사 수 D1 268, D2 88, D3 1, D4 2, D5 63, D6 2, D7 1, D8 59, D9 21. 플래그 없는 순수 openMSX 모델과는 판정 717개 중 358개가 다르다.

2026-10-25(P2): op 스크립트에 블록 셋을 더했다. `C-HDR dirty`(웨이브 번호 직후 필드 6 쓰기가 백필 뒤에도 남는지), `C-HDR again`(헤더를 읽는 도중 웨이브 번호 재기록), `G-RESET`(reset 전 24슬롯의 필드 4·9에 값을 쓰고 reset 뒤 다시 읽기, 필드 6 두 개). 접근 625개, 판정 1528개. engine2는 D10·D11·D12가 더 필요하고, engine3(`ymf278_pcm_engine3`, `run_cpuvis.sh`가 엔진 모듈 이름으로 고름)은 D10·D11·D12 없이 통과한다. 앞의 두 블록은 engine3 뮤턴트 `dirty_ignored`, `again_none`이 처음에 통과해서 만들었고, `again_none`은 engine3의 헤더 이중 읽기 버그(저장 사이클에 같은 슬롯을 다시 고름)가 결함을 가려서 그 버그를 고친 뒤에야 걸렸다.

2026-10-26(결정 1): op 블록 `D3x`(bit0=0에서 쓰기·읽기 뒤 bit0=1로 같은 주소 읽기), `D4x`(reg 4만, reg 3만 쓰고 reg 6 접근), `D7x`(reg 6 쓰기 직후 다음 주소 읽기, 다시 처음부터 읽기)를 더했다. 접근 949개, 판정 2627개(op 0-296 키는 그대로). engine2 의존 검사 D3 1→2, D4 2→5, D7 1→3. engine3는 `ENGINE_DROPS`에서 D3·D4·D7도 빼고 PASS(허용 결함은 D5만 남음).

2026-10-25(5차 검토 반영): cpuvis가 자기 메모리 이미지를 쓴다(`run_cpuvis.sh`가 golden `mem.bin`을 복사해 웨이브 0 헤더 바이트 7-11을 31 5A 27 C6 0B로 바꿈; 원래 00 F0 00 F4 00이라 필드 5·7·9는 백필 유무가 안 보였다). golden의 `mem.bin`은 그대로다. `G-RESET`은 reset 뒤 24슬롯의 필드 4-9를 전부 읽는다(144개). 새 블록 `C-RDPORT`: 웨이브 번호를 쓴 뒤 1-16 clk 간격으로 되읽어, 헤더 읽기가 레지스터 파일의 읽기 포트를 쓰는 사이클과 겹치게 한다(engine3 뮤턴트 `rd_engine_clash`가 간격 5에서 40h를 읽음). 접근 863개, 판정 2352개. 두 엔진의 D2 하한(1024/107 clk)이 달라 `C-RDPORT` 뒤 op 시각이 갈라지고 LD 검사 8개가 한쪽은 `ld`, 다른 쪽은 `ld-held`가 되므로 기준 키 목록을 엔진별로 둔다. op 0-296(`C-RDPORT` 앞)의 키는 이전 기준 1528개 중 그 구간 611개와 두 엔진 모두 같다. engine2 플래그 의존: D10 24, D11 120(이전 2), D12 4.

D3·D4·D5·D7·D12는 **RTL 결함**이다: openMSX의 해당 동작에 "Verified on real YMF278" 주석이 있다(D7은 읽는 순간의 메모리를 주는 openMSX 동작, 하드웨어 주석은 없음). 게이트는 고칠 때까지 이 결함을 허용할 뿐 정답으로 삼지 않으며, 출력 줄에 "tolerated RTL defects"로 따로 적는다. D1·D2·D6은 RTL의 선택이고 하드웨어 근거는 어느 쪽에도 없다.

| ID | 차이 | 현행 근거 | openMSX | 성격 | P2에서 |
|---|---|---|---|---|---|
| D1 | BUSY/LD 지연을 clk_sdram 클럭으로 셈(마스터 클럭이 아님): 128.86 MHz에서 openMSX보다 3.8배 짧음 (LD 10000 clk = 77.6 µs, openMSX 295 µs) | R:52-83 | YMF278B.cc:10-39 | 2026-10-04 의도적으로 유지(R:56-62 주석) | 그대로 또는 스케일. 상태 비트일 뿐 |
| D2 | 래치 3..6 쓰기의 BUSY = 1024 clk(7.95 µs), 그동안 CPU WAIT | R:82, 236-241, 192-197 | 28 마스터 클럭(0.83 µs), WAIT 없음 | R800 OTIR 업로드 손실 회피용(PLAN §0, memwr) | **바꿀 대상**: 쓰기가 SDRAM에 반영되는 시점에 BUSY 해제, WAIT ≈ 107 clk (PLAN 목표 5) |
| D3 | reg 6 읽기/쓰기가 reg 2 bit0(메모리 접근 모드)를 무시 | E:1666-1722 | 모드 0이면 쓰기 무시·주소 유지, 읽기 FFh (YMF278.cc:739-748, 780-786, **실칩 확인 주석**) | **RTL 결함** | **engine3 고침**(2026-10-26 사용자 결정 1): bit0=0이면 쓰기 무시, 읽기 FFh, 둘 다 주소 그대로(openMSX `readReg`: 증가도 bit0일 때만). 되돌린 뮤턴트 `d3_wr_through`, `d3_rd_through`, `d3_no_ff` FAIL. engine2는 허용 결함 그대로 |
| D4 | reg 3/4 쓰기가 메모리 주소를 즉시 바꿈 | E:1683-1684 | reg 5 쓰기 때만 주소 갱신 (YMF278.cc:716-737, 실칩 확인 주석) | **RTL 결함** | **engine3 고침**: reg 3/4는 저장만, reg 5 쓰기에서 세 바이트를 주소로. 뮤턴트 `d4_reg3_moves`, `d4_reg4_moves` FAIL |
| D5 | NEW2 0→1마다 ID 1회 신호 재무장 | R:166-169 | reset 후 한 번만 (YMF262.cc:1101-1110, **실칩 확인 주석**) | **RTL 결함** | 고침(D9와 함께: warm reset은 재무장) |
| D6 | reset 후 F8h 읽기 00h, FM 믹스 x1 | E:1542-1547, 1398-1403 | 1Bh (YMF278.cc:842), FM 믹스 레벨도 그 값 | 미확인 | 읽기값만이면 맞추기 쉬움 |
| D7 | reg 6 읽기는 직전 reg 5 쓰기/reg 6 읽기 때 프리페치한 바이트를 줌. reg 6 쓰기 뒤에 reg 5 없이 읽으면 옛 값 | E:1702, 1716-1721; T:268-271 | 읽는 순간의 메모리 (YMF278.cc:780-782) | **RTL 결함** | **engine3 범위를 줄여 고침**: reg 6 쓰기가 포트를 떠난 뒤 다음 주소에서 다시 미리 읽어, "쓰기 뒤 reg 5 없이 읽으면 옛 값"이 없어짐(뮤턴트 `d7_no_refetch` FAIL). 미리 읽기 구조(SDRAM 지연 숨기기)는 그대로라 **읽는 순간 값과의 차이는 남는다(실칩 미확인)**. 메모리를 바꾸는 것은 CPU 쓰기뿐이고 쓰기마다 다시 읽으므로, 남는 차이는 미리 읽기가 끝나기 전에 읽는 경우(H13)뿐이다. 그래서 따로 플래그(D7b)는 두지 않았다: 0 clk 지연 벤치에서는 관측이 없어 플래그가 "쓰이지 않음"으로 FAIL한다 |
| D8 | reg 5/6 쓰기, reg 6 읽기 뒤 BUSY가 엔진의 메모리 연산 완료까지 늘어남(최대 1프레임) | R:141; E:1722 | 고정 지연 | 구조적(S-BOUND) | 새 엔진에서도 상한 보장 |
| D9 | warm reset이 NEW2를 지움 | T:90-102 | reg 105h 유지, ID 신호만 재무장 (YMF262.cc:1398-1404) | **의도적**: GoFigure 감지 실패 수정(T:93-99 주석) | 유지 |
| D10 | reset 후 필드 4(68h-7Fh) 읽기 20h: engine2는 bit 5를 뒤집어 저장한다(전부 0인 리셋 이미지 = LFO 정지) | E:1454-1456, 1551 | openMSX reset은 모든 레지스터에 0을 쓴다: 읽기 0, LFO 동작(YMF278.cc reset → writeRegDirect case 4) | 미검증: openMSX reset **구현**(writeRegDirect 순서)에서 나온 값, 하드웨어 근거 없음. engine3는 이것을 목표로 채택했다(소프트웨어가 reset 직후 이 레지스터를 읽을 일은 거의 없다) | engine3: 저장한 그대로 읽음(플래그 없음) |
| D11 | reset 후 필드 5-9 읽기 0 | E:1423-1438 | openMSX reset은 F7h→08h 순서로 0을 써서 각 슬롯의 마지막 쓰기가 웨이브 번호 0 → 웨이브 0의 헤더가 필드 5-9에 들어감 | 미검증: openMSX reset **구현**의 결과, 하드웨어 근거 없음. engine3는 이것을 목표로 채택했다 | engine3: reset 해제 뒤 24슬롯 웨이브 0 헤더를 읽어 채움. 5차 검토 전에는 슬롯 0·23만 읽는 뮤턴트도 통과했을 것(필드 5·7·9가 0이라서). 이제 `reset_hdr_partial`이 FAIL |
| D12 | 웨이브 번호를 헤더를 읽는 도중에 다시 쓰면 첫 번호의 헤더가 남을 수 있음(engine2는 읽기 시작할 때 본 번호로 읽고, 저장할 때 요청을 지움). 실측(2026-10-25, `AGAIN_GAP` × `AGAIN_PRE` 64조합): 두 쓰기 사이 20-60 clk이면 프레임 위상 8개 중 7개에서 옛 헤더, 1개(위상 224)에서 새 헤더; 68 clk 이상이면 항상 새 헤더. 모델은 64 clk 안이면 두 헤더 다 허용 | E:1277-1278, 1590-1591 | 쓴 번호의 헤더를 즉시 반영(YMF278.cc:594-615) | **RTL 결함**(P2에서 cpuvis `C-HDR again` 블록으로 처음 드러남) | engine3: 읽는 도중 재기록되면 다시 읽음(`hf_again`) |

## E. 위험 · 미검증 (게이트가 아직 못 보는 것)

| ID | 내용 | 근거 | 제안 |
|---|---|---|---|
| H1 | reg 6 읽기는 프리페치 완료를 기다리지 않는다(`pcm_reg_rd_done = 1`). 재생 중(서비스가 늦을 때) R800 INIR처럼 연속으로 읽으면 이전 바이트를 다시 받을 수 있다. cpuvis는 재생 없는 상태에서만 읽는다 | T:271; E:1702, 1716-1722 | P2: 읽기 ack를 데이터 도착에 묶고, cpuvis에 "재생 24보이스 + 연속 읽기" 블록 추가 |
| H2 | BUSY가 쓰기 **발행** 시점에 내려간다(반영 시점이 아님). MEM_WRITE_DELAY가 그 틈을 덮는다 | E:1298-1306, 1703, 1722 | PLAN 목표 5. memwr 게이트(지연 0 대조) 유지 |
| H3 | C-DROP(WAIT 타임아웃 뒤 접근 버림) 경로는 어떤 벤치도 안 지난다 | R:205-216 | cpuvis에 ack 타임아웃 op 추가 검토 |
| H4 | 헤더 로드는 프레임당 1슬롯(서비스 창) + 재생 중 슬롯의 즉시 스톨. 한꺼번에 24슬롯의 웨이브 번호를 쓰면 무음 슬롯의 헤더는 최대 24프레임(544 µs)이 걸려 LD(77.6 µs)보다 늦다. 그동안 필드 5-9 읽기는 옛 값. **소리도 틀린다**: `sc_songchange24`는 지연 1에서만 비트 일치, 지연 6에서 1600 중 620, 10에서 623, 20에서 44 일치(첫 불일치 frame 310 = 96회 쓰기 프레임) — `load` 게이트, 현행 엔진 FAIL | E:1242, 1271-1281 | P2 설계: 헤더 로드를 슬롯 마이크로시퀀스나 서비스 창 여러 개로. 새 엔진은 `load` PASS |
| H5 | FM 쪽(F8h 믹스, OPL3 상태/타이머 실제 속도)은 이 하네스 밖. cpuvis의 OPL3는 타이머 스텁(clk_sdram 구동) | tb/opl3_stub.sv | P6 |
| H6 | (해결) I7은 `sc_silence`, I2는 `sc_lfo_off`가 본다(`oracle` 게이트) | — | — |
| H8 | golden 뮤턴트는 모두 기능 끄기·비교 경계 수정이다. 스케줄링(디스패치 순서, 헤더 스톨, PIPE 캐시 태그, 프레임 끝 예약, `cache_rr` 32프레임 재페치, 노트 중 warm reset)을 건드리는 뮤턴트가 없다. 같은 프레임 key-off→key-on, 슬롯 23→0 경계, 12비트 루프 이음새 홀수 걸침도 전용 시나리오가 없다. cpuvis 뮤턴트 15개도 전부 정적 디코드다 | E:754-757 외 | P2: 스케줄링 뮤턴트 추가 |
| H11 | golden 모델과 ref278(REF_OMSX)은 mem.bin(0x80100바이트) 너머 4MB를 0으로 채운다. RAM 쪽(0x200000+)은 openMSX도 0으로 지우므로(YMF278.cc:826) 같다. ROM 쪽 0x80100-0x1FFFFF는 **TB 가정**이다: openMSX에서는 실제 2MB ROM 데이터. 이 영역을 읽는 시나리오는 없다(032d200 전후 ref278 출력이 기존 21개에서 바이트 동일, msx1-handoff 4차) | tb/tb_golden_pcm.sv:47; golden_pcm_omsx.py; ref278.cpp main | 그 영역을 쓰는 시나리오가 생기면 yrw801 이미지로 |
| H12 | (게이트됨, `busylat`) engine3의 "쓰기가 브리지를 떠날 때까지 BUSY"를 없앤 뮤턴트는 memwr에서 0 errors다(WAIT 하한 107 clk가 실제 쓰기 지연보다 길다). 데이터로는 안 보인다: 두 번째 쓰기는 `cpu_wr_pend`가 BUSY를 잡아 두므로 덮어쓰지 않는다. 보이는 것은 마지막 쓰기 뒤 BUSY 하강 시점뿐이라, cpuvis에 쓰기 지연(`WLAT` 150·300)을 주고 모델이 reg 6 쓰기 BUSY를 쓰기 지연 이상으로 기대하게 했다: 뮤턴트는 109 clk에 내려가 FAIL, 트리 PASS. engine2(하한 1024)도 같은 지연에서 PASS(대조) | E3 `cpu_mem_busy`; `cpuvis_check.py` `HOLDS_WRITE` | 실제 쓰기 지연 분포가 나오면(F4) `WLAT`를 그 최대치 근처로 |
| H13 | H1은 engine3에도 그대로다: reg 6 읽기는 CPU를 잡아 두지 않는다. cpuvis 읽기 지연 150 clk에서 BUSY를 보지 않는 200 clk 간격 연속 읽기가 이전 프리페치를 받는다(두 엔진 모두 "expected a2 got a1"). 실제 지연(최대 수십 clk)과 R800 I/O 간격(약 100 clk 이상)에서는 안 생긴다 | E3 SV_RD_WAIT; R:282-292 | 읽기 ack를 데이터 도착에 묶을지 DESIGN 결정 |
| H14 | 쓰기 ack 바로 다음 clk의 되읽기는 두 엔진 모두 이전 값을 준다(cpuvis 간격 0). engine3는 CPU 쓰기를 다음 clk에 `reg_rd_data`로 넘겨 engine2와 같은 1 clk 지연이다(넘기지 않으면 2 clk, 간격 1에서 FAIL). CPU가 I/O를 그만큼 붙여 낼 수는 없다 | E3 readback 파이프라인; `C-RDPORT` | — |
| H16 | msx.sv ch4 canary가 브리지를 잡는 사이클에 오른 엔진 읽기 요청은 사라진다(engine2: 그 프레임의 남은 슬롯 미처리). fullsys lprobe에서 phase 4 기준 초당 약 570번; `+nocanary` 대조는 0. 보드 빌드에도 있음 | M:1851-1935; DESIGN 9절 | msx.sv 수정(사용자 결정: canary 제거 또는 요청 붙잡기) |
| H15 | (기존, 범위 밖) `msx.sv:2531` MoonSound `rst_n = ~reset_ms`는 clk21m 쪽 신호를 clk_sdram 비동기 리셋에 바로 쓴다. 해제 동기화기와 recovery/removal STA는 확인 안 함. engine3는 `rst_n`을 데이터로도 쓴다(리셋 쓸기 카운터) | M:2531; E3 `clr_cnt` | Quartus 게이트에서 recovery/removal 확인 |
| H9 | golden TB의 메모리 모델은 고정 지연 + 미결 1개뿐: 지터, 리프레시, 다른 채널 경합, CPU 쓰기 busy가 없다 | tb/tb_golden_pcm.sv:44-70 | ch4 지연 실측 뒤 분포를 TB에 |
| H10 | `dbg_slot_keyon/active/envlive`는 `debug_overlay.sv:28-30`이 쓴다. 드롭인 교체면 새 엔진도 내야 한다 | debug_overlay.sv:28-30 | DESIGN ALM 표에 포함 |
| H7 | 실제 소프트웨어 레지스터 트레이스(MoonBlaster, vgmplay, OPL4 데모)는 이번에 수집하지 않았다(PLAN P0의 일부) | — | P2 전에 openMSX에서 수집 |
