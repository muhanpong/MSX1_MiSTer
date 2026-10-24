# OPL4 PCM 재제작 — 지켜야 할 동작 사양 (P0)

작성 2026-10-24, 기준 커밋 b90a9d4 (브랜치 opl4_scratch). 새 엔진은 아래 항목을 **그대로 지키거나, 바꾸면 그 항목의 게이트를 의도적으로 바꾼다**.
경로 약어: `E` = `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_engine2.sv`, `R` = `.../rtl/ymf278b_regs.sv`,
`T` = `.../rtl/ymf278b_top.sv`, `A` = `.../rtl/pcm/ymf278_pcm_alu.sv`, `M` = `rtl/msx.sv`,
openMSX = `~/data/openmsx_v9968/src/sound/` (`YMF278B.cc`, `YMF278.cc`, `YMF262.cc`).

검증 수단 (모두 `.claude/skills/opl4-harness/scripts/harness.sh`):

| 게이트 | 무엇 | 시나리오/뮤턴트 위치 |
|---|---|---|
| `golden` | 슬롯 출력 샘플, 128.86 MHz(PIPE 경로), SDRAM 지연 1·20, 비트 일치(지연 0, ±1도 불허) | `sim/golden/gen_pcm_testdata.py`의 `sc_*` 18개, 모델 `golden_pcm_omsx.py` |
| `mutants` | golden이 실패할 수 있음 | `mutants/make_engine2_mutants.py` 19개 |
| `cpuvis` | CPU 가시 동작, 접근 하나하나를 openMSX 모델과 같은 클럭에서 비교 | `sim/cpuvis/` (op 스크립트 `cpuvis_ops.py`, 모델 `cpuvis_check.py`), 뮤턴트 `mutants/make_cpuvis_mutants.py` 15개 |
| `stress` | MLAB 레지스터 파일: 슬롯 읽기 순간의 쓰기, warm reset, reset 길이 | `sim/lockstep/run_stress.sh` (자체 뮤턴트 4개 + reset_len=8) |
| `memwr` | fullsys R800 OTIR 1024바이트 업로드 + 읽어 비교 | `assets/mprobe_r.hex`, 대조 `MEM_WRITE_DELAY 0` |
| `resource` | fit 보고서 ALM | — |

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
| C-RESET | warm reset: 래치, BUSY/LD, 슬롯 레지스터, 메모리 주소 클리어. 레지스터 파일 클리어는 reset이 **24 clk 이상** 유지돼야 함 | E:1423-1438; R:154-165 | YMF278.cc:829-848; YMF278B.cc:57-67 | cpuvis D9 블록; stress(reset_len=8은 반드시 실패) |
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
| S-TL | TL 즉시 로드(필드 3 bit0) 또는 보간: 9샘플 주기, 커지는 쪽 27샘플/스텝, 작아지는 쪽 13.5샘플/스텝 | E:1619-1658 | YMF278.cc:335-349, 637-646 | `sc_tlramp`; `mut_eg_tlramp2` |
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

