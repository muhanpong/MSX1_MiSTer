# 핸드오프 — SCC+ 지직거림, 원인은 파형 재기록 교란 (2026-09-04)

## 한 줄 결론

SCC+ 지직거림은 **슬롯 문제가 아니라 성부 문제**다. 계측으로 확정: 보드가
openMSX에서 벗어나는 건 **파형 RAM을 자주 고쳐 쓰는 성부(타악기)뿐**이고,
파형이 고정인 성부(반주)는 openMSX와 ±0.5 dB로 일치한다. 범인은
`IKASCC_player_s.v`의 `ram_rdrq`가 CPU의 파형 RAM 접근 사이클 동안 채널
출력을 CPU 주소 바이트로 오염시키는 것 — 매 파형 쓰기마다 글리치가 섞인다.

## 결정적 증거 — 성부별 4자 비교

곡: **Passing Breeze** (SCMD). 이 곡은 OPLL / SCC+ A / SCC+ B가 **각각 다른
성부**를 연주하는 다중칩 편곡. A = 타악기 리듬부, B = 반주부.

무손실 캡처(HDMI→ezcap IEC958 48kHz) vs openMSX(soxr 48kHz), 성부별로 격리
(다른 음원 볼륨 0), 곡 시작부터 정렬(포락선 템포비 + FFT 샘플 지연).

```
대역        A성부(타악기)     B성부(반주)
30-200 Hz     -1.9 dB          +0.3 dB
200-500       +4.5             +0.0
500-1000      +6.6  ★          +0.5
1000-2000     +5.1             -0.1
2000-4000     +2.5             +0.3
4000-8000     +1.1             +0.4
8000-16000    +2.2             +0.0
```

**B 성부는 openMSX와 사실상 일치, A 성부만 크게 벗어난다.** 파형 상관도
A 0.345 / B 0.154(B는 곡 특성상 원래 낮음), 포락선 상관 A 0.985 / B 0.910.

이전에 "A만 더럽고 B는 깨끗"으로 관측된 슬롯 비대칭은 착시였다 —
실제로는 **A 슬롯에 타악기부가, B 슬롯에 반주부가 배정**된 것. 슬롯을 바꿔
꽂으면 더러움도 따라갈 것으로 예측된다(미검증, 다음 세션 확인거리).

## 메커니즘 — IKASCC_player_s.v

```verilog
// 각 채널 파형 주소 (ch1 예, :96)
wire [4:0] ch1_ram_addr = ch1_ram_rdrq ? ch1_ram_addr_cpu : ch1_ram_addr_cntr;

// ram_rdrq 생성 (:491, RAMCTRL_ASYNC=1 브랜치가 합성됨)
//wire ram_rdrq = ~(i_CS_n | i_RD_n) & i_SCCREG_EN & (addr_lo[7:5]==ADDR_RAM_BASE[7:5]); // 원본, 주석처리됨
wire   ram_rdrq = ~(i_CS_n)          & i_SCCREG_EN & (addr_lo[7:5]==ADDR_RAM_BASE[7:5]); // 현재 합성
```

`ram_rdrq`가 뜨면 채널이 위상 카운터 대신 CPU 주소로 파형 RAM을 읽는다.
`i_RD_n`이 빠져서 **CS가 잡힌 사이클 전체**(읽기·쓰기·유휴 포함)로 늘어나
있고, SCC 드라이버가 파형을 상시 재기록하는 성부에서는 매 쓰기가 한 번씩
채널 출력을 오염시킨다. 실칩(단일 포트 RAM)에도 있는 거동이지만 openMSX는
모델링하지 않으므로 보드만 거칠다. 실칩 대비 과한지 여부는 미측정.

## ⛔ 함정 — 순진한 복원은 회귀

`ram_rdrq`에 `i_RD_n`을 그대로 되살리면 **파형 쓰기 주소까지 죽는다**
(`ch_ram_addr`가 쓰기 시에도 CPU 주소여야 하는데 카운터 주소로 나감).
실측 회귀: `run_sccplus` 45/0 → **12/33**, `run_sccdetect` 47/10 → 37/20.
기준선은 `$CLAUDE_JOB_DIR/tmp/baseline_repo`에 사본을 만들어 확인했다.

`4bfe491`("async ram timing fixes", 2026-04-12, 본인 커밋)에서 뺀 것은
실수가 아니라 필요한 조치였다. **읽기와 쓰기의 주소 소스를 분리**해야 한다:
- 쓰기: 지금처럼 CS 기반 (i_RD_n 없이)
- 읽기(파형 하이재크): i_RD_n 또는 i_RDRQ로 좁혀 실제 CPU 읽기에만

