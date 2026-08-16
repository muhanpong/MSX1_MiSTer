# Pause 심벌 오버레이 — 스펙 계약 (2026-08-15 동결)

## 배경/결정 사항
- 원안 F1(OSD에 pause on/off 표시, T[44]→O[44]+status_set 부트클리어)은 **폐기**:
  status_in이 128비트 전체 기록이라 오결선 시 사용자 저장 설정 전체 오염 위험.
  대체 = pause+OSD열림 동안 심벌 상시 표시(OSD 안에서 토글 즉시 피드백).
- 결과: 본 작업은 **순수 부가 로직**. 최악 실패 모드 = 심벌 표시 이상. 기존 경로 무침습.

## 기능 스펙
S1. 심벌: ⏸ (세로 막대 2개, 막대 4px 폭 + 간격 4px 권장, 높이 ~16px), 게임 표시영역 우상단.
S2. 상태기계 (모두 msx_pause 기준):
    - pause ON  & OSD_STATUS=1        → 상시 표시
    - pause ON  & OSD_STATUS 1→0 엣지 → 18프레임(≈0.3s@60Hz) 표시 후 소멸
    - pause ON  & 입력 이벤트         → 18프레임 재표시 (타이머 재장전)
      입력 = ps2_key[10] 토글 변화 | ps2_mouse[24] 토글 변화 | joy0/joy1 값 변화
    - pause OFF                        → 즉시 소멸 (타이머 클리어)
S3. 위치 제약 (vcrop 상시 사용 전제):
    - Y: 오버레이 창 라인 28..44 (표시영역 상단 +2 여유; 최악 vcrop 20라인에도 생존)
    - X: 표시영역 256px의 우측 사분면 안쪽 (우측 보더 불확실성 회피, OSD 중앙박스 겹침 최소)
    - 설계 에이전트가 debug_overlay의 h_cnt 스케일 실측/산출로 정확 좌표 확정
S4. 독립성: 기존 디버그 패널 게이트(en=status[48])와 완전 분리된 자체 enable.
    status[48]=0에서도 심벌 정상 동작. 영역 비겹침(패널=좌상단, 심벌=우상단).

## 구현 제약
C1. 전 로직 CLK_VIDEO 도메인. msx_pause/OSD_STATUS/ps2_*/joy는 2FF CDC 후 사용.
C2. debug_overlay.sv에 통합(픽셀 카운터 h_cnt/v_cnt 재사용), 신규 포트 최소.
C3. MSX1.sv 변경 = 신호 배선만 (msx_pause, OSD_STATUS, ps2_key, ps2_mouse, joy0, joy1).
    CONF_STR 불변. T[44] 시맨틱 불변.
    [개정 2026-08-15, A4 HIGH-1] 예외: ce_10m7_p/ce_5m39_n의 pause 게이트 해제 2줄 추가.
    vdp18 머신에서 pause가 비디오 CE까지 동결해 심벌 표시/타이머가 불가했던 것을,
    V9938 경로(CLK21M 직결, 원래 미게이트)와 동일 시맨틱으로 정렬해 해소.
C4. 예산 ≤150 ALM. 신규 로직이 크리티컬 패스에 들지 않을 것(단순 비교기+카운터 수준).
C5. 프레임 카운트는 vblank 상승 엣지 기준(기존 vblank_prev 패턴 재사용).

## 필수 산출: 양방향 불변식표 (설계 에이전트)
각 모드에서의 거동 전수 열거 — 최소 다음 포함:
  리셋 직후 / pause OFF 정상 플레이 / pause ON+OSD 열림 / 닫힘 직후 / 0.3s 경과 후 /
  입력 연타 / OSD 재열림 / unpause 순간 / status[48] on·off 조합 / 50Hz(PAL) 프레임레이트
  (18프레임@50Hz=0.36s — 허용 오차로 명기) / vcrop on·off / 스캔더블러 경로.

## 검증 게이트
V1. 트리거/타이머 로직 iverilog TB 통과 후에만 병합 (OSD엣지/입력재장전/unpause클리어).
V2. 리뷰 필수 항목: ps2_key[10]·ps2_mouse[24] 토글 시맨틱을 sys/hps_io.sv 소스로 확인(추측 금지),
    status[48]=0 동작, CDC 누락, joy 변화 오탐(아날로그 비트 유무).
V3. 실기 체크리스트(배포 후): ①일반 게임 무영향 ②pause+OSD 심벌 즉시 표시 ③닫으면 0.3s
    ④입력 재표시(키/마우스/조이) ⑤unpause 소멸 ⑥디버그 패널 off/on 조합 ⑦vcrop 화면서 심벌 보임.

## 에이전트 편성 (5)
A1 설계: 본 스펙 기반 상세설계 + 불변식표 + 좌표 산출 + hps_io 토글 시맨틱 확인. 산출=설계서.
A2 코딩①: MSX1.sv 배선 (신호 인출→debug_overlay 포트). 산출=diff.
A3 코딩②: debug_overlay.sv 심벌 렌더러+상태기계+CDC + iverilog TB. 산출=diff+TB결과.
A4 리뷰: V2 렌즈 전수 + A2/A3 diff 교차. 산출=지적목록(심각도별).
A5 감사: 메모리 프로토콜 준수(불변식표 존재/교차검증/복명복창) + 스펙↔diff 추적성. 산출=감사보고.
채택·병합·리뷰반영·빌드·배포 = 메인(Claude).
