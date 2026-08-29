# msx_device 가 머신팩 사이로 새는 문제 — 미해결

## 결함 (실측됨)

`rtl/peripheral/slots/memory_upload.sv` 의 `msx_device` 는 config 레코드를 훑으며
**OR 로 누적**되는데 팩 로드 시작 시 클리어되지 않는다. 바로 옆 `cart_device` 와
`cart_slot_expander_en` 은 클리어된다 — 이것만 빠져 있다.

**실기 증거 (2026-08-30, `MSX1_20260830a_pana40h`)**: Panasonic FS-A1FX 를 로드한 뒤
전원을 끄지 않고 Sony HB-F1XV 로 바꾸면 `MATSUSHITA` 비트가 살아남아

    out64,8:print inp(64);inp(65)   →  247 251   (기대: 255 255)

즉 터보가 없는 머신이 "Panasonic 터보 있음"으로 응답한다. KANJI/OPL3/RESET_STATUS/
MOONSOUND 는 거의 모든 팩에 있어 누수가 안 보였고, 8개 팩에만 있는 `DEV_MATSUSHITA` 가
이걸 드러냈다.

## ★순진한 수정은 더 나쁘다 (되돌림)

`if (load)` 블록에 `msx_device <= '0;` 한 줄을 넣었다 (`0b49f49`). 실기에서 **회귀**했다:

- `MSX1_20260830b_devclear` 에서 Sony HB-F1XV + Konami 매퍼 게임이 깨짐
  (좌하단 VRAM 잡음 사각형 + 플레이어 스프라이트 없음 + 연속음 + 리셋 루프)
- `MSX1_20260830a_pana40h` 에서는 정상. 두 빌드의 **RTL 차이는 그 한 줄뿐**이다
  (옆 세션의 미커밋 P3 도 두 빌드에서 동일함을 mtime·diff 로 확인).
- openMSX 의 Sony_HB-F1XV 에서는 재현되지 않는다.

원인 추정: `load` 는 머신팩(ioctl_index 1)만이 아니라 **FW 팩(2)과 SLOT A/B ROM 로드(3/4)
에서도** 뜬다. 즉 게임을 로드할 때마다 클리어가 돈다. 그 뒤 `STATE_READ_CONF` 가
`ddr3_addr < ioctl_size[0]` 동안 머신팩을 다시 훑으며 `CONFIG_DEVICE` 로 비트를 복원해야
하는데, 실기에서는 복원되지 않는 경로가 있는 것으로 보인다. **정확한 메커니즘 미확인.**

## 다시 손대기 전에 갖출 것

1. **"머신팩 로드 → ROM 로드" 를 재현하는 벤치.** 현재 어떤 TB 도 이 순서를 돌리지 않는다.
   그래서 sim 전건 통과 상태로 실기 회귀가 나갔다.
2. 그 벤치에서 (a) 팩 교체 시 누수가 사라지는지, (b) ROM 로드 뒤 장치 비트가 **살아있는지**
   둘 다 확인. 둘 중 하나만 보면 이번 실수를 반복한다.
3. 유력한 방향: 클리어를 **머신팩 로드(ioctl_index 1)로 스코핑**. 다만 위 벤치 없이는 넣지 말 것.

`sim/check_upload_accum_clear.py` 는 이 예외를 알고 있으며, 예외가 사라지면(=제대로 고쳐지면)
스스로 조용해진다.

## 교훈

실기 회귀를 낸 수정의 근거가 "명백히 옳아 보임"이었다. 누수는 **음성 대조**로 잡았지만
수정 자체는 **대조 없이** 나갔다 — 고친 쪽만 보고 안 깨졌는지는 안 봤다.
관련: `docs/hwtest_20260830a.md`
