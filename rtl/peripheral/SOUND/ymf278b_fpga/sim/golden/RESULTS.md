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
| **trem_only** | 0.988 | **0.697** | **1.337** | **실편차** |
| 4op | 0.99769 | 0.9997 | 1.000 | OK |

### 발견된 FM 편차 (후속 수정 후보)
**트레몰로가 레퍼런스 대비 평균 ~2.4dB 얕음** (lvl=1.337 = 평균 감쇠 부재 수준).
단서: `opl3_pkg TREMOLO_MAX_COUNT=13312` vs 실칩 주기 13440(210×64),
tremolo.sv 삼각파 폴드식(`2*26 + ~val`)의 불연속. 정확 원인은 하네스의
가설→패치→재측정 루프로 격리할 것. vibrato는 포락선 기준 정상.

## 제3자 코드
`third_party/nuked_opl3.[ch]` = Nuked-OPL3 (Nuke.YKT, LGPL 2.1) —
로컬 검증 전용, 합성/배포 대상 아님.