| ID | 차이 | 근거 | 보이는 시나리오 |
|---|---|---|---|
| I1 | eg_cnt 오프바이원: RTL은 프레임 **끝**에 증가, openMSX는 샘플마다 `advance()` 첫 줄에서 증가 | E:139-146; YMF278.cc:333; `sim/golden/RESULTS.md` | EG가 움직이는 모든 시나리오 |
| I2 | EG_OFF 슬롯은 LFO도 진행 안 함(openMSX는 모든 슬롯 진행) | E:613-618, 552; YMF278.cc:339-353 | `sc_lfo_reset`(재키 시 위상) |
| I3 | 비브라토 ÷12를 0 방향으로 절단(openMSX `/`도 0 방향이지만 RTL은 크기 표 `vib_q_tab`) | E:439-469, 822-829; YMF278.cc:300-315 | `sc_lfo`, `sc_lfo_reset` |
| I4 | 새 스텝/키온이 쓰기 다음 프레임에 바로 적용(openMSX는 샘플 출력 **뒤** 진행, 한 샘플 늦음) → ref278과 위상 차, `sim/golden_srg/README.md`의 "floor" | tb_golden_pcm.sv 머리말; YMF278.cc:549-559 | `sc_square16`, `sc_pitchbend`, `sc_odd16` (ref278 대비) |
| I5 | F9h 믹스는 정수 곱/시프트(내림), openMSX는 float 볼륨. 그리고 F9h 쓰기는 **그 프레임의 출력**부터 적용(슬롯 쓰기보다 한 프레임 빠름) | E:720-735; A:113-126; YMF278.cc:491-504 | `sc_pan_mix` |
| I6 | 헤더 로드 지연(서비스 창/스톨) — 소리 결과는 dirty mask와 스톨로 openMSX와 같게 맞춤. CPU가 LD가 풀리기 전에 필드 5-9를 읽으면 옛 값이 보일 수 있음(H4) | E:1233-1281 | `sc_dirdep_*`; cpuvis는 LD 해제 후에만 읽음 |
| I7 | openMSX는 활성 슬롯이 하나도 없으면 `generateChannels`가 `advance()`까지 건너뜀(eg_cnt, TL 보간, LFO 정지). RTL은 항상 진행 | YMF278.cc:508-513; E:132-150 | 전부 무음 구간 뒤의 EG 위상. **시나리오 없음** |
| I8 | reg 2 bit1(메모리 타입, mode1 칩셀렉트 배치)은 저장·읽기만, 주소 배치는 바꾸지 않음 | E:1670-1678; YMF278.cc:850-870 | 없음(MoonSound는 mode0) |
| I9 | 소리 메모리: openMSX는 0-2MB ROM(쓰기 무시), 2MB+ RAM. RTL은 SDRAM ch4 하나(ROM 영역 쓰기 처리 여부는 msx.sv ch4 브리지 쪽, **미확인**) | YMF278.cc:872-894; MSXMoonSound.cc:64-87 | cpuvis는 0x200000+에만 씀 |
| I10 | EG_DEC에서 env를 0x3FF로 클램프(openMSX는 클램프 없음, DL ≤ 0x3E0이라 결과 동일) | E:1073-1081; YMF278.cc:380-389 | — |

## D. openMSX와의 CPU 가시 차이 (cpuvis 모델 플래그)

`sim/cpuvis/cpuvis_check.py`의 `DEVIATIONS`가 이 표의 실행 가능한 형태다. 게이트는 모든 플래그를 켠 모델과 RTL이 접근마다 일치하고, **각 플래그가 op 스크립트의 관측 1개 이상을 바꾸는지**(= 스크립트가 그 차이를 실제로 건드리는지)를 요구한다. 2026-10-24 측정: 717개 검사 0 실패, 플래그별 의존 검사 수 D1 268, D2 88, D3 1, D4 2, D5 63, D6 2, D7 1, D8 59, D9 21. 플래그 없는 순수 openMSX 모델과는 718개 중 358개가 다르다.

