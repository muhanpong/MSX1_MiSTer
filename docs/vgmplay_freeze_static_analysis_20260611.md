# YMF278B FPGA — vgmplay 웨이브 테이블 로드/재생 시 Freeze 정적 분석 보고

- **작성일**: 2026-06-11
- **대상**: `rtl/peripheral/SOUND/ymf278b_fpga` (브랜치 `moonsound-wip`)
- **증상**: vgmplay로 OPL4 PCM 모듈에 웨이브 테이블을 로드하고 재생하면 시스템이 freeze 됨.
  동일 동작을 openMSX(YMF278B/MoonSound 레퍼런스 구현)에서 수행하면 문제 없음.
- **분석 방법**: RTL 정적 분석 (사이클 단위 시그널 트레이스, 시뮬레이션/하드웨어 실측 없이 코드만으로 도출)

---

## 결론 (TL;DR)

**근본 원인은 PCM 엔진의 SDRAM 포트 중재(arbitration) 프로토콜 위반이다.**
Header-Fetch(HF) FSM과 CPU 메모리 FSM이 "1-cycle 펄스를 쏘고 잊어버리는(pulse-and-forget)" 방식으로
요청을 발행하는데, msx.sv의 ch4 브리지는 **IDLE 상태에서만 요청을 수락**한다.
`mem_busy` 가드는 Stage B에만 있고 HF·CPU 경로에는 없다.

그 결과 **CPU 메모리 write 트랜잭션이 비행 중일 때 HF가 read 요청을 발행하면 그 요청이 조용히
버려지고, write 트랜잭션은 `mem_rd_valid`를 발생시키지 않으므로 HF FSM이 `HF_WAIT`에서 영원히
멈춘다.** 이 교착은 vgmplay의 액세스 패턴(슬롯 wave 레지스터 write 직후 reg 0x02 mode=1 +
reg 0x06 `otir` 블래스트)에서 결정론적으로 발생하며, 이후 상태 레지스터의 BUSY(D0) 비트가
영구히 1로 고정되어 시스템이 freeze 된다.

openMSX는 모든 동작이 순차적 C++ 함수 호출(버스 중재 자체가 없음)이라 이 클래스의 버그가
원천적으로 존재하지 않는다.

---

## 1. 구조 배경

SDRAM 포트(ch4)에는 세 요청자가 있다 (`ymf278_pcm_engine.sv:1828-1865`의 중재기):

| 요청자 | 발행 가드 | 요청 방식 |
|---|---|---|
| HF FSM (`HF_REQ`) | **없음** | 1-cycle `mem_rd_en` 펄스 |
| Stage B (`B_ISSUE`) | `!mem_busy` ✔ | 1-cycle 펄스 |
| CPU rd/wr (`cpu_*_issue_now`) | **없음** | 1-cycle 펄스 |

msx.sv의 브리지(`msx.sv:699-720`)는 `pcm_state==IDLE`에서만 `ms_mem_rd_req`의 상승 에지를
검출한다. **busy 중에 도착한 펄스는 흔적 없이 사라진다.**

또한 `ms_mem_rd_valid = (pcm_state==3) && !pcm_is_write` (`msx.sv:724`) —
**write 트랜잭션은 valid를 절대 만들지 않는다.**

관련 신호 정의:

- `hf_window_open = (frame_cycle >= PIPELINE_END) || cpu_mem_active` (`ymf278_pcm_engine.sv:1550`)
- `cpu_mem_active = reg02_mem_access_mode & cpu_mem_busy` (`ymf278_pcm_engine.sv:1810`)
- `cpu_mem_busy = cpu_rd_pend | cpu_wr_pend | cpu_rd_outstanding` (`ymf278_pcm_engine.sv:1808`)
- `cpu_issue_ok = hf_window_open && (hf_state == HF_IDLE) && (b_state == B_IDLE || b_state == B_DONE) && !cpu_rd_outstanding` (`ymf278_pcm_engine.sv:1742-1745`)
- `hf_pick_now = (hf_state == HF_IDLE) && hf_window_open && hf_found` (`ymf278_pcm_engine.sv:1632`)

핵심 관찰: **reg 0x06 write가 pending이 되는 순간(`cpu_wr_pend=1`) `cpu_mem_active`를 통해
HF 윈도우가 프레임 중간 임의 시점에 즉시 열린다.** 이때 `hf_pending`이 하나라도 서 있으면
(직전 ~1프레임 = 22.7µs 내 wave 번호 레지스터 write가 있었거나, 윈도우가 닫혀 있어 적체된 경우)
`hf_pick_now`와 `cpu_wr_issue_now`가 **같은 사이클에 동시 발화**한다.

