# TODO — 부팅 간헐 실패 조사 (미해결, 2026-08-19 관측)

## 증상
- 부팅이 "빡빡함". **부트 로고가 안 뜰 때가 있음**, 간헐적 기동 실패.
- **재시작 전 머신 상태에 영향을 받는 것으로 보임** ← 가장 중요한 단서.
- 관측 빌드: `MSX1_20260819a_yamanooto.rbf` (Yamanooto 8MB 이미지 시험 중).
  ★이 빌드에서 **새로 생긴 것인지 미확인** — 아래 확인항목 ① 참조.

## 배제된 가설 (근거 확인 완료)

| 가설 | 확인 결과 |
|---|---|
| 타이밍 위반 | `MSX1.sta.rpt` setup/hold/recovery/removal/MPW **전부 양수, TNS 0.000**. `clk_sdram`(emu\|pll general[0]) setup **+0.860** / hold **+0.257** — 2026-05-30의 +0.065보다 오히려 여유. |
| 로드 완료 전 CPU 기동 경합 | `memory_upload.sv:78` `reset_rq = !(state == STATE_IDLE \| state == STATE_ERROR)` — 업로드 중 머신을 리셋에 잡아둠. 핸드셰이크 건전. |
| `STATE_ERROR`로 불완전 기동 | `state <= STATE_ERROR` 대입이 소스 전체에 **0건**. 죽은 상태라 진입 불가. |
| Yamanooto `DEV_PSG`가 내부 PSG와 충돌 | 카트 PSG(`psg.sv:20`)는 `cpu_addr[7:3] == 5'b00010` = **0x10-0x17** 디코드. 내부 PSG(0xA0-0xA2)와 무관. |
| 이번 변경분이 비-Yamanooto 경로로 샘 | `cs`/`cart_dout_en`/`scc_req` 전부 `mapper == MAPPER_YAMANOOTO` 게이트. 미선택 시 `mem_unmaped=0`, `dout=0xFF`(AND 중립), `sccReq=0`. |

## ★1순위 가설 — DDR3 스테이징 영역 침범 (기존 결함, 이번 작업과 무관)

```
슬롯A ROM 스테이징  0x0C00000   (MSX1.sv CONF_STR "H3FS3,ROM,Load,30C00000")
슬롯B ROM 스테이징  0x1100000   (            "H4F4,ROM,Load,31100000")
                     간격 5MB
FW  PACK            0x2000000
```
`memory_upload.sv:231` `ddr3_addr <= curr_conf == CONFIG_SLOT_A ? 28'hC00000 : 28'h1100000;`

**8MB 롬을 슬롯 A에 올리면 끝 주소가 `0x1400000` → 슬롯 B 영역을 3MB 침범.**
(슬롯 B에 8MB는 끝 `0x1900000`으로 FW까지 7MB 여유라 안전)

### 왜 증상과 맞는가
- 슬롯 B에 스테이징된 내용이 있으면 슬롯A 8MB 롬이 그것을 덮음 → 다음 부팅에 잔재 영향
  → **"재시작 전 머신 상태 영향"** 과 일치
- 슬롯 B가 비어 있으면 무해 → **간헐적**인 이유 설명됨

### 전례
`memory_upload.sv:296` 주석에 같은 유형의 사고 이력이 남아 있음:
> `// FW Store base (relocated 0x300000->0x2000000: 9MB region overflowed into slotA@0xC00000, clobbering yrw801's upper ~1MB)`

### 영향 범위
ASCII16X(8MB 플래시)도 동일 조건이므로 **Yamanooto 도입 이전부터 존재**했을 가능성이 높음.
GoFigure(0x7DC000 ≈ 7.86MB) 시험 시 슬롯 B가 비어 있어 드러나지 않았을 수 있음.

## 확인 항목 (다음 세션에서)

1. **★결정적 A/B**: 보드에 남아 있는 `MSX1_20260818b_sccplus.rbf`(Yamanooto 없음)를 같은 머신·같은 롬 조건으로 로드.
   거기서도 빡빡하면 → **이번 변경과 무관** 확정.
2. **8MB 한정 여부**: 작은 게임(그라디우스2 128KB 등)만 올렸을 때도 발생하는지 vs
   Yamanooto 8MB 이미지일 때만 발생하는지. 1순위 가설이 맞다면 **8MB 때만** 나와야 함.
3. **슬롯 B 상태**: 슬롯 B가 비어 있는지 / 이전에 롬을 로드한 적 있는지.
   비어 있는데도 발생하면 1순위 가설 약화.

→ **②가 가설을 가장 빠르게 가름**. ①까지 하면 원인 범위 거의 확정.

## 수정 방향 (가설 확인 후)
- 슬롯 A/B 스테이징 간격을 8MB 이상으로 재배치. 단 `MSX1.sv`의 `CONF_STR` 로드 주소와
  `memory_upload.sv:231`이 **반드시 함께** 바뀌어야 함(FW 이전 때와 동일한 함정).
- 또는 로드 크기 바운드 체크를 넣어 침범 자체를 차단.
- ★[[feedback-vdp-timing-change-protocol]] 1항 적용: 주소 상수는 공용이므로 소비처 전수조사 후 수정.

## 관련
`docs/yamanooto_spec.md`, `docs/sccplus_spec.md`.
관측 시점 커밋: `44828b1` (yamanooto), `2ec7be3` (S8-1), `be52736` (scc+ ch5).
