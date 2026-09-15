# ASO MoonSound BGM 무음 — OPL2 모드 뱅크1 별칭 누락 (20260915, 조사 완료·RTL 미적용)

## 결론
ASO는 `105h=00`(NEW=0, OPL2 모드)로 두고 BGM을 **뱅크1 포트(C6/C7)** 로 씀 → 칩/openMSX는 NEW=0일 때
뱅크1 쓰기를 **뱅크0으로 되돌림**(105h만 예외). 우리 `ymf278b_regs.sv`는 뱅크 비트를 그대로 넘겨
뱅크1 채널(악기 없음·C0 cha/chb=0 → `channels.sv:243`에서 출력 0)로 감 → BGM 무음. 효과음은 뱅크0 직접 쓰기라 생존.
A-Z80 무관(20260913 T80 시절부터 존재).

## 근거 (openMSX, 사용자 창 소켓, 상태 `aso_bgm_before_claude`로 보존·복원)
- 타이틀 20s I/O 로그(`research/aso_bgm/run1.log`): 뱅크1에 `04=80, 05=00` 후 `A6–A8/B6–B8/53–55`만 씀,
  키온 ~100ms 간격 = BGM. MSX-Music·웨이브 쓰기 0.
- 채널 녹음: FM ch7–9(뱅크0 6–8) t=0부터 연속, 뱅크1 ch10–18 **openMSX에서도 무음**.
- openMSX 레지스터 스냅샷: 뱅크1 512중 0x100–0x1FF 전부 0, 뱅크0 `B6–B8=2D/31/25`(키온) = 별칭 확인.
- 규칙 소스: openMSX `YMF262::writeReg` — `if (!OPL3_mode && r != 0x105) r &= ~0x100;` (2003 moonsound 도입부터).
  YMF278B.cc FM 쓰기가 이 함수를 경유. 읽기는 raw latch.

## 시뮬 (verilator, 합성 파일 목록 = `rtl/sound/sound.qip` 그대로, `research/aso_bgm/`)
| 검사 | 현재 RTL | 패치 |
|---|---|---|
| S0 프리로드 + 20s 로그 전체 재생 → OPL3로 나간 쓰기 미러 vs openMSX S1 | 불일치 5 (053/054 stale, 153–155 오착) | **0** |
| 키온 해제 S0 + 첫 0.35s(÷4 압축) 재생, mean\|L\| | 8.9 (바닥잡음) | **1145** (peak 4800) |
| 대조: NEW=1 뱅크1 채널 음 | 4550.4 | 4550.4 (동일) |
| 기존 `tb_opl4_detect` | PASS | PASS |

## 제안 수정 (`research/aso_bgm/opl2_alias.patch`, 한 파일)
`ymf278b_regs.sv`: 로컬 `opl3_new`(105h bit0 미러, 리셋 0) +
`fm_wr_addr = (latch[8] && !opl3_new && latch[7:0]!=05) ? {0,latch[7:0]} : latch` 를 쓰기 주소·fm_shadow 쓰기에 사용.
읽기는 raw latch 유지(openMSX 동일). 부수효과: NEW=0에서 뱅크1 `04h` 쓰기가 타이머/IRQ 레지스터(004h)로 감(openMSX 동일).

## 남은 것
- 실기: 빌드 → ASO 타이틀·인게임 BGM, 회귀(MoonSound 곡/MBWave 검출/GoFigure/vgmplay OPL4).
- 미확인: 실칩 YMF278B 동작은 openMSX 모델에만 근거(MAME/DOSBox 대조는 워크트리 밖이라 이번엔 안 봄).

## 추가 조사: 다른 뱅크/모드 거동 (20260915)
openMSX `YMF262.cc` 전수 대조 → 차이 후보를 **양쪽 실측**(RTL=verilator 패치본, openMSX=격리 홈 헤드리스 인스턴스,
같은 쓰기 시퀀스, 대조군 포함). 스크립트 `research/aso_bgm/{fmtest.tcl,t*.txt}`.