---

## 2. 핵심 결함: HF ↔ CPU-write 충돌 → `HF_WAIT` 영구 교착

### 2.1 사이클 단위 트레이스

전제 (사이클 T의 상태): `hf_state==HF_IDLE`, `hf_found=1`, `cpu_wr_pend=1`,
`reg02_mem_access_mode=1`, `b_state==B_DONE`, `cpu_rd_outstanding=0`.

| 사이클 | 사건 |
|---|---|
| **T** | `cpu_mem_active=1` → 윈도우 열림. `hf_pick_now=1`과 `cpu_wr_issue_now=1`이 **동시 발화** (`cpu_wr_issue_now`는 `hf_state==HF_IDLE`을 조건으로 사용하므로 서로를 배제하지 못함) |
| **T+1** | 중재기가 CPU write 발행: `mem_wr_en=1`, `mem_addr=cpu_mem_adr`. 동시에 `hf_state→HF_REQ`, `cpu_wr_pend→0` |
| **T+2** | 중재기가 HF read 발행 — **`mem_addr`를 HF 헤더 주소로 덮어씀**. 브리지는 이 사이클에 state 1(write, `pcm_is_write=1`)로 진입하며 `pcm_sdram_req`를 올림. SDRAM ch4는 바로 이 사이클의 `ch4_addr`를 래치(`sdram.sv:179-183`) → **CPU의 write 데이터가 HF 헤더 주소에 기록됨 (메모리 오염)**. HF의 `mem_rd_en` 펄스는 브리지가 busy(state≠IDLE)라 **무시됨** |
| **T+3 이후** | write 트랜잭션 완료. `ms_mem_rd_valid`는 write이므로 발생하지 않음. `hf_state=HF_WAIT`은 `mem_rd_valid`를 영원히 대기 — **HF_WAIT에는 타임아웃이 없음 → 영구 교착** |

같은 사이클이 아니어도, **write 트랜잭션이 비행 중인 ~10-15 사이클 구간 안에서 HF가 pick되면
동일하게 요청이 드롭되어 같은 교착에 빠진다.**

### 2.2 Freeze로 이어지는 체인

웨이브 테이블 **업로드 단계에서는 모든 슬롯이 `EG_OFF`** 다
(리셋값 `env_state=0` = `EG_OFF`, `ymf278_pcm_eg_step.sv:13`).
`EG_OFF` 슬롯은 Stage B가 SDRAM read를 전혀 발행하지 않으므로(`ymf278_pcm_engine.sv:599`의
skip 경로) **HF를 구출할 `mem_rd_valid`가 영원히 오지 않는다.** 그러면:

1. `cpu_issue_ok`는 `hf_state==HF_IDLE`을 요구 → 이후 모든 reg 0x06 write의 `cpu_wr_pend`가
   영구히 1 → `cpu_mem_busy` 영구 1.
2. `ymf278b_regs.sv:106`: `busy = (busy_cnt != 0) | pcm_cpu_mem_busy` →
   **상태 레지스터 BUSY(D0) 비트 영구 1**. BUSY를 폴링하는 소프트웨어는 즉시 무한 루프 =
   **하드 freeze** (CPU는 M1을 계속 돌리며 폴링 루프에 갇힘).
3. `pcm_wr_wait`(`ymf278b_regs.sv:145-150`)의 deferred ack가 영원히 나가지 않음 →
   이후 모든 wave-memory write는 msx.sv의 600-cycle WAIT 타임아웃(≈28µs, `msx.sv:631,644`)으로만
   풀리고, **데이터는 SDRAM에 전혀 기록되지 않음** (업로드 내용 전부 유실).
4. `cpu_mem_active`가 stuck 1 → `dispatch_now` 영구 억제(`ymf278_pcm_engine.sv:231`) →
   **이후 key-on을 해도 슬롯이 절대 디스패치되지 않음** — PCM 엔진 전체 사망이 재생 단계까지
   영구 지속.

**재생 중**(슬롯 활성)에 같은 충돌이 나면 Stage B의 valid를 HF가 가로채(`HF_WAIT`은 raw
`mem_rd_valid`를 무조건 소비, `ymf278_pcm_engine.sv:1574`) 일시적으로 교착이 풀리지만,
그 대가로 **헤더 byte0 오염 + write가 엉뚱한 주소에 기록되는 데이터 오염**이 발생한다.

