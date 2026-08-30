# CPU VRAM 쓰기가 낡은 주소로 나간다 — 구조적 비대칭 (★발현 불가로 정정)

> ## ⚠️ 결론: 비대칭은 실재하지만 **이 방식으로는 발현되지 않는다.**
> 아래 본문은 2026-08-30 에 세운 가설이고, 같은 날 **실기(CEtest9 초록)와 코드 양쪽으로
> 반증**됐다. 정정 내용은 문서 맨 아래 "왜 발현되지 않는가"를 볼 것.
> 문서를 지우지 않는 이유는, 같은 비대칭을 다시 발견한 사람이 같은 길을 또 걷지 않도록
> **반증까지 남기는 게 요점**이기 때문이다.


## 결함

`rtl/video/VDP/vdp.vhd` 의 VRAM 아비터에서 **CPU 쓰기 경로와 읽기 경로가 비대칭**이다.

포트 0x99 로 VRAM 주소를 설정하면 토글 요청이 선다 (`vdp_register.vhd:585`):

    WHEN "01" =>    -- SET VRAM ACCESS ADDRESS(WRITE)
        VDPVRAMACCESSADDRTMP(...) <= ...
        VDPVRAMADDRSETREQ <= NOT VDPVRAMADDRSETACK;

아비터는 대기 중인 주소 설정을 **보지 않고** 쓰기 슬롯을 잡는다 (`vdp.vhd:1404`):

    ELSIF( VDPVRAMWRREQ /= VDPVRAMWRACK )THEN
        VRAMACCESSSWITCH := VRAM_ACCESS_CPUW;

그리고 그 분기는 낡은 주소를 그대로 쓴다 (`vdp.vhd:1439-1447`):

    IF( VRAMACCESSSWITCH = VRAM_ACCESS_CPUW )THEN
        IRAMADR <= VDPVRAMACCESSADDR;           -- ★ ADDRSETREQ 를 안 본다
        VDPVRAMACCESSADDR <= VDPVRAMACCESSADDR + 1;

**읽기 분기는 본다** (`vdp.vhd:1461-1467`):

    ELSIF( VRAMACCESSSWITCH = VRAM_ACCESS_CPUR ) THEN
        IF( VDPVRAMADDRSETREQ /= VDPVRAMADDRSETACK ) THEN
            VDPVRAMACCESSADDRV := VDPVRAMACCESSADDRTMP;
            VDPVRAMADDRSETACK <= NOT VDPVRAMADDRSETACK;
        ELSE
            VDPVRAMACCESSADDRV := VDPVRAMACCESSADDR;
        END IF;

주소 설정이 커밋되는 나머지 자리는 **CPU·커맨드 접근이 없는 슬롯의 DOTSTATE="11"**
(`vdp.vhd:1548`) 뿐이다.

## 실패 시퀀스

    OUT (99),lo        ; 1st byte
    OUT (99),hi OR 40h ; 2nd byte -> ADDRSETREQ 토글, ADDRTMP = 새 주소
    OUT (98),data      ; -> WRREQ 토글

주소 설정이 커밋되기 전에 아비터가 CPUW 슬롯을 주면, 데이터가 **직전 주소**에 쓰이고
거기서부터 자동 증가한다. 유실이 아니라 **오배치(misdirected write)** 다.

증상이 정확히 둘로 갈린다:
- 의도한 목적지(스프라이트 속성/색상 0xF000대)는 **끝내 안 채워짐** → **스프라이트 없음**
- 데이터는 엉뚱한 곳에 쌓임 → **화면에 큰 잡음 사각형**

## 왜 지금까지 안 보였나

주소 설정이 굶는 건 **CPU 쓰기 요청이 연달아 오고 비-CPU 슬롯이 드물 때** — 즉 **표시기간**이다.
VBLANK 중에는 빈 슬롯이 많아 즉시 커밋된다.

- **5.37 이상에서 통과**: `cpu_turbo` 가 켜지면 VDP 페이서가 VDP 포트 접근 간격을
  32 clk21m 로 강제한다(`rtl/msx.sv`). 그 틈에 주소 설정이 커밋된다.
- **3.58 에서 실패**: 페이서가 통째로 꺼져 있다(`cpu_turbo` 게이트).
- **openMSX 정상**: 주소 래치를 제대로 모델링한다.

## 이 가설이 설명하는 것 / 못 하는 것

설명함:
- 좌하단 큰 VRAM 잡음 + 플레이어 스프라이트 없음 (오배치의 두 얼굴)
- 3.58 실패 / 5.37 통과
- **타세션 최소재현 카트 5종(CEtest3/5/6/7/8)이 전부 음성인 이유** — 전부 주소를 한 번만
  잡고 데이터를 연속 전송한다. **스트림 중간에 주소를 재발행하지 않는다.**
  문제의 게임롬은 색상 업로드에서 **16쌍마다 `OUT(99),OUT(99)` 로 주소를 다시 잡고 32B 전송** —
  포트 0x99 와 0x98 이 촘촘히 번갈아 간다. 이 패턴만 이 경로를 때린다.
  (CEtest8 은 VBLANK 를 5.8ms 초과했는데도 초록이었다 = 표시기간 침범만으로는 부족하고
   **주소 재발행 교차가 필요**하다는 강한 증거)
- openMSX 와의 차이

설명 못 함:
- **30a ↔ 30b 가 갈리는 이유.** 아비터는 동기 논리라 배치가 슬롯 위상을 바꾸지 않는다.
  게임이 경계에 딱 걸려 있어 아주 작은 차이에도 넘어가는 것일 수는 있으나, **미확인**이다.

