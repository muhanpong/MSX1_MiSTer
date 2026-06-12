# 골든 비교 결과 (2026-06-12)

## PCM — RTL(ymf278_pcm_engine2) ↔ YMF278.cc 파이썬 모델
`./run_pcm_golden.sh`

| 시나리오 | 결과 |
|---|---|
| sc_single8 (8-bit, keyon/off) | **100% 비트 일치** (maxd=0) |
| sc_square16 (16-bit, 옥타브 스윕) | **100% 비트 일치** |
| sc_tri12_loop (12-bit 루프심, 팬 스윕) | **100% 비트 일치** |
| sc_multi (4보이스, 리키/웨이브체인지) | **100% 비트 일치** |
| sc_lfo (vib+trem) | **100% 비트 일치** |

하네스가 잡아서 수정한 RTL 버그 2건:
1. `cur_slot` 리셋 누락 → 리셋 직후 프레임의 헤더페치/슬롯 비정상
2. **지연 헤더 백필이 wave# 이후의 CPU 파라미터 쓰기를 덮어씀** (openMSX는 동기 백필)
   → dirty-mask로 수정. 묵은 "custom-PCM 음색 오류"의 유력 원인.

비교 시 주의: openMSX 대비 RTL 의도적 차이(모델 wrapper가 반영) —
eg_cnt 오프바이원, EG_OFF 슬롯 LFO 미진행, vib ÷12 절단방향(0방향).

## FM — RTL(gtaylormb opl3) ↔ Nuked-OPL3 (실칩 비트정확 레퍼런스)
`fm/run_fm_golden.sh` (Verilator 코심)

| 시나리오 | 샘플상관 | 포락선상관 | 레벨비 | 판정 |
|---|---|---|---|---|
| 2op_tone | 1.00000 | 1.0000 | 1.000 | OK (0.16% RMS) |
| envelope | 1.00000 | 0.9999 | 1.000 | OK |
| chord_dualbank | 0.99984 | 1.0000 | 1.000 | OK |
| rhythm | 0.793 | 0.9962 | 1.066 | OK(포락선) — 노이즈 LFSR 위상차 |
| vib_only | 0.951 | 0.9985 | 1.000 | OK(포락선) — LFO 위상차 |
| trem_only (수정 후) | **0.99984** | 0.9954 | 1.006 | **OK** (1.87% RMS) |
| 4op | 0.99769 | 0.9997 | 1.000 | OK |

### 발견 → 수정 완료된 FM 버그 (2026-06-12)
**envelope_generator의 `am` 파이프라인 미정렬** (업스트림 gtaylormb 버그):
calc_phase_inc는 vib를 `pipeline_sr`로 p2에 정렬하지만 env 가산은 raw `am`을
소비 → 2슬롯 뒤 op의 속성이 적용되어 트레몰로가 사실상 무효였음
(deep 4.8dB가 0.09dB로 측정됨; 전 op에 am=1을 주면 정상 = 정렬 증명).
vib와 동일하게 `am_sr` 추가로 수정 → trem_only 1.87% RMS/corr 0.99984.
잔여 미세 단서(비차단): TREMOLO_MAX_COUNT 13312 vs 실칩 13440, 폴드식 불연속.

## 제3자 코드
`third_party/nuked_opl3.[ch]` = Nuked-OPL3 (Nuke.YKT, LGPL 2.1) —
로컬 검증 전용, 합성/배포 대상 아님.