| ID | 차이 | 현행 근거 | openMSX | 성격 | P2에서 |
|---|---|---|---|---|---|
| D1 | BUSY/LD 지연을 clk_sdram 클럭으로 셈(마스터 클럭이 아님): 128.86 MHz에서 openMSX보다 3.8배 짧음 (LD 10000 clk = 77.6 µs, openMSX 295 µs) | R:52-83 | YMF278B.cc:10-39 | 2026-10-04 의도적으로 유지(R:56-62 주석) | 그대로 또는 스케일. 상태 비트일 뿐 |
| D2 | 래치 3..6 쓰기의 BUSY = 1024 clk(7.95 µs), 그동안 CPU WAIT | R:82, 236-241, 192-197 | 28 마스터 클럭(0.83 µs), WAIT 없음 | R800 OTIR 업로드 손실 회피용(PLAN §0, memwr) | **바꿀 대상**: 쓰기가 SDRAM에 반영되는 시점에 BUSY 해제, WAIT ≈ 107 clk (PLAN 목표 5) |
| D3 | reg 6 읽기/쓰기가 reg 2 bit0(메모리 접근 모드)를 무시 | E:1666-1722 | 모드 0이면 쓰기 무시·주소 유지, 읽기 FFh (YMF278.cc:739-748, 780-786) | 미확인(의도 기록 없음) | 결정 필요 |
| D4 | reg 3/4 쓰기가 메모리 주소를 즉시 바꿈 | E:1683-1684 | reg 5 쓰기 때만 주소 갱신 (YMF278.cc:716-737, 실칩 확인 주석) | 결함 쪽 | openMSX대로 고치는 것을 권장 |
| D5 | NEW2 0→1마다 ID 1회 신호 재무장 | R:166-169 | reset 후 한 번만 (YMF262.cc:1103-1110) | 미확인 | 영향 작음 |
| D6 | reset 후 F8h 읽기 00h, FM 믹스 x1 | E:1542-1547, 1398-1403 | 1Bh (YMF278.cc:842), FM 믹스 레벨도 그 값 | 미확인 | 읽기값만이면 맞추기 쉬움 |
| D7 | reg 6 읽기는 직전 reg 5 쓰기/reg 6 읽기 때 프리페치한 바이트를 줌. reg 6 쓰기 뒤에 reg 5 없이 읽으면 옛 값 | E:1702, 1716-1721; T:268-271 | 읽는 순간의 메모리 (YMF278.cc:780-782) | 결함 | 읽기 시점 기준으로 |
| D8 | reg 5/6 쓰기, reg 6 읽기 뒤 BUSY가 엔진의 메모리 연산 완료까지 늘어남(최대 1프레임) | R:141; E:1722 | 고정 지연 | 구조적(S-BOUND) | 새 엔진에서도 상한 보장 |
| D9 | warm reset이 NEW2를 지움 | T:90-102 | reg 105h 유지, ID 신호만 재무장 (YMF262.cc:1398-1404) | **의도적**: GoFigure 감지 실패 수정(T:93-99 주석) | 유지 |

## E. 위험 · 미검증 (게이트가 아직 못 보는 것)

| ID | 내용 | 근거 | 제안 |
|---|---|---|---|
| H1 | reg 6 읽기는 프리페치 완료를 기다리지 않는다(`pcm_reg_rd_done = 1`). 재생 중(서비스가 늦을 때) R800 INIR처럼 연속으로 읽으면 이전 바이트를 다시 받을 수 있다. cpuvis는 재생 없는 상태에서만 읽는다 | T:271; E:1702, 1716-1722 | P2: 읽기 ack를 데이터 도착에 묶고, cpuvis에 "재생 24보이스 + 연속 읽기" 블록 추가 |
| H2 | BUSY가 쓰기 **발행** 시점에 내려간다(반영 시점이 아님). MEM_WRITE_DELAY가 그 틈을 덮는다 | E:1298-1306, 1703, 1722 | PLAN 목표 5. memwr 게이트(지연 0 대조) 유지 |
| H3 | C-DROP(WAIT 타임아웃 뒤 접근 버림) 경로는 어떤 벤치도 안 지난다 | R:205-216 | cpuvis에 ack 타임아웃 op 추가 검토 |
| H4 | 헤더 로드는 프레임당 1슬롯(서비스 창) + 재생 중 슬롯의 즉시 스톨. 한꺼번에 24슬롯의 웨이브 번호를 쓰면 무음 슬롯의 헤더는 최대 24프레임(544 µs)이 걸려 LD(77.6 µs)보다 늦다. 그동안 필드 5-9 읽기는 옛 값 | E:1242, 1271-1281 | P2 설계: 헤더 로드를 슬롯 마이크로시퀀스나 서비스 창 여러 개로 |
| H5 | FM 쪽(F8h 믹스, OPL3 상태/타이머 실제 속도)은 이 하네스 밖. cpuvis의 OPL3는 타이머 스텁(clk_sdram 구동) | tb/opl3_stub.sv | P6 |
| H6 | I7(전부 무음일 때 openMSX의 진행 정지)를 보는 시나리오가 없다 | — | 필요하면 ref278 대비 시나리오 |
| H7 | 실제 소프트웨어 레지스터 트레이스(MoonBlaster, vgmplay, OPL4 데모)는 이번에 수집하지 않았다(PLAN P0의 일부) | — | P2 전에 openMSX에서 수집 |
