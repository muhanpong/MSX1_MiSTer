# YMF278B PCM Engine v3 — Sequential Slot Machine (from-scratch redesign)

2026-06-11. v2(SCSP식 4단 병렬 파이프라인)의 freeze/복잡도 문제로 파이프라인을 처음부터 재설계.
**함수 단위 코드(alu_pkg, eg_pkg)와 레지스터 디코드/HF 백필/key_retrig/TL ramp 의미론은 v2에서 그대로 가져옴.**

## v2의 실패 모드 (제거 대상)
1. **stuck-BUSY**: `cpu_issue_ok = hf_window_open && hf_state==IDLE && b_state==IDLE/DONE && !outstanding`,
   `hf_window_open = (frame tail) || (mode && busy)` — 4중 FSM 결합. 어느 하나 어긋나면
   `cpu_mem_busy` 영구 1 → BUSY 폴링 소프트웨어(vgmplay OPL4) 무한스핀 = freeze (검출기 전부 소등과 일치).
2. 4단 병렬 스테이지(A/B/C/D) + 윈도우-안정 가정 → SDC 멀티사이클 제약 7쌍 필요, 배치 민감.
3. 거대 조합 체인(oct→calc_step→…→byte_addr)을 레지스터 쪼개기로 땜질.

## v3 원칙
- **고정 시간표**: 프레임 1948클럭(@85.909MHz → 44.1kHz) = 슬롯 24×72 + 서비스 윈도우 220.
- **슬롯당 완전 순차 FSM**: 한 번에 한 슬롯만, 단계당 1클럭(연산 1-2개) — 병렬 스테이지/스테이지 레지스터/멀티사이클 SDC 전부 불필요.
- **CPU mem op는 무조건 매 프레임 서비스** (서비스 윈도우 최우선) + 슬롯 윈도우 잔여시간 기회 서비스.
  → **BUSY ≤ 1프레임(22.7µs) 구조적 보장**. 모드/타FSM과 무결합.
- 헤더 페치(HF): 서비스 윈도우에서 프레임당 1슬롯, 16-bit 워드 7회 읽기.
- SDRAM 읽기는 항상 블로킹(req→valid 대기) — read-drop 클래스 원천 제거.
- EG_OFF & !retrig 슬롯은 스킵(침묵, SDRAM 접근 없음) — v2와 동일.

## 슬롯 윈도우 시퀀스 (≤72클럭)
LOAD(1) → VIB(1) → STEP(1) → ADV(1) → POSB(1) → ADDR(1) →
FETCH(워드 2~4회 × ~13) → DECODE(1) → INTERP(1) → EGRATE(1) → EGSTEP(1) →
GAIN(1) → MUL1(1) → MUL2(1) → PAN(1) → ACC+writeback(1) → DONE(잔여: CPU op 기회 서비스)

워드 페치: A샘플 = wA0=a0>>1, wA0+1 (a0..a0+3 커버 ⊇ a0,a1,a2). B샘플 = 같은 영역이면 재사용,
아니면 wB0=b0>>1, wB0+1. 최악 4회(루프 랩/12-bit 홀수 straddle), 보통 2-3회.

## v2에서 보존한 hardware-검증 의미론
- key_retrig 2소스(field4 keyon-edge / field0 wave-overwrite-while-keyon), hf_pending 게이트, 소비 시점
- HF 백필(헤더 byte7-11 → lfo/vib/ar/d1r/dl/d2r/rc/rr/am), 주소식(wave<384 || hdr==0)
- EG 전이 전부(키온 always-restart, rate63 instant, REL 제외 키오프, DL→SUS/OFF), damp/prvb(calc_decay_rate)
- env+TL 2단 독립 게인(각자 0x280 클립), TL ramp(9샘플 주기 step 0/1/2), AM/VIB(reciprocal 버전)
- CPU mem 자동증가 규칙(read=06H읽기시, write=issue시), reg05 프리페치, reg02 readback(devID 001)
- 출력: pcm_shift(OSD pcm_vol) + pcm_mix_gain(reg F9), 24-bit 누산 → 16-bit 포화
