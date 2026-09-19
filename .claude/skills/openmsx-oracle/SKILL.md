---
name: openmsx-oracle
description: Use openMSX as the reference oracle when a game misbehaves on the MiSTer MSX1 core — localize the stop PC, identify whose code it is, measure what the real machine returns, and hand back a decisive number. Use when a title hangs, a display element vanishes, or a core/emulator divergence has to be settled.
---

# openMSX를 오라클로 쓰기

코어에서 무언가 안 되면, **"우리 것이 틀렸다"를 증명하는 게 아니라 "실기라면 무엇이
나오는가"를 재서 넘겨준다.** 그 숫자 하나면 RTL 쪽이 바로 고칠 수 있다.

도구: `tools/omsxprobe/` (ports / bands / sprites / trace). 함정 목록은 그 README에 있다.

## 정지(hang) 좁히는 순서

1. **정지 PC를 받는다.** 코어 쪽 디버그 패널의 live PC + 마지막 인터럽트 시점 PC.
2. **그 주소가 누구 코드인지 가른다.** 페이지 0은 DOS에서 RAM이고, turbo R은 BIOS를
   DRAM에서 실행한다 — 즉 "RAM 주소"라고 게임 코드가 아니다. BIOS ROM 이미지에서 같은
   오프셋을 떠서 바이트가 일치하는지 본다(`fs-a1st_firmware.rom` 등의 0x50000 슬라이스).
3. **디스어셈블해서 무엇을 기다리는지 읽는다.** 대기 루프면 탈출 조건이 곧 답이다.
   예: `IN A,(90h) / RRCA / RRCA / CCF / SBC A,A` → **포트 90h bit1이 0이어야 탈출**.
4. **openMSX에서 그 자원의 실제 값을 잰다.** 단, `debug read ioports`는 peek이라
   실행된 `IN`과 다를 수 있다. 값이 중요하면 `IN` 다음 주소에 bp를 걸고 A를 읽는다.
5. **넘긴다**: 주소·디스어셈블·탈출 조건·실기 값·검증 가능한 예측(예: "CTRL+STOP으로
   풀려야 함")을 함께.

## 미구현 포트 판정 (2단 필터)

미디코드 포트는 FFh로 읽히고, **액티브 로우 상태 비트가 "차단"으로 고착**된다.
그래서 없는 포트의 실패는 오동작이 아니라 **영구 대기**로 나타난다.

1. **기판 포트인가?** 카트리지 자리(MSX-AUDIO C0/C8, RS-232C 80~87, 라이트펜 B8~BB,
   MIDI E8~EB)는 카드가 없으면 실기도 FFh다. 채우면 없는 장치를 있다고 말하는 꼴.
2. 기판 포트면(프린터 90/91, 시스템 F3~F7, 타이머 E6/E7 …) **실기 값을 재서** 준다.

`omsxprobe.py ports`로 60초 census를 떠서 "읽히는 포트" 목록부터 만든다.

## 단일 변수 격리

세이브스테이트에서 분기해 **한 번에 하나만** 바꾼다.

- CPU 종류/클럭: `set z80_freq_locked false; set z80_freq N`, `r800_freq`
- **구간 한정 변경**: 브레이크포인트로 특정 코드 블록 진입/이탈 때만 클럭을 바꾸면
  "총 처리량은 그대로 두고 그 블록의 I/O 간격만" 바꿀 수 있다(→ timing-axis-bisect)
- 장치 유무: 그 장치가 없는 실기 기종으로 대조군을 만든다(MIDI 없는 FS-A1ST 등)
- BIOS 루틴 무력화: DRAM의 BIOS 사본을 poke(`XOR A / RET` 등)해 반환값을 고정

## 계측기부터 의심하기

이 세션에서 잘못된 결론을 낸 원인은 전부 대상이 아니라 **계측기**였다.

- 판정기가 못 보는 실패 모드(색상 다양성만 보다 "검게 빔"을 정상으로 셈)
- 인접 프레임 비교로 스크롤분이 섞인 차분
- one-shot bp 두 개를 겹쳐 걸어 서로 간섭
- 상대/절대 시간, 콜백 문자열의 치환 시점

**숫자를 넘기기 전에 "이 계측이 지금 조건에서 울릴 수 있나"를 한 번 확인한다.**
그리고 틀렸으면 즉시 철회 메시지를 보낸다 — 상대 세션이 그 숫자로 RTL을 고친다.
