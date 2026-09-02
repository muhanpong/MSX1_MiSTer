# 핸드오프 — Hi no Tori 크래시 조사 (2026-09-02 새벽)

세션이 컨텍스트 한계에 가까워 인계한다. 상대는 타세션 **`hinotori-fb`**(피어)이고,
그쪽이 롬(60Hz 패치)을, 이쪽이 코어·계측·판독을 맡는 분업이다.

---

## 1. 결론부터 — 지금 어디까지 왔나

**증상**: Hi no Tori 60Hz 패치 롬(`b1m55-unified`)이 확률적으로 크래시.

**확정된 것**
- 크래시는 **CPU 정지가 아니라 `RST 38` 무한 스핀**(또는 그 변종)이다.
  미매핑 읽기가 `0xFF`를 반환하고(`rtl/peripheral/slots/msx_slots.sv:211`), `0xFF`가
  곧 `RST 38`이라, 페이지0이 BIOS를 벗어나는 순간 CPU가 0038에서 영원히 돈다.
- 방아쇠는 **BIOS 슬롯 루틴이 포트 A8에 치명적인 슬롯맵 값을 쓰는 것**이다.
  실측된 치명 쓰기: `W@F382=01`(4회, F1XV), `W@01D4/01E7/01EE=00`, `W@0323=00`,
  `W@F396=00`, `W@01C5=14`.
- **코어는 무죄에 가깝다.** PPI 모드워드·A8 읽기 경로·AB 포트 전부 건강-크래시 캡처에서
  동일. 자세한 근거는 아래 4절.
- **머신 의존이 아니다.** F1XV(맵 D4)와 CPC-400S(맵 0x14) 양쪽에서 재현된다.
  차이는 생존성뿐 — F1XV는 RAM이 슬롯3이라 치명값이 스택까지 지워 웨지로 고착,
  CPC-400S는 RAM이 슬롯0이라 카트만 사라져 자가 재부팅된다.

**남은 질문 하나**
> **무엇이 난동을 시작시키나 — 즉 무엇이 BIOS 슬롯 코드에 쓰레기 레지스터/스택을 들고
> 들어가나.**

피어의 최신 가설 둘(둘 다 트레이스로 판별 가능):
1. **0200 직접 진입** — `CALL F380`은 시스템 전체에 BIOS 0200 한 곳뿐이고, 0200 직전
   `01FB IN A,(A8)`과 쓰기 사이에 다른 A8 I/O가 없다. 우리 링에 **읽기가 없으므로**
   0200(±2)로 직접 뛰었고 A=01을 이미 들고 있었다는 귀결.
2. **스택 언더런** — 0320 블록이 끝에서 `POP AF`/`RET`로 스택을 두 번 꺼낸다.
   정상 게임플레이 SP 범위는 **F0AE-F0D6**인데, 우리 하드웨어 spin-SP는 **F168**,
   피어 openMSX 재현은 **F16C** — **정상보다 ~150바이트 위**다. 스택은 아래로 자라니
   SP가 위로 갔다는 건 POP 초과 = 언더런이고, 남의 데이터를 복귀주소로 팝하고 있다는 뜻.

---

## 2. 지금 당장 할 일 (막힌 지점)

**SignalTap 캡처가 유일한 다음 계기**다. 링(3칸)은 소진됐고 슬라이드 트램폴린은 이
경로에 없다.

### 진행 상태 — ◆ 2026-09-03 해결. 계측 빌드 배포 완료.
- `rtl/msx.sv`의 48비트 CPU 버스 레지스터 `stp_data`는 **`(* preserve, noprune *)`**
  로 보존된다.
- **`MSX1.stp` 완성**(GUI 작성). 48노드 / acq_clk `emu:emu|msx:MSX|clk21m` /
  depth 16384 / position post / storage qualifier continuous / trigger-in disabled /
  trigger 18항 = `a==0x0320 && ~m1_n && ~mreq_n`.
- `MSX1.qsf`에 Quartus가 SLD 배선을 생성했다(`acq_data_in` 48 + `acq_trigger_in` 48 +
  `acq_clk`, `SLD_SAMPLE_DEPTH=16384`, `SLD_FILE db/MSX1_auto_stripped.stp`).
- **배포: `MSX1_20260903a_stp.rbf`** (md5 `a246545f5ee529290143f7cad2e80760`,
  192.168.1.86 확인). RAM 351→**447/553**, block memory +786,432 bits(=16384×48),
  ALM 73%, worst setup **+0.624 ns**(전 슬랙 양수).

