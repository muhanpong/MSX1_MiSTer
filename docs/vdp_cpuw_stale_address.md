# CPU VRAM 쓰기가 낡은 주소로 나간다 — 구조적 비대칭 (미수정)

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
