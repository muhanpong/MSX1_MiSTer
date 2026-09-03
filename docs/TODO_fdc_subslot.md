# FDC를 서브슬롯에 — 미구현 (자원 제약 아님)

2026-09-04 조사. 사용자 요청으로 **다음 빌드에 구현 예정**.

## 지금 막고 있는 것

```systemverilog
msx_config.sv:204   fdc_enabled = use_FDC | (~expanded_A & typ_A == CART_TYP_FDC);
                                             └────┬────┘  슬롯 A를 확장하면 카트 FDC가 꺼진다
memory_upload.sv:757   typ == CART_TYP_FDC & subslot == 2'd0 ? {…}   ← 서브슬롯 쪽 대응 행 없음
```

`~expanded_A`는 하드웨어 제약이 아니다. 확장하면 슬롯 레벨 장치 선택(`typ_A`)이 숨겨지므로
(`slotA_classic_hide`) 그 항이 무의미해질 뿐인데, 서브슬롯 쪽 대체 경로를 만들지 않았다.

## 자원은 이미 다 있다

| 확인 | 결과 |
|---|---|
| FDC 라우팅 | `msx_slots.sv:727` `.cs(device == DEVICE_FDC)` — `device`는 `slot_layout[{slot,subslot,block}]`에서 온다. **서브슬롯 어디든 동작** |
| 열거형 여유 | `subslot_dev_t`가 3비트에 값 6개(0–5) → 6·7 비어 있음 |
| 디스크 ROM | `ROM_FDC`는 슬롯 레벨 FDC가 이미 사용 중 — 새 자원 불필요 |
| 배치 테이블 | 서브슬롯 테이블(`memory_upload.sv:741-745`)이 슬롯 레벨과 완전 평행 |

## 작업 목록

| 파일 | 변경 |
|---|---|
| `package.sv:8` | `subslot_dev_t`에 `SUB_FDC` 추가 |
| `memory_upload.sv` | 서브슬롯 배치 행 1개 — 슬롯 레벨 튜플 그대로:<br>`expanded & sub_dev == SUB_FDC ? {MAPPER_NONE, DEVICE_FDC, ROM_FDC, 8'h08, 8'h00, 8'd0, 8'd0, DEV_NONE} :` |
| `msx_config.sv` CONF_STR | 슬롯 A 서브슬롯 목록에 `FDC` 추가 |
| `msx_config.sv:118-147` | 충돌 규칙 — 시스템 전체에 FDC 하나 |
| `msx_config.sv:204` | `fdc_enabled`에 `(expanded_A & 어느 서브슬롯이든 SUB_FDC)` 항 |

★ `fdc_enabled`는 OSD의 **`Mount Drive A:`(`MSX1.sv:305`, `h1` 마스크)** 를 보이게 하는 신호다.
빠뜨리면 FDC는 붙는데 디스크를 못 넣는다.

## 지킬 제약

1. 머신에 내장 FDC가 있으면 숨김 — 슬롯 레벨의 `H2`/`h2`(`use_FDC`)와 동일. WD2793은 하나뿐
2. 서브슬롯 넷 중 하나만 — ROM/SCC처럼 first-occurrence-wins
3. 슬롯 A 전용 — 슬롯 B는 `slot_B_select < CART_TYP_MFRSD`로 잘려 FDC를 표현조차 못 한다
   (`msx_config.sv:115`)

★ CONF_STR 토큰·마스크는 [[feedback_stay_inside_proven_range]] 참고 — 리포 선례 범위를 넘지 말 것.
