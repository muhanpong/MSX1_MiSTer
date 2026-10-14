NHTEST 1 -- Neon Horizon / sdram128 실기 확인용

파일
  nhtest.dsk   720 KB 디스크 (AUTOEXEC.BAS -> BLOAD "NHTEST.BIN",R)
  NHTEST.ROM   Neon Horizon 8 MB 원본에서 첫 두 바이트 "AB"만 00으로 바꾼 것.
               게임이 자동 실행되지 않아 BASIC이 뜨고, "ASCII16X" 서명(0010h)은 그대로라
               ASCII16-X 매퍼, 같은 SDRAM 위치로 올라갑니다.

순서
  1. OSD: LOAD *.ROM -> NHTEST.ROM (MAPPER TYPE: AUTO)
     SRAM AUTOSAVE는 Off 권장 (NHTEST.sav가 생기면 다음 실행 결과가 섞입니다)
  2. 디스크 드라이브에 nhtest.dsk 마운트 후 리셋 -> 자동 실행
  3. 끝나면 화면 아래 SUM 세 줄을 사진으로 보내 주세요. 끝난 뒤에는 리셋하세요.

검사 (Z80 기준 약 7분, R800이면 더 빠름)
  T3 VRAM 128 KB 쓰기/읽기          -> 틀린 바이트 수
  T1 카트 8 MB, 16 KB x 512쪽 체크섬 (원본 표와 비교), 2회
  T2 Neon이 게임 시작 때 하는 것과 같은 플래시 바이트 쓰기 (484000h <- 45h)
  T1 3회차 (페이지 0121은 T2 때문에 달라지는 것이 정상)
  T4 매퍼 RAM 세그먼트 4..끝 쓰기/읽기

기대값 (openMSX에서 확인)
  SUM T1 bad p1 p2 p3: 0000 0000 0001
  SUM T2 bef/aft/nxt: FF 45 FF
  SUM T3 VRAM, T4 RAM/seg: 0000 0000/<세그먼트 수>

읽는 법
  p1 > 0          : SDRAM의 카트 내용이 이미 원본과 다르거나 읽을 때 틀림
  p2 > p1         : 읽는 동안 내용이 바뀜 (읽기가 저장값을 손상)
  p3 > 1          : 플래시 쓰기가 다른 곳까지 건드림
  bef != FF       : 이전 .sav 복원이 그 자리를 이미 바꿔 놓음
  aft != 45       : 플래시 쓰기가 SDRAM에 반영되지 않음
  T3/T4 != 0      : VRAM / RAM 경로 문제
  BAD pg 줄       : 페이지 번호, 실측 합계/xor (처음 6개까지 표시)
