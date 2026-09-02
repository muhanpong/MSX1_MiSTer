# SignalTap `MSX1.stp` — 내용과 재작성 절차

`MSX1.stp`는 `.gitignore`의 `*.stp`로 저장소에 넣지 않는다(사용자 결정 20260903).
잃어버리면 GUI에서 다시 만들어야 하는데, **손으로 XML을 쓰면 세 번 다 실패했다**
(지어낸 `<trigger>` → `quartus_stpw` 크래시 / 트리거 제거 → 같은 크래시 / 복원 →
Quartus가 파일을 아예 안 읽음). 이 문서는 그 GUI 작업을 되풀이하기 위한 것이다.

기록 시점 실제 파일에서 뽑은 값이다. 관련: `MSX1.qsf`의 SignalTap 주석 블록,
`docs/handoff_hinotori_20260902.md`, `tools/hinotori_rig/stpdecode.py`.

---

## 1. 무엇을 탭하는가

`rtl/msx.sv`의 `stp_data` — CPU 버스를 통째로 묶은 48비트 레지스터다.
팬아웃이 없으므로 **`(* preserve, noprune *)`가 둘 다 필요**하다. 조합 wire에
`(* keep *)`만 붙였던 초기 시도는 합성에서 소멸해 analyzer에 탭할 노드가 없었다.

```systemverilog
(* preserve, noprune *) logic [47:0] stp_data;
always_ff @(posedge clk21m) stp_data <= {
    2'b00,                                        // [47:46] spare
    ppi_out_a,                                    // [45:38] live slot map
    wait_n, m1_n, mreq_n, iorq_n, rd_n, wr_n,     // [37:32] strobes
    d_to_cpu,                                     // [31:24] what the CPU receives
    d_from_cpu,                                   // [23:16] what the CPU drives
    a                                             // [15:0]  address bus
};
```

| 비트 | 내용 | 비트 | 내용 |
|---|---|---|---|
| `[15:0]` | `a` 주소 | `[32]` | `wr_n` |
| `[23:16]` | `d_from_cpu` (CPU가 쓰는 값) | `[33]` | `rd_n` |
| `[31:24]` | `d_to_cpu` (CPU가 받는 값) | `[34]` | `iorq_n` |
| `[45:38]` | `ppi_out_a` 슬롯맵 | `[35]` | `mreq_n` |
| `[47:46]` | spare | `[36]` | `m1_n` |
| | | `[37]` | `wait_n` |

`MOONSOUND_DIAG` 안에 있으므로 `MSX1.qsf`의
`set_global_assignment -name VERILOG_MACRO "MOONSOUND_DIAG=1"`이 살아 있어야 한다.
없으면 `stp_data` 자체가 존재하지 않는다.

## 2. Signal Configuration (기록 시점 실측값)

```
instance          auto_signaltap_1
nodes             48   emu:emu|msx:MSX|stp_data[0..47]   (data + trigger 양쪽)
clock (acq_clk)   emu:emu|msx:MSX|clk21m   posedge   tap_mode=classic
sample depth      16384          (= 763 µs, 약 600~700명령)
RAM type          AUTO
pipeline factor   0
storage qualifier Continuous     (storage_mode="off")
trigger position  post           (트리거 이전 88% / 이후 12%)
trigger in        disabled
trigger levels    1  (basic)
```

`clk21m` = 21.47727 MHz. **T-state당 6샘플 = CPU 3.58 MHz 정상 속도**다. 명령 간격이
`T×6 + 6`으로 딱 떨어진다(웨이트 오버헤드가 명령당 1 T 상당으로 일정):
`INC SP` 6 T→42, `INC (HL)` 11 T→72, `LD A,(nn)` 13 T→84, `LD C,A` 4 T→30 — 전부 실측 일치.

디코더가 접어주는 런 길이는 M1 약 15샘플, 메모리 R/W 12샘플인데, 이건 **스트로브가
낮게 유지되는 구간**이지 T-state 수가 아니다. 이걸 T-state로 착각하면 4샘플/T = 5.37 MHz
터보로 오독하게 된다(실제로 한 번 그랬다). 클럭을 판정하려면 위처럼 **명령 간격**을 쓸 것.
`tools/hinotori_rig/stpdecode.py`가 런을 하나의 버스 사이클로 접는다.

## 3. GUI 재작성 절차 — 실제로 걸렸던 함정 순서대로

1. **Instance Manager에서 `Create Instance`.** 창을 열면 JTAG로 보드에서 발견한
   기존 인스턴스가 보이는데, 거기엔 노드를 못 붙인다. 반드시 새로 만든 쪽을 선택하고,
   비어 있는 잉여 인스턴스는 지운다(안 지우면 신호 0개짜리 analyzer가 M10K만 먹는다).