## 다음 수정 방향 (미착수)

`ram_rdrq`(하이재크 게이트)와 `ram_wrrq`(쓰기 게이트)를 이미 별개 신호로 갖고
있으므로, `ch_ram_addr` 먹스가 "쓰기 중에는 카운터 주소를 쓰면 안 되는" 이유가
정확히 무엇인지부터 파악할 것 — 쓰기 데이터가 CPU 주소로 가야 하는 건
`o_RAM_ADDR_CPU`(=addr_lo[4:0]) 경로이고, 채널 사운드 출력용 읽기 주소와는
다른 소비처일 수 있다. `IKASCC_player_memory_s`(:341 부근)에서 wrrq일 때
`i_RAM_ADDR`이 어디서 오는지 추적이 관건. TB로 "타악기풍 쓰기 폭풍"을
넣어 교란 에너지를 정량화하는 시뮬을 먼저 만들 것(sim/run_sccplus.sh 기반).

가능하면 **RAMCTRL_ASYNC 브랜치를 건드리지 말고** ch_ram_addr 먹스에서
읽기(사운드)와 쓰기(CPU) 경로를 분리하는 쪽이 안전. 시뮬 45/0 유지가
합격 기준.

## 현재 빌드 / 워킹트리

- 보드·로컬 최신 = **MSX1_20260904f_bankmask** (11:32). 오늘 SCC 3수정 포함:
  d_sccmode(scc2_slot 게이팅) / e_sccreq(cs 검증) / f_bankmask(mem_size 마스크).
  이 셋으로도 지직거림은 **안 사라짐**(사용자 판정 "아주 더럽다"). 별개 경로.
- 미커밋: `rtl/peripheral/slots/konami_scc.sv` (bank mask, 실기 반영됨/미커밋).
- IKASCC는 원복 완료(git status 0). ram_rdrq 실험 빌드는 중단·폐기, rbf 없음.

## 측정 자산

```
tools/audio_fp/openmsx_scc_slotA_from_start.wav   openMSX A성부 레퍼 18.0s
tools/audio_fp/openmsx_scc_slotB_from_start.wav   openMSX B성부 레퍼 29.7s
tools/audio_fp/board_scc_slotA_lossless.wav       보드 A HB-F1XV 2MB 45.4s (곡 2.59s~)
tools/audio_fp/board_scc_slotA_lossless_B.wav     보드 A HB-F1XDmk2 2MB FM (26.66s~)
tools/audio_fp/board_scc_slotA_fsa1f_1mb.wav      보드 A FS-A1F 1MB (14.42s~)
tools/audio_fp/board_scc_slotB_f1xv2mb.wav        보드 B HB-F1XV 2MB (32.40s~)
tools/audio_fp/audio_fingerprint.py               지문 도구
```

무손실 캡처:
```
parecord --device=alsa_input.usb-ezcap_ezcap_GAMEDOCK_ULTRA_00000001-02.iec958-stereo \
         --file-format=wav --rate=48000 --channels=2 --format=s16le out.wav
```
openMSX 소켓 헬퍼: `$CLAUDE_JOB_DIR/tmp/omsx.py` (세션별 경로라 재생성 필요).
볼륨 설정 이름은 `[openmsx_info setting]`을 `|`로 join해 파싱(공백 포함 이름).
카트 두 장 = "Konami SCC+ Cartridge with expanded RAM"(A, slot1) / 동 "(1)"(B, slot2).

## 방법론 교훈 (이번에 밟은 함정)

1. **화면녹화 mp4 = AAC 손실.** 18kHz 위 잘리고 파형 미보존 → 파형 비교 불가.
   반드시 캡처 카드에서 parecord로 직접 받을 것.
2. **정렬 전 비율 지표는 레벨차를 결함으로 오독.** `Δ/포락선` 스파이크,
   정규화 대역 비중 둘 다 폐기. 정렬(템포비+샘플지연+이득정합) 후에만 비교.
3. **성부별 격리가 핵심.** 슬롯 비대칭으로 보이던 것이 성부 배정 차이였다.
   openMSX에서 성부별 레퍼를 잡아 4자 비교해야 슬롯/성부가 갈린다.

관련: docs/scc_pack_divergence_20260904.md,
[[project_scc_plus_crackle]], [[feedback_ikascc_player_s_integration]],
[[feedback_verify_synthesized_module]], [[reference_openmsx_measurement_harness]]