## 수정안 (미적용)

CPUW 분기를 CPUR 분기와 **대칭**으로 만든다 — 읽기 경로에 이미 있는 로직이라 새로 발명하는 게 아니다:

    IF( VDPVRAMADDRSETREQ /= VDPVRAMADDRSETACK ) THEN
        VDPVRAMACCESSADDRV := VDPVRAMACCESSADDRTMP;
        VDPVRAMADDRSETACK <= NOT VDPVRAMADDRSETACK;
    ELSE
        VDPVRAMACCESSADDRV := VDPVRAMACCESSADDR;
    END IF;
    -- IRAMADR 와 증가에 ADDRV 사용

★**주의**: 이 변경은 3.58 을 포함한 **모든 속도**의 VDP 거동을 바꾼다.
"3.58 은 스톡과 비트동일"이 이 코어의 설계 불변식이지만, 그건 **터보 가드/페이서**에 대한
불변식이고 이건 VDP 내부 정정이다. 그래도 회귀 범위가 전 게임이므로 검증이 필수다.

## 검증 계획

1. GHDL TB 로 실패 시퀀스를 재현하는 벤치를 먼저 만들 것 (수정 전 FAIL, 후 PASS).
2. 타세션 카트 **CEtest6/7/8 이 계속 초록**인지 (양성 유지 = 회귀 없음).
3. 문제의 게임롬이 3.58 에서 정상 동작하는지.
4. VDP 타이밍 회귀: GoFigure 부팅검사·Zanac·MFRSD 펌웨어 텍스트
   (`docs/` 의 VDP 타이밍 작업 참조 — 이 영역은 과거에 되돌린 전례가 있다).

관련: `docs/TODO_fit_sensitive_path.md` · `rtl/msx.sv` 의 VDP 페이서 주석


---

# ★왜 발현되지 않는가 (2026-08-30 정정)

## 실기

타세션이 요청대로 **CEtest9**(ISR 안에서 16회 × [`OUT(99)` 쌍 + `OUTI`×32], 목적지
0xF000대/R#14=3, LMMM 동시 발행, 120라운드, 512B 되읽기 검증)를 만들어 30b @3.58 에서
돌렸다. **초록.** 게다가 그 카트는 게임보다 **더 공격적**이다 — 재발행을 16쌍 전부 하고
(게임은 가시성 스킵으로 산발), 주소 마지막 OUT 과 첫 데이터 OUT 간격도 17T 로 더 촘촘하다
(게임은 `POP/EI/RET` 때문에 ≥24T).

## 코드 — 이쪽이 결정적이다

아비터는 **`DOTSTATE="10"` 에서만** 결정하고, 그 외 모든 DOTSTATE 는 `VRAM_ACCESS_DRAW` 다:

    IF( DOTSTATE = "10" ) THEN
        ... DRAW > SPRT > CPUW > CPUR > VDP커맨드 ...
    ELSE
        VRAMACCESSSWITCH := VRAM_ACCESS_DRAW;
    END IF;

그리고 주소 커밋은 최종 ELSE(=switch 가 CPUW/CPUR 이 아닐 때) 안의 `DOTSTATE="11"` 조건이다:

    IF( (DOTSTATE = "11") AND (VDPVRAMADDRSETREQ /= VDPVRAMADDRSETACK) )THEN
        VDPVRAMACCESSADDR <= VDPVRAMACCESSADDRTMP;

`"11"` 에서는 switch 가 **항상** DRAW 이므로 반드시 그 ELSE 로 들어간다.
**즉 대기 중인 주소 설정은 매 도트 사이클마다 무조건 커밋된다.**

본문의 "커밋은 CPU·커맨드 접근이 없는 슬롯에서만 일어난다"는 서술이 **틀렸다.**
`"11"` 은 언제나 그 조건이다.

`OUT(99)` 쌍과 첫 `OUT(98)` 사이는 아무리 촘촘해도 17T ≈ 100 clk21m 이고, 그 사이
`"11"` 이 수십 번 지나간다. **경쟁 창이 존재하지 않는다.**

## 남는 것

CPUW 분기가 `ADDRSETREQ` 를 보지 않는 **비대칭 자체는 실재**한다. 다만 위 이유로
CPU 가 만들 수 있는 시퀀스로는 도달할 수 없다. 고칠 가치가 있다면 **정합성 정리**이지
버그 수정이 아니며, 3.58 포함 전 속도의 VDP 거동을 바꾸는 위험을 감수할 이유가 없다.
**손대지 말 것.**

## 진짜 남은 축

`SPRT` 가 `CPUW` 보다 **우선순위가 높다.** 스프라이트 32개 + 표시 ON 이면 CPU 쓰기 슬롯이
줄고, 그러면 원래 메커니즘(`VDPVRAMACCESSDATA` 가 서비스 전에 덮여 **바이트 유실**)이
살아날 수 있다. 재현 카트 6종은 전부 스프라이트가 사실상 없어 **이 조건을 한 번도 안 걸었다.**
다만 거친 계산으로는 표시 중에도 CPU 슬롯이 32 clk21m 에 1개는 오고 OUTI 는 96 clk21m
간격이라 여유가 있어 보인다 — **확신 없음.**

**결론: 추측을 멈추고 계측한다.** 유실 카운터(`WRREQ /= WRACK` 인데 새 쓰기가 들어온 횟수)를
디버그 오버레이에 띄우는 것이 다음 단계다.