### 2.3 vgmplay에서 결정론적으로 재현되는 이유

vgmplay의 OPL4 초기화/로드 시퀀스는 정확히 트리거 패턴이다:

1. 초기화에서 24개 슬롯의 wave 번호 레지스터(0x08-0x37)를 write → `hf_pending` 다수 set.
   HF는 프레임 꼬리(220 cycle/프레임)에서 한 슬롯씩 서비스하므로 전부 비우는 데 수백 µs 필요.
2. 그 직후 reg 0x02 mode=1, reg 0x03/04/05 주소 설정, reg 0x06 `otir` 업로드 시작.
3. 첫 reg 0x06 write가 `cpu_wr_pend`를 세우는 순간 → 윈도우 즉시 개방 → 잔존 `hf_pending`과
   충돌 → **교착**.

또한 엔진 주석(`ymf278_pcm_engine.sv:156-161`)에 따르면 실제 플레이어가 재생 중에도
mode 비트를 켠 채로 두는 것이 관찰되었으므로, 재생 중 스트리밍 RAM write에서도 동일 충돌이
상시 발생 가능하다.

---

## 3. 부수 결함 (정적으로 확인됨)

### 3.1 valid 소유자 미태깅 (응답 가로채기)

`HF_WAIT`은 raw `mem_rd_valid`를 무조건 소비한다(`ymf278_pcm_engine.sv:1574`).
Stage B/CPU read의 응답을 HF가 가로채면 `hf_buf`에 샘플 바이트가 헤더로 들어가고, 반대로
`mem_rd_valid_b`는 `hf_active`로 게이팅되어(`ymf278_pcm_engine.sv:556`) Stage B가 자기 데이터를
받지 못한다. **트랜잭션에 소유자 태그가 없는 것이 구조적 원인**이며, HF가 프레임 꼬리(220 cycle)
안에 12바이트 fetch를 끝내지 못하고 다음 프레임의 dispatch 구간으로 흘러넘칠 때도 같은
가로채기/오염이 발생한다.

### 3.2 `hf_pick_now` vs FSM 천이 조건 불일치 → `hf_pending` 유실

- FSM 천이(`ymf278_pcm_engine.sv:1562`): `hf_window_open && hf_found && !cpu_rd_outstanding`
- `hf_pick_now`(`ymf278_pcm_engine.sv:1632`) 및 `hf_cur_wave` 로드(`:1603`):
  **`!cpu_rd_outstanding` 조건이 빠져 있음**

`cpu_rd_outstanding=1`인 동안 윈도우가 열려 있으면 `hf_pick_now=1`이 되어
**`hf_pending` 비트가 클리어되지만 FSM은 HF_IDLE을 떠나지 않는다** → 해당 슬롯의 헤더가
fetch 없이 영영 로드되지 않음 (무음/잘못된 음).

### 3.3 `mem_addr` 안정성 계약 위반

중재기 주석(`ymf278_pcm_engine.sv:1835-1842`) 스스로 "주소는 다음 issue까지 유지되어야 한다"고
명시하지만(브리지가 1사이클 뒤 천이, SDRAM이 다시 1사이클 뒤 주소 샘플), 1-2 사이클 뒤
다른 요청자가 issue하면 SDRAM이 주소를 샘플하기 전에 `mem_addr`이 덮어써진다
(§2.1의 T+2 — write가 HF 주소로 들어가는 경로).

### 3.4 WAIT ack 패리티 desync

타임아웃(`msx.sv:644`)으로 `ms_io_pending`이 풀린 뒤 늦게 도착하는 `ms_ack_toggle` 에지는
**다음** I/O의 WAIT를 즉시 풀어버린다. 한 번의 타임아웃 이후 ack 패리티가 한 단계 밀린 채로
스로틀이 무력화되어, WAIT 핸드셰이크가 막으려던 원래의 race
(`cpu_wr_data_latch` 덮어쓰기, `ymf278_pcm_engine.sv:1777-1780`)가 되살아난다.

---

## 4. openMSX에 이 버그가 없는 이유

openMSX(`YMF278.cc`)는 `writeReg(wave#)` 안에서 헤더 12바이트를 **동기적으로** 읽고,
reg 0x06 write도 함수 호출 하나로 완결된다. "동시에 진행 중인 메모리 트랜잭션"이라는 개념
자체가 없으므로 중재/핸드셰이크 버그 클래스가 존재할 수 없다.
FPGA 포팅에서 새로 도입된 공유-버스 중재 계층(HF FSM / Stage B / CPU mem FSM ↔ ch4 브리지)이
버그의 발생지다.