| # | 시나리오 | openMSX | RTL | 판정 |
|---|---|---|---|---|
| 1 | NEW=0에서 뱅크1 포트 쓰기 | 뱅크0으로 | 뱅크1로 | **ASO 원인**, 패치 있음 |
| 2 | 104h=01 남긴 채 NEW=0, ch3 2-op 키온 | ch3 소리(8611) — OPL2선 4-op 무효 | **무음**(0) | 차이. 대조(104h=0) 둘 다 소리 |
| 3 | NEW=0에서 C0=00 → NEW=1 → 키온 | 소리 — 팬은 C0 쓸 때 래치(OPL2면 전부 ON) | **무음** | 차이 |
| 4 | NEW=1에서 C0=00 → NEW=0 → 키온 | 무음 — 래치 유지 | **소리** | 차이 |
| 5 | NEW=1에서 E3=04 → NEW=0 | 파형4 유지(neg 26%) | 파형0(neg 49%) | 차이 — 파형 마스크도 쓸 때 래치 |
| 6 | NEW=0에서 E3=06 → NEW=1 | 파형2(neg 0%) | 파형6(사각) | 차이 |

- RTL 쪽 원인: `channels.sv` 출력 가산이 `!is_new`를 매 샘플 동적 평가(2~4), `control_operators.sv`의 4-op 쌍 선택이
  `is_new` 무관(2), `phase_generator.sv:151` `ws[2] && is_new` 동적(5·6).
  openMSX 주석은 3~6을 "tested/verified on real YMF262"라 함(예외 "unless when ...." 미기재).
- 2~6은 **실행 중 NEW를 바꾸면서 C0/E0를 다시 안 쓰는** 경우에만 드러남. 보통 드라이버는 초기화 때 NEW를 한 번 정함 → 실사용 영향 미확인·낮음.
  ⚠ 1번 패치 후엔 NEW=0 프로그램의 뱅크1 `04h` 쓰기가 더는 connection_sel을 건드리지 않음(ASO는 04=80을 씀 → 기존엔 우연히 0으로 지움).
  리셋 후엔 connection_sel=0이라 무관.
- 일치 확인(코드): 타이머 02–04·NTS 08·BD/리듬은 뱅크0만, 상태 읽기 C4/C6 동일, A9–AF/B9–BF/C9–CF 무시.
- 모드 무관 차이(코드만): NEW2 서명(02h) — openMSX는 리셋당 1회("verified on real YMF278"), RTL은 NEW2 상승마다 재무장.
  리셋 시 104h/105h — openMSX는 안 지움("FIX IT"), RTL은 지움(RTL 쪽이 타당).
- 계측 사고 1건: 첫 파형 시뮬이 자극 생성 셸함수의 `set --` 인자 덮어쓰기로 NEW=0·E3 공백이 되어 "OPL3 파형4~7 불능"으로 보였음 →
  is_new 프로브로 잡음. 재생성 후 위 표.

## vgmplay-legacy 대조 (20260916, `research/aso_bgm/vgmplay/`, 커밋 8262c68)
- `ymf278b.c`의 FM은 포트 0~3을 MAME 계열 `ymf262.c`에 그대로 넘김. 자체 뱅크 로직은 없음: 뱅크0 02~04 가로채 버림(타이머 미구현),
  105h는 NEW2 비트 떼고 전달. 헤더에 "Backport to MAME-style C from OpenMSX"(2010) → **독립 출처 아님**.
- **#1 근거 강화**: `ymf262.c OPL3Write` 주소포트1 — "verified on real YMF262: in OPL2 mode register set#2 writes go to set#1,
  verified on registers from set#2: 0x01, 0x04, 0x20-0xef. The only exception is register 0x05". 데이터포트는 "A1 ignored"(우리와 같음).
  MAME는 주소 쓸 때, openMSX는 데이터 쓸 때 판정 — NEW는 래치=105h일 때만 바뀌므로 관측 차이 없음.
- **#2~6**: `ymf262.c`도 C0 팬·E0 파형을 쓸 때 래치, 4-op은 OPL3 모드에서만. `pan_ctrl_value`/`waveform_number`를 저장만 하고
  모드 전환 때 재적용하지 않음. "tested on real YMF262" 주석의 원출처가 여기(MAME) — openMSX는 이를 물려받음.
  즉 근거는 **한 저자의 실칩 시험 1건**, 두 에뮬이 공유.
- OPL4 고유 부분은 vgmplay가 openMSX보다 덜 정확: NEW2=0에서도 웨이브 선택 래치 기록(openMSX "Verified on real YMF278":
  선택·쓰기 모두 무시 — 우리 RTL은 openMSX 쪽과 같음), BUSY/LOAD 항상 0, NEW2 서명 없음, FM에 플레이어 임의 −3dB.
  → OPL4 기준 모델로는 openMSX 유지.