2. **노드 추가는 왼쪽 노드 목록의 `Double-click to add nodes`에서** 한다.
   Clock 필드 옆 `...`에서 Node Finder를 열면 48개 선택이 **클럭 지정으로 흘러가**
   `stp_data[0]`이 클럭이 되고 노드 목록은 빈 채로 남는다. 실제로 이렇게 한 번 날렸다.
   - Filter `Signal Tap: pre-synthesis`, Look in `|sys_top|`, Named `*stp_data*` → 48개
3. **Clock**은 Clock 필드의 `...`로 따로 지정한다. Named `*clk21m*` → `emu:emu|msx:MSX|clk21m`.
   pre-synthesis에 안 보이면 필터를 `post-fitting`으로 바꿔 찾는다(같은 네트).
   단 **데이터 노드는 pre-synthesis로 잡은 것을 유지**할 것.
4. **`Trigger in` 체크 해제.** 켜진 채 노드가 비면 Quartus가 아무 데도 안 물린
   `auto_stp_trigger_in` 핀을 만들고, 최종 조건이 `condition1 AND (trigger_in==High)`가
   되어 **arm은 되는데 영원히 안 걸린다**.
5. Data 탭에서 depth 16 K, trigger position Post.
6. 트리거 비트 지정(§4) → **Ctrl+S**로 `MSX1.stp` 저장.

**저장 후 검증**: `grep -c stp_data MSX1.stp`가 48 이상이어야 한다. 파일이 1 KB 남짓이고
`<mnemonics/>`만 있으면 노드가 하나도 안 들어간 것이다.

> ⚠️ **Quartus GUI는 `MSX1.qsf`를 덮어쓴다** — 빌드 도중에도 쓴다. 손으로 살린
> 어세스먼트를 주석으로 되돌리고, 경로를 `../../Documents/github/MSX1_MiSTer/MSX1.stp`
> (프로젝트 기준으로 해석 불가)로 바꿔 넣는다. **qsf는 GUI를 닫은 뒤에 손볼 것.**

## 4. 트리거 라이브러리

Basic 트리거 값은 **런타임 프로그래밍**이다 — 값만 바꾸고 `Run Analysis`를 누르면
재빌드가 필요 없다. 재빌드가 필요한 것은 구조 변경(노드 추가, depth, 세그먼트,
storage qualifier, 트리거 레벨 수, advanced trigger)뿐이다.

⚠️ 조건을 바꿀 때 **이전 조건의 비트를 반드시 전부 Don't Care로 되돌릴 것.** AND라서
한 칸만 남아도 영원히 안 걸린다. 실제로 `[22]` 한 칸 때문에 캡처를 한 번 날렸다.

### T1 — `a==0x0320 && ~m1_n && ~mreq_n` (BIOS 슬롯 루틴 페치)
`[36]`,`[35]` Low · `[9]`,`[8]`,`[5]` High · `[15:10]`,`[7]`,`[6]`,`[4:0]` Low

**폐기.** "게임 중 0320 호출은 0회"라는 전제가 틀렸다 — WRSLT는 정상 게임플레이 중
정상적으로 돈다(캡처 a가 반례). arm하자마자 건강한 코드에 걸린다.

### T2 — A8 쓰기 & 값 `[7:6]==00`
`[34]`,`[32]` Low · `[7]`,`[5]`,`[3]` High · `[6]`,`[4]`,`[2]`,`[1]`,`[0]` Low · `[23]`,`[22]` Low

**과잉 제약.** 실제 치명값 `5C`는 `[7:6]==01`이라 `[22]`에 걸려 통과했다.

### T3 — A8 쓰기 & 값 `bit7==0` (T2에서 `[22]` 해제)
페이지3이 슬롯3(RAM)이 아닌 모든 맵을 잡는다. 건강한 `D4`/`D7`은 안 걸리고
`5C`/`01`/`00`/`14`는 걸린다. **F1XV 전용** — CPC-400S는 정상맵이 `0x14`라 즉시 오발한다.
이걸로 치명 `OUT (A8),01`을 실제로 잡았다(캡처 c).

### T4 — `M1 && d_to_cpu==0xFF` (지워진 메모리 실행)
`[36]`,`[35]` Low · `[31:24]` 전부 High. **오발이 잦다** — §5의 stale 문제 때문.

### T5 — T4 + 페이지3 한정 ★현재 설정
```
[36] Low   m1_n
[35] Low   mreq_n
[15] High  [14] High        a[15:14]=11 → C000-FFFF (페이지 3)
[31:24] 전부 High           d_to_cpu == 0xFF
그 외 전부 Don't Care
```
이걸로 폭주 origin을 잡았다(캡처 d: `8C2F CALL E7A4` → 0x3A 밭).
그래도 stale 오발이 남으니 §5 판별법으로 걸러야 한다.

