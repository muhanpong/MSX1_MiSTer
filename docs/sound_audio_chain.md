# 사운드 계통과 네 번의 포화

음원 일곱 갈래가 16비트 스테레오 하나로 합쳐지기까지 게인이 다섯 번, 클리핑이 네 번
걸린다. 어디서 잘리는지 알면 어디서 올리면 안 되는지도 안다.

행 번호는 `MSX1_20260904b_audiofix` 빌드 기준.
웹 버전(계통도 SVG): https://claude.ai/code/artifact/798ff11c-ca53-453b-b3e1-6d5ef7e06f02

---

## 1. 계통도

```
 카트리지 슬롯                      본체                     MoonSound OPL4
 ─────────────                     ────                     ──────────────
 OPLL  ──── ×vol_mul ──┐    PSG + 비프 + 테이프        OPL3 FM        PCM 엔진
 SCC A+B ── ×vol_mul ──┼─ Σ      10b unsigned              │              │
 카트 PSG ─ (트림 없음)┘  19b         │                    │      고정 −12.04 dB
                          │        ×psg_mul                │      + 엔진 클램프
                          ①            │                   │              │
                       ±32767      10b 클램프           ×fm_gain      ×pcm_post
                          │            │                   └──── Σ ───────┘
                     cart_sound       fm                    22b, >>>7
                        16b          17b                        │
                          └──── Σ ────┘                         ③ ±32767
                            mono_mix 17b                        │
                                 │                          ms_out L/R
                                 ② 포화 압축기                  │
                                   (선형 구간 ×2)      moonsound_en ? : 0
                                 │                              │
                          mono_audio 16b 모노                   │
                                 └────────── Σ ────────────────┘
                                       mix_l / mix_r 17b
                                              │
                                              ④ 부호 불일치 시에만 클립
                                              │
                                      AUDIO_L / AUDIO_R
                                        (msx_pause 면 0)
```

세 갈래가 아래로 합쳐진다. 카트 PSG만 게인 단이 없고, MoonSound PCM만 엔진 안에서
이미 한 번 잘린 뒤에 트림을 받는다. 스테레오가 생기는 유일한 지점은 OPL4다.

## 2. 포화 지점 네 곳

| # | 위치 | 동작 | 들어오는 폭 | 나가는 폭 |
|---|---|---|---|---|
| ① | `msx_slots.sv:130` | ±32767 하드 클램프 | 19b signed | 16b `cart_sound` |
| ② | `msx.sv:217` | 포화 압축기 — 상위 3비트가 `000`/`111`이면 선형(×2), 아니면 클램프 | 17b signed | 16b `mono_audio` |
| ③ | `ymf278b_top.sv:502` | ±32767 하드 클램프 | 22b signed | 16b ×2 `ms_out` |
| ④ | `msx.sv:226` | 부호 비트 불일치일 때만 클립 | 17b signed | 16b ×2 `AUDIO` |

다섯 번째가 하나 더 있다 — OPL4 PCM 엔진이 클램프 **전에** 고정으로 먹는
`PCM_HEADROOM` = −12.04 dB (`ymf278b_top.sv:369`). OSD 트림은 그 뒤에 걸린다.

## 3. 게인 사다리

넷 다 `x/128` 배율에 2 dB 눈금, 오차 0.03 dB 이내. 다른 건 **0번 항목이 어디 놓였는가**뿐.

| 음원 | 사다리 | 폭 | entry 0 | 뮤트 | 정의 |
|---|---|---|---|---|---|
| 내장 PSG | `psg_mul` | `[8:0]` unsigned | 128 · 0 dB | `PSG Mute` `[62]` | `msx.sv:198` |
| OPLL (MSX-MUSIC) | `vol_mul` | `[9:0]` signed | 128 · 0 dB | `MSX-MUSIC Mute` `[63]` | `msx_slots.sv:104` |
| SCC (A+B 공용) | `vol_mul` | `[9:0]` signed | 128 · 0 dB | `SCC Slot A/B` `[61:60]` | `msx_slots.sv:104` |
| OPL4 PCM | `pcm_post` | `[11:0]` | 128 · 0 dB | 뮤트 별도 | `ymf278b_top.sv:371` |
| OPL4 FM | `fm_gain` | `[11:0]` | **203 · +4 dB** | 뮤트 별도 | `ymf278b_top.sv:390` |
| 카트리지 PSG | — | — | — | **없음** | `msx_slots.sv:686` |

## 4. 코드를 읽어야 보이는 것

