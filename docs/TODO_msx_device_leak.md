# msx_device 가 머신팩 사이로 샜다 — ◆◆해결 (2026-08-30)

## 결함

`rtl/peripheral/slots/memory_upload.sv` 의 `msx_device` 는 머신팩 config 레코드를 훑으며
**OR 로 누적**되는 장치 마스크인데, 팩 로드 시작 시 클리어되지 않았다. 바로 옆
`cart_device` 와 `cart_slot_expander_en` 은 클리어된다 — 이것만 빠져 있었다.

## ★실기 증거 (결정적)

**`SONY_HB-F1XV1MB_NOLOGO` 팩을 로드한 상태에서 Z80BENCH v1.4.2 가 이렇게 보고했다:**

    Machine   : MSX2+ (Panasonic)      <- Sony 머신인데 Panasonic 으로 식별
    CPU Speed : 5.36 MHz               <- tPANA 속도(5.369)로 실제 구동
                "performs 150% of an original MSX Z80"

새어 들어온 `DEV_MATSUSHITA` 가 I/O 41H bit2 에 응답하니, **Panasonic 터보를 찔러보는 모든
소프트**(Z80BENCH, MGSDRV, Tales of Popolon, Hi no Tori 60Hz 패치)가 터보가 없는 머신에서
스스로 5.37 로 올린다. 사용자 표현으로 **"어떤 머신 팩을 사용하든 Panasonic MSX2+ 로 관측"**.

## 수정

`if (load)` 초기화 블록에 `msx_device <= '0;` — `cart_device` 바로 옆.

## ★한 번 되돌렸다가 다시 넣었다 (1b57fd4 -> 복원)

이 수정을 담은 빌드 `MSX1_20260830b_devclear` 에서 Sony HB-F1XV / Daewoo CPC-300 / CPC-400S 로
특정 롬(Hi no Tori 60Hz 패치)이 3.58 에서 크래시했다. 30a 로 되돌리면 정상이었다.
그래서 **회귀로 판단하고 되돌렸는데, 오판이었다.**

진상: **그 롬은 30a 에서 가짜 터보를 타고 5.37 로 돌고 있었다.** 누수를 막자 진짜 3.58 이 됐고,
그 롬은 3.58 에서 원래 못 돈다(제작 세션 실측: 틱 med 33ms vs 예산 16.7ms, 30Hz 폴백이
실기에서 안 먹음). **코어 결함이 아니라 소프트가 없는 하드웨어에 의존하고 있었던 것.**

이 오판을 쫓느라 헛짚은 것들 — 전부 폐기:
- "ROM 로드 경로에서 장치 복원 실패" -> `sim/run_device_reload.sh` 가 반증
- "배치(fit) 민감 마진 경로" -> `docs/TODO_fit_sensitive_path.md`, 철회됨
- "VDP CPU 쓰기 유실 / 주소 오배치" -> `docs/vdp_cpuw_stale_address.md`, 코드로 반증됨
- 타세션이 만든 최소재현 카트 **6종이 전부 음성**이었던 이유도 이것 — **재현할 결함이 없었다.**

## 검증

- `sim/run_device_reload.sh` — P1(팩 장치 세팅) / P2(ROM 로드 후 유지) / P3(팩 교체 시 잔존 없음)
  전건 통과. 수정 없으면 P3 실패.
- `sim/check_upload_accum_clear.py` — OR 누적 신호가 전부 load 시 클리어되는지 정적 검사.

## 별건으로 남는 것

**54개 머신팩 중 38개가 `<device>` 선언 0개**다(선언하는 건 Panasonic FS-A1WX/FX 계열과
Sony HB-F1XV 계열뿐). 누수가 이걸 가려주고 있었으므로, 이제 그 팩들이 원래 가져야 할
장치를 실제로 못 갖는다. Daewoo CPC-400S 는 한자 폰트 ROM 이 있는데 `KANJI` 선언이 없다.
`DEV_MOONSOUND` 는 소비처가 0건인 죽은 비트라 무관.

## 교훈

**실기 회귀를 봤다고 곧바로 되돌리면, 그 회귀가 "고쳐진 결과"일 때 원인을 되살린다.**
이번엔 되돌림 자체가 6단계 헛수고의 출발점이었다. 되돌리기 전에 **"고친 게 맞는데 소프트가
낡은 동작에 의존했던 것 아닌가"** 를 먼저 물었어야 했다.