### 다음 단계
1. Quartus GUI에서 `MSX1.stp` 열고 JTAG 연결 → 게임 진입 **후** 수동 arm
2. 크래시 → CSV export → 피어에게 경로 전달
3. 판독은 아래 "트레이스 판독 체크리스트" + 피어의 `tracediff.py`

### ⚠️ 이 단계에서 실제로 겪은 함정 두 개 (2026-09-03)
- **smart recompile이 A&S를 건너뛴다.** `quartus_sh --flow compile`이
  `Info (293003): Smart recompilation skipped module Analysis & Synthesis`를 내고
  **빈 .stp로 합성된 옛 넷리스트를 그대로 재사용**했다. fit까지 정상 완주하므로
  로그만 봐서는 성공처럼 보인다. **검증 지표: `block memory bits`가 depth×width 만큼
  늘었는가**(여기선 2,331,610 → 3,118,042 = +786,432) + `map.rpt`에
  `sld_signaltap:auto_signaltap_N` 인스턴스가 있는가. RAM 블록 수가 그대로면 실패다.
  회피책은 `quartus_map MSX1 -c MSX1`을 먼저 명시 실행(그다음 `make build`).
- **Quartus GUI가 `MSX1.qsf`를 덮어쓴다.** 빌드 도중에도 쓴다. 손으로 살린
  어세스먼트를 주석으로 되돌리고, 경로를 `../../Documents/github/MSX1_MiSTer/MSX1.stp`
  (프로젝트 기준 해석 불가)로 바꿔 넣었다. **GUI를 닫은 뒤에 qsf를 손볼 것.**

### 트리거 (피어 합의)
| 순위 | 조건 | 근거 |
|---|---|---|
| 1 | 주소=`0320`, `m1_n`=0, `mreq_n`=0 | 게임 중 슬롯 기계장치 호출은 0회이므로 이 페치 자체가 이상현상. 치명 쓰기보다 ~20명령 앞섬 |
| 2 | 주소 하위=`A8`, `iorq_n`=0, `wr_n`=0, `d_from_cpu`=`01` | 사슬 끝 확증용. F1XV에서 4회 재현된 서명 |

⚠️ **`a==F382`는 트리거로 쓸 수 없다** — F382는 PC지 버스 주소가 아니다.
I/O 사이클의 주소 버스 하위 바이트는 **포트 번호(A8)**, 상위는 A 레지스터다.

### 48비트 버스 배치 (`rtl/msx.sv`의 `stp_data`)
```
[15:0]  a (주소)      [23:16] d_from_cpu   [31:24] d_to_cpu
[32] wr_n  [33] rd_n  [34] iorq_n  [35] mreq_n  [36] m1_n  [37] wait_n
[45:38] ppi_out_a (슬롯맵)   [47:46] spare
```

### 트레이스 판독 체크리스트 (피어와 합의)
1. F382 쓰기 직전이 **CALL인가 RET인가** — 0200~0202 페치가 있으면 CALL, 스택 읽기
   2회면 RET
2. **SP가 F0D6를 넘어 올라간 시점** = 오염 기원
3. 0320 진입 직전 명령
4. 기지 이미지(BIOS 32K + 카트 256K + 피어 RAM 블롭)와 **처음 어긋나는 페치**
   — 피어의 `tracediff.py`가 자동 특정
5. 0320→F382 구간이 **연속인가** (중간에 인터럽트 수락 M1이 끼면 다른 병)

**깊이 한계**: 16384샘플 = 763 µs ≈ 600~700명령. (1)(2)는 잡히지만 오염 기원이 더
앞이면 버퍼 밖이다. 그때는 **m1-only storage qualifier**로 이력을 4~5배 늘린다 —
단, 큐얼리파이어는 컴파일 시점 하드웨어이므로 **GUI에서 켜고 저장한 뒤 재빌드** 필요
(그러면 Quartus가 올바른 XML을 직접 써준다).

---

## 3. 계측 도구 (이번 세션 산물)

### 디버그 오버레이 — `rtl/debug_overlay.sv`
`MOONSOUND_DIAG` 빌드에서 화면 좌측에 34밴드. **7라인/밴드, 주사선 왼쪽 밀착,
reg-probe도 패널 안에 편입**(PH=240). 각 행 16비트, 4 h_cnt/비트, MSB 좌측.