**① 카트리지 PSG는 OSD로 만질 수 없다.**
`DEV_PSG`를 선언한 카트리지의 PSG(`sound_psg`)는 트림 없이 `snd_sum`에 바로 들어간다.
일곱 음원 중 유일하게 볼륨도 뮤트도 없다. 메뉴의 "PSG Volume"은 본체 PSG만 건드린다.

**② PSG 트림은 세 신호를 한꺼번에 잡는다. 뮤트는 아니다.**
`audioPSG` = PSG 채널 + 키보드 비프(PPI 포트 C 비트 7, `msx.sv:544`) + 테이프 입력.
실기도 이 셋이 한 믹서로 가므로 트림이 공용인 건 맞다. 그러나 `PSG Mute`는 `ay_ch_mix`
**하나만** 끊는다(`msx.sv:189`) — `psg_mul`을 0으로 만드는 방식이었다면 비프와 테이프까지
죽었을 것이다. **실기 확인됨(20260904): 뮤트해도 키보드 비프는 살아 있다.**

뮤트를 볼륨 사다리의 11번째 칸으로 넣지 않은 이유도 같은 맥락이다 — 연속량(게인)과
상태(뮤트)는 다른 종류다. 게다가 사다리 끝에 두면 가장 자주 쓰는 조작이 10번 눌러야
닿고, 껐다 켜면 맞춰둔 트림이 날아간다. MoonSound 블록이 원래 그렇게(뮤트 별도 행)
되어 있었고, 나머지도 거기 맞췄다.

**③ OPL4 PCM은 잘린 뒤에 트림을 받는다.**
엔진이 클램프 전에 `PCM_HEADROOM`으로 고정 −12.04 dB를 먹이고, OSD 트림 `pcm_post`는
그 클램프 **뒤**에 붙는다. 그래서 엔진 단계에서 이미 포화한 소재는 +8 dB로 올려도
복구되지 않는다 — 잘린 파형이 커질 뿐이다.

**④ 모노 압축기는 선형 구간에서 2배 한다.**
②는 단순 클램프가 아니다. `mono_mix[16:14]`가 `000`이나 `111`이면
`{sign, mono_mix[13:0], 1'b0}`를 내보낸다 — 끝의 `1'b0`가 왼쪽 시프트, 즉 ×2다.
본체 계열 전체가 여기서 6 dB를 얻고 그만큼 헤드룸을 잃는다.

**⑤ 스테레오는 MoonSound뿐.**
①②를 거친 `mono_audio`는 좌우에 같은 값으로 들어간다. 정위가 생기는 유일한 지점은
OPL4의 `ms_out_l/r`이다.

**⑥ `vol_mul`이 signed `[9:0]`인 데는 이유가 있다.**
signed 9비트는 255에서 넘친다. +8 dB 항목의 322가 −190으로 읽히면 **채널 전체의 부호가
뒤집히고** 하류에서 감지할 방법이 없다. 폭을 10비트로 넓혀 막아뒀다. `psg_mul`은
unsigned라 애초에 이 함정이 없다 — 겉보기에 같던 두 표의 헤드룸이 실은 달랐다.

## 5. 실무 규칙

클리핑이 상류에 있으므로 **부스트는 가능한 한 하류에서** 하는 게 안전하다. 특정 음원이
작다고 그 음원 트림을 +8 dB로 올리면 ①이나 ③에서 잘리고, 그 왜곡은 ④에서 되돌릴 수
없다. 상대 밸런스를 맞출 때는 **큰 쪽을 내리는 편이** 파형을 지킨다.

OPL4 FM만 0번 항목이 +4 dB에 놓여 있다. 오류가 아니라, 사용자가 실제로 듣던 게인을
0번에 유지하려고 사다리를 회전시킨 결과다. 다른 음원과 같은 눈금이라고 생각하고
비교하면 4 dB를 놓친다.

## 6. 출처

- `rtl/msx.sv` — 내장 PSG 계열, 모노 믹스, 최종 포화
- `rtl/peripheral/slots/msx_slots.sv` — OPLL / SCC / 카트 PSG 합산, `vol_mul`
- `rtl/peripheral/slots/scc_sound.sv:23` — SCC A/B 파형 믹스(`oe` 게이트)
- `rtl/peripheral/SOUND/ymf278b_fpga/rtl/ymf278b_top.sv` — OPL4 FM/PCM 게인과 포화

관련: [[project_volume_ladder_2db]], [[project_opl4_level_calibration]],
[[feedback_gain_changes_need_permission]]
