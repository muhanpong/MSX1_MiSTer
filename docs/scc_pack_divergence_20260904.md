# SCC+ 지직거림 수사 — 2026-09-04 측정 기록

팩에 따라 SCC+ 소리가 갈린다는 보고를 계측으로 확인하려던 하루. **팩 차이는
재현되지 않았고**, 대신 팩과 무관한 코어–openMSX 격차가 정량화됐다.

## 1. 측정 체계

| 항목 | 내용 |
|---|---|
| 보드 | HDMI → ezcap GAMEDOCK ULTRA → IEC958 디지털 48 kHz 무손실 |
| openMSX | `record` 무손실 WAV 44.1 kHz → soxr로 48 kHz |
| 조건 | SCC+ 슬롯 A만, PSG/MSX-MUSIC/SCC B 뮤트, 곡 처음부터 |
| 정렬 | 포락선 상관으로 템포비 탐색 → FFT 교차상관으로 샘플 정렬 → 최소자승 이득 정합 |

**초기에 쓴 화면녹화 mp4는 AAC 손실 압축이었다.** 18 kHz 위가 잘리고 파형이
보존되지 않는다. 무손실로 다시 재니 대역 수치는 거의 같았지만(±0.02 dB),
방법론상 비교 대상이 되지 못한다. 캡처 카드에서 직접 받는 경로를 쓸 것.

## 2. 폐기한 지표 둘

- **스파이크/초** — `Δ/포락선 > 8` 비율 기준이라 RMS가 낮은 쪽이 자동으로
  부풀려진다. 절대 `|Δ|` 임계로 재니 순위가 뒤집혔다.
- **정렬 전 대역 비중** — 레퍼런스 에너지의 80 %가 200 Hz 이하라 정규화가
  끌려가 보드가 전 대역에서 초과로 보였다.

교훈: 정렬되지 않은 두 신호의 비율 지표는 레벨차를 결함으로 오독한다.

## 3. 팩 비교 결과 — 차이 없음

같은 곡, 같은 캡처 경로, 같은 뮤트 조건.

| 대역 | A: HB-F1XV 2MB | B: HB-F1XDmk2 2MB FM | C: FS-A1F 1MB | C−A |
|---|---:|---:|---:|---:|
| 30–200 Hz | 52.25 % | 52.63 % | 52.52 % | +0.02 dB |
| 200–500 | 18.86 | 18.42 | 18.71 | −0.03 |
| 500–1000 | 9.37 | 9.34 | 9.30 | −0.04 |
| 1–2 kHz | 5.49 | 5.49 | 5.34 | −0.12 |
| 2–4 kHz | 6.01 | 6.08 | 6.12 | +0.08 |
| 4–8 kHz | 6.26 | 6.26 | 6.24 | −0.01 |

C는 사용자가 "나쁘다"고 지목한 팩인데 A와 **±0.12 dB** 안에서 같다.

타이밍도 같다 — 국소 지연 표준편차 A 6.48 ms / B 3.54 / C 4.99, 누적 드리프트
셋 다 17초에 ~1 ms. **나쁜 팩이 오히려 더 안정적이다.**

측정계 자체는 세 독립 캡처가 ±0.1 dB로 일치하므로 분해능 부족이 아니다.
**뮤트로 SCC+ A만 남긴 조건에서는 팩 차이가 존재하지 않는다.**

## 4. 팩과 무관한 코어–openMSX 격차

세 팩 모두 openMSX와 같은 방식으로 다르다.

```
포락선 상관  0.975   (같은 음, 같은 타이밍)
파형 상관    0.344   (파형 자체가 다름)
빼기 잔차    원신호 대비 -0.55 dB (거의 안 지워짐)

  30-200 Hz  80.4% -> 52.2%   -1.9 dB
 200-500      6.7% -> 18.9%   +4.5
 500-1000     2.1% ->  9.4%   +6.6
1000-2000     1.7% ->  5.5%   +5.2
16-20 kHz    0.25% -> 0.39%   +1.9
```

기본파가 상대적으로 약하고 중역 배음이 강하다. **고역 초과는 미미해
에일리어싱 모양이 아니다.** IKASCC가 실칩 재현을 목표로 하므로 openMSX보다
거친 것이 정상일 가능성이 있다 — 결함으로 단정할 근거는 아직 없다.

## 5. 기각한 가설

**에일리어싱 / 안티에일리어싱 필터 부재**
`sys/audio_out.v`의 IIR은 다운샘플 **앞**에 있고, RTL 기본 계수는 −3 dB
10.3 kHz·24 kHz에서 −22.6 dB의 진짜 안티에일리어싱 필터다. 다만 HPS가 `0x39`로
덮을 수 있고 보드 `MiSTer.ini`에 `afilter_default`가 없다. 펌웨어 소스가 없어
미선택 시 통과 계수를 내려보내는지는 **단정하지 않는다**. 실측상 고역 초과가
+1.9 dB뿐이라 어느 쪽이든 주범은 아니다.

**IKASCC 채널 합산 오버플로**
`o_SOUND <= ch1..ch5` — 채널이 8비트 signed 5개, 목적지 11비트. 여유 있다.

**`ram_rdrq`에서 `i_RD_n`이 빠진 것** ← 오독이었다
```verilog
ch1_ram_addr = ch1_ram_rdrq ? ch1_ram_addr_cpu : ch1_ram_addr_cntr;
```
이 신호는 "CPU 읽기"가 아니라 **"CPU가 RAM 주소를 쥔다"**는 뜻이라 **쓰기에도
필수**다. `i_RD_n`으로 좁히면 파형 쓰기가 위상 카운터 주소로 나간다.
복원 시뮬레이션: `run_sccplus` 45/0 → **12/33**, `run_sccdetect` 47/10 → 37/20.
`4bfe491`에서 뺀 것은 실수가 아니라 필요한 조치였다. 되돌림 완료.

## 6. 남은 것

사용자는 실사용에서 팩 차이를 분명히 구분한다. 이번 시험은 **SCC+ A만 켜고
나머지를 다 뮤트한** 조건이었으므로 실사용과 다르다. 다음 단계는 **아무것도
뮤트하지 않은 전체 믹스**를 좋은 팩/나쁜 팩으로 잡아 비교하는 것. 여기서
차이가 나오면 합산·포화 단(`msx.sv:217` 모노 압축기의 선형 구간 ±16,383)이
용의선상에 오르고, 안 나오면 그 가설도 죽는다.

## 7. 산출물

```
tools/audio_fp/openmsx_scc_slotA_from_start.wav   openMSX 레퍼런스 18.0s
tools/audio_fp/board_scc_slotA_lossless.wav       A  HB-F1XV 2MB      45.4s
tools/audio_fp/board_scc_slotA_lossless_B.wav     B  HB-F1XDmk2 2MB FM 23.3s
tools/audio_fp/board_scc_slotA_fsa1f_1mb.wav      C  FS-A1F 1MB        35.6s
tools/audio_fp/{ref,board}_aligned.wav, residual.wav
tools/audio_fp/audio_fingerprint.py
```

무손실 캡처 명령:
```
parecord --device=alsa_input.usb-ezcap_ezcap_GAMEDOCK_ULTRA_00000001-02.iec958-stereo \
         --file-format=wav --rate=48000 --channels=2 --format=s16le out.wav
```

관련: [[project_scc_plus_crackle]], [[project_scc_ch5_d5_closed]],
[[feedback_verify_the_detector_first]], [[reference_openmsx_measurement_harness]]