행 배치(위→아래, 0-index):
```
 0 ROM base   1 PCM valid   2 PCM level   3 NEW2   4 slot map   5 dead count
 6 freeze detectors (8세그)  7 pc_snap  8 pc_vec  9 pc_now  10 IM+I
11 watch_pc  12 watch{data,cnt}
13~18 A8 트랜잭션 링 (tx0 PC / tx0{val,rw} / tx1 PC / tx1{val,rw} / tx2 PC / tx2{val,rw})
19 spin 시작 시 SP      20 RST38 스핀 카운터    21 PPI{trap,live}
22 OUT(A8) PC           23 {A8값, 쓰기횟수}     24 ROSE {A8 읽기값, 00-읽기수}
25 난동 기원(미실행 RAM 첫 페치 직전 주소)      26 WHITE{MS,RV,ctrl,리셋수}
27 SPRING{AB모드셋값,횟수}  28 SALMON AB PC     29 JMP0
30~33 reg-probe 4행
```

### 판독기 — `tools/hinotori_rig/`
- **`readtrap.py`** — 캡처 1장을 픽셀 디코드해 `ok` / `*** CRASH` / `*** TRAPPED` 판정.
  `screenshot`은 **코어 원본 해상도**(예: 582×242, 1px=1유닛)로 저장되므로 네이티브
  경로가 기본이고 스케일러 캡처(≥600px)도 자동 분기.
- **`watch.sh`** — ~2초 주기로 보드에 `screenshot` → scp 회수 → 판독. 상태 변할 때만 로그.
  `rst`(리셋 카운터)로 세션 동일성 추적, 인게임 도달 전 프레임은 `boot-transient`로 강등.
- `rig.sh`, `keyinject.py` — **폐기 예정**. 자동 롬 로드는 이 코어에서 성립하지 않는다(4절).

---

## 4. 반드시 알아야 할 함정 (같은 실수 반복 금지)

### 계측기부터 검증할 것
이 세션 최대 교훈. 자세히는 메모리 `feedback-verify-the-detector-first`.
- **프리즈 검출기 8개 중 6개는 MoonSound IRQ가 서야만 카운트**한다
  (`irq_cnt`/`intack_cnt`/`iffoff_cnt`/`refuse_cnt`/GHOST/ACK-stop). 이 게임엔
  MoonSound IRQ가 없으므로 **구조적으로 못 울린다** = "off"는 무정보.
- **`noM1`은 `msx_pause` 게이팅이 없어 OSD 열기·ROM 로드마다 sticky 점등**했다.
  → 0901e에서 pause 게이팅 추가. 그 전 캡처의 "CPU 정지"는 전부 오독이었다.
- **PC 트랩이 Z80 리셋 벡터(PC=0000)에 자가 무장**해 부팅 때 래치를 소진했다.
  → `booted` 게이트 추가.
- **스핀 카운터는 ISR 중첩에도 증가한다**(0038 연속 페치). 이 빌드는 매 프레임 중첩하므로
  **작은 값은 정상**. 임계값 0x100 이상만 웨지로 판정할 것.
- **RAMPAGE(난동 기원)는 sticky-first**라, 무해한 진입이 먼저 걸리면 소진된다.
  실제로 피어의 옛 E7FF RET 경로가 이걸 태웠다.
- **정상 슬롯맵은 머신마다 다르다** (F1XV=D4, CPC-400S=0x14). 하드코딩 금지.

### MiSTer 보드 조작의 실제 능력
검증된 것과 아닌 것을 반드시 구분할 것.
- ✅ **`echo screenshot > /dev/MiSTer_cmd`** — 동작. 파일은
  `/media/fat/screenshots/MSX1/`. **코어 원본 해상도**로 저장.
- ✅ **키 주입** — `/dev/uinput` 직접 조작으로 **동작한다**(F12 OSD 토글 실증).
  단 장치 생성 후 **1.2초 정도 대기**해야 MiSTer가 hotplug를 인식한다.
- ❌ **`screenshot`은 OSD 레이어를 담지 않는다.** 눈으로 확인함. `/dev/fb0`은 리눅스
  콘솔이라 대안이 아니고, 바이너리에 다른 캡처 경로도 없다.
  → **메뉴를 보면서 조작하는 것은 불가능**하다. 맹목 시퀀스만 가능.
  → 다만 **⏸ 심벌**이 `msx_pause`(= `status[43] & OSD_STATUS` 포함)에 반응해
    코어 비디오에 그려지므로, **OSD 개폐 상태는 스크린샷으로 판정 가능**하다.