---

## 5. 권장 수정 (우선순위순)

1. **모든 요청자에 `!mem_busy` 가드 적용 + pend 비트는 수락 확인 후 클리어**
   - `HF_REQ`를 `B_ISSUE`처럼 `if (!mem_busy)`에서 홀드.
   - `cpu_wr_issue_now` / `cpu_rd_issue_now`에도 `!mem_busy` 추가.
   - `cpu_wr_pend` / `cpu_rd_pend`는 브리지가 IDLE→ACTIVE로 천이한 것을 확인한 뒤에만 클리어.
2. **트랜잭션 소유자 태깅**
   - issue 시 2비트 owner(B / HF / CPU_RD)를 래치하고 `mem_rd_valid`를 소유자에게만 라우팅.
   - `hf_active` / `cpu_rd_outstanding` 기반의 휴리스틱 valid 게이팅을 대체.
3. **HF 시작 조건 강화 + 워치독**
   - `hf_pick_now`에 FSM과 동일한 조건(`!cpu_rd_outstanding`, 가능하면
     `!cpu_wr_pend && !mem_busy`)을 적용해 §3.2 불일치 제거.
   - `HF_WAIT`에 타임아웃(예: 256 cycle) → 재발행 또는 `HF_IDLE` 복귀(이때 `hf_pending` 재설정).
4. **타임아웃 desync 해소**
   - msx.sv에서 타임아웃으로 pending을 풀 때 ack 패리티를 재동기화
     (예: 타임아웃 시 `ms_ack_sync`를 현재 토글 값으로 강제 일치).

---

## 6. 검증 방법 제안

기존 `tb_bridge_realism.sv` 스타일의 브리지 모델 위에서
"wave 레지스터 write → 수 µs 내 reg 0x02 mode=1 + reg 0x05/0x06 write" 시퀀스를 주입하면
`HF_WAIT` 고착과 `cpu_mem_busy` stuck을 시뮬레이션에서 그대로 재현할 수 있다.

이 진단은 현재 커밋된 디버그 검출기와도 부합한다 — 이 freeze에서는:

- `dbg_wait_stuck` **꺼짐** (WAIT는 28µs 타임아웃으로 매번 풀림)
- `dbg_cpu_nom1` **꺼짐** (CPU는 BUSY 폴링 루프에서 M1을 계속 수행)
- 상태 읽기의 **D0(BUSY)만 영구 1**

로 관측될 것이다.

---

## 부록: 핵심 코드 위치 요약

| 파일:라인 | 내용 |
|---|---|
| `ymf278_pcm_engine.sv:1550` | `hf_window_open` — `cpu_mem_active`로 프레임 중간 개방 |
| `ymf278_pcm_engine.sv:1562` | HF_IDLE 천이 조건 (`!cpu_rd_outstanding` 포함) |
| `ymf278_pcm_engine.sv:1632` | `hf_pick_now` (`!cpu_rd_outstanding` 누락 — §3.2) |
| `ymf278_pcm_engine.sv:1569-1573` | `HF_REQ` — `mem_busy` 가드 없이 무조건 발행 |
| `ymf278_pcm_engine.sv:1574` | `HF_WAIT` — raw valid 소비, 타임아웃 없음 |
| `ymf278_pcm_engine.sv:1742-1747` | `cpu_issue_ok` / `cpu_wr_issue_now` — `mem_busy` 가드 없음 |
| `ymf278_pcm_engine.sv:1828-1865` | SDRAM 포트 중재기 (`mem_addr` 홀드 계약 주석 포함) |
| `ymf278_pcm_engine.sv:599` | EG_OFF 슬롯 read skip (업로드 중 구출-valid 부재의 원인) |
| `ymf278b_regs.sv:106` | `busy` 상태비트 = `busy_cnt | pcm_cpu_mem_busy` |
| `ymf278b_regs.sv:145-150` | `pcm_wr_wait` deferred ack (BUSY 해제 대기) |
| `msx.sv:699-720` | ch4 브리지 FSM — IDLE에서만 요청 수락 |
| `msx.sv:724` | `ms_mem_rd_valid` — write는 valid를 만들지 않음 |
| `msx.sv:631,644` | WAIT 600-cycle 타임아웃 / ack 패리티 desync 지점 |
| `sdram.sv:179-183` | ch4 주소 래치 시점 (req 상승 에지 사이클) |
| `ymf278_pcm_eg_step.sv:13` | `EG_OFF = 0` (리셋 상태) |