### 참고 — 쓰지 말 것
- `a==F382` 같은 **PC 값은 트리거가 안 된다.** I/O 사이클의 주소 하위 바이트는
  포트 번호이고 상위는 A 레지스터다.
- 주소 창(`F300-F37F` 등)으로 좁히면 **그 한 번의 크래시가 착지한 자리**를 지문으로
  삼는 셈이라 다음 크래시엔 안 걸린다. 실제로 불발했다.

## 5. `d_to_cpu`는 사이클 첫 샘플에 이전 값을 물고 있다

트리거 조건에 `d_to_cpu`를 쓸 때 반드시 감안할 것. `mreq_n`이 떨어지는 첫 샘플에서
데이터 버스는 아직 **앞 사이클 값**이다.

```
14333  a=7FFA  d_to=FF  mreq=1     ← 앞 사이클(빈 슬롯 읽기)이 FF를 남김
14337  a=F383  d_to=FF  mreq=0     ← 트리거가 여기서 발화 (헛발)
14338  a=F383  d_to=18  mreq=0     ← 실제 오퍼코드는 0x18
```

**판별법**: CSV에서 그 값이 몇 샘플 유지되는지 본다. 1샘플이면 stale 헛발,
M1 사이클 내내(약 15샘플)면 진짜다. `stpdecode.py`는 런의 **마지막** 값을 취하므로
디코드 결과에는 헛발이 안 나타난다 — 원본 CSV를 봐야 한다.

## 6. 빌드에 넣기

`MSX1.qsf`의 세 줄 주석을 푼다(파일이 없으면 다시 주석 처리할 것 — 없는 파일을
가리키면 빌드가 깨진다):

```
set_global_assignment -name ENABLE_SIGNALTAP ON
set_global_assignment -name USE_SIGNALTAP_FILE MSX1.stp
set_global_assignment -name SIGNALTAP_FILE MSX1.stp
```

`.stp`를 저장하면 Quartus가 그 아래에 SLD 배선을 직접 생성한다
(`acq_data_in` 48 + `acq_trigger_in` 48 + `acq_clk`, `SLD_SAMPLE_DEPTH=16384`,
`SLD_FILE db/MSX1_auto_stripped.stp`). 그 블록은 커밋되어 있으니 무엇이 탭됐는지
기록으로 남아 있다.

**★ 반드시 `quartus_map`을 먼저 명시 실행할 것:**

```
quartus_map MSX1 -c MSX1 && make build
```

`quartus_sh --flow compile`만 돌리면
`Info (293003): Smart recompilation skipped module Analysis & Synthesis`가 뜨면서
**빈 .stp로 합성된 옛 넷리스트를 그대로 재사용**한다. fit·sta가 정상 완주하므로
로그만 보면 성공처럼 보인다. 한 시간을 날릴 뻔했다.

**들어갔는지 검증** (리소스 델타로만 판정한다):

| 지표 | analyzer 없음 | 16K×48 있음 |
|---|---|---|
| `block memory bits` | 2,331,610 | **3,118,042** (+786,432 = 16384×48) |
| `Total RAM Blocks` | 351 / 553 | **447 / 553** |
| `map.rpt` | `sld_hub`만 | **`sld_signaltap:auto_signaltap_1`** |

`sld_hub`는 JTAG 허브일 뿐 analyzer가 아니다. 착각하기 쉽다.

depth를 32 K로 올리지 말 것 — 약 155블록이 되어 91%에 착지하는데, 그 영역에서 예전에
`SDRAM_DQ` IOB 패킹이 깨져 2 MB RAM이 flaky해졌다.

## 7. 캡처 절차

1. Quartus에서 `MSX1.stp`를 열고 Hardware `DE-SoC [1-9]` 연결
2. 게임 진입 **후** `Run Analysis`(단발)로 arm.
   `Autorun Analysis`는 계속 재무장해서 어렵게 잡은 캡처를 덮어쓴다
3. 트리거가 걸릴 때까지 대기 — analyzer는 무한정 armed 상태로 기다린다.
   걸리면 캡처는 버퍼에 보존되므로 화면에서 뒤늦게 알아채도 된다
4. File → Export → CSV
5. `python3 tools/hinotori_rig/stpdecode.py <파일>.csv` 로 버스 사이클로 디코드

설계 불일치 경고가 뜨면 SOF Manager에 `output_files/MSX1.sof`를 **attach만** 한다.
**Program 버튼은 누르지 말 것** — MiSTer는 HPS가 FPGA를 관리한다. RBF 배포로 간다.