- ❌ **자동 롬 로드 실패.** MGL(`load_core`)도 `mbc`도 안 된다.
  MSX1은 컴퓨터 코어라 **슬롯 타입 + 매퍼 + 파일** 세 상태가 맞아야 하는데,
  MGL은 매퍼를 표현 못 하고 mbc는 자기가 아는 코어의 메뉴 구조를 전제로 개루프 키를 쏜다.
  `mbc`는 `/media/fat/Scripts/.MiSTer_SAM/mbc`에 있고 코어 표에 우리 `MSX1`이 없다.
  → **롬 로드는 사용자가 OSD에서 수동으로.** 이 결론을 뒤집으려 하지 말 것.
- 코어 설정은 `/media/fat/config/MSX1.CFG` **16바이트 = status 워드 전체**.
  마지막 로드된 머신팩은 `MSX1.f1`에 경로 문자열로 남는다.

### SignalTap 통합
- **손으로 쓴 `.stp`는 세 번 다 실패**했다: ①지어낸 `<trigger>` 요소 → GUI 크래시
  (`SDR_DATA_TRIGGER::get_last_trigger_level_latency_delay`, `m_is_basic_vec->size() > 0`)
  ②트리거 제거 → 같은 크래시(레벨 0개) ③트리거 복원 → Quartus가 파일을 아예 안 읽음.
  → **`.stp`는 GUI가 만들게 할 것.**
- 조합 wire의 `(* keep *)`은 무시된다. 팬아웃 없는 레지스터에는 **`noprune`**이 필요하다
  (`preserve`만으로는 부족). `(* preserve, noprune *)` 조합으로 해결됨.
- SignalTap TCL 제어 API는 **없다**(`::quartus::stp`가 주는 건 LAI용 두 명령뿐).
  트리거 설정·무장·캡처는 전부 GUI 전용.
- JTAG 체인은 살아 있다: `jtagconfig` → `DE-SoC [1-9]` / `5CSEBA6`.
  **MiSTer는 HPS가 FPGA를 관리하므로 JTAG SOF 프로그래밍은 하지 말 것.** RBF 배포로 간다.

---

## 5. 저장소 상태

- **HEAD**: `2f38f84` "diag: the noM1 detector was lying"
- **브랜치**: `moonsound_ascii16x`
- **미커밋**: `MSX1.qsf`, `MSX1.sv`, `rtl/msx.sv`, `rtl/debug_overlay.sv`,
  `rtl/peripheral/jt8255.v`, `tools/hinotori_rig/`(신규), `MSX1.stp.broken`(신규)
- ⚠️ **`rtl/msx.sv`/`MSX1.sv`에 미검증 P3 터보(`sdram_rdtog`)가 섞여 있다.**
  2f38f84에 이미 포함됐고 사용자가 수용함("문제 생기면 기본 클럭으로 돌리면 되는 앱·게임").
- ⚠️ **다른 Claude 세션이 같은 워크트리를 편집한다. `git add`는 반드시 경로 명시.**
- 배포된 RBF: `MSX1_20260901e_ring.rbf`(현재 보드), 그 뒤 빌드들은 SignalTap 미포함이라
  배포 안 함.

---

## 6. 피어에게 넘길/받을 것

- 피어 최신 롬: `Hi no Tori Hououhen (b1m55-slidetrap).rom` **sha1 `076173a2`**
  (E7C8-E7FF 전체가 JR 슬레드로 handler 수렴, E7FF는 `RST 00`).
  다만 **F1XV에서 트램폴린이 한 번도 발화하지 않았다** — 그쪽 경로가 아니다.
- 피어가 준비해둔 것: `tracediff.py`(CSV 헤더 자동 매핑, 사이클별 뱅크/서브슬롯 추적,
  기지 이미지와 바이트 대조해 **첫 불일치 페치 ±40사이클** 출력), 48비트 비트필드 디코더.
- 우리가 줄 것: **SignalTap CSV 경로**.

### 미해결로 남긴 것
- `MSX1.sv:581`의 `ce_cpu_p & ~msx_pause`에 **위상 정렬 가드가 없다**. 정적으로는
  전 항이 clk21m 등록 신호라 런트/순서역전 진입점이 없다고 결론냈으나, 경험적 반증은
  안 됐다.
- **demo60 리그는 사용자 지시로 폐기**. 명시적 요구 없이 언급하지 말 것.
