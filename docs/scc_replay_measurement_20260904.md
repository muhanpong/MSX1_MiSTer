# SCC+ 잡음 — 레지스터 스트림 재생 계측 (2026-09-04 후속3)

## 목적
g_sccIso(사운드포트 격리)+h_deform(deform 부활) 배포 후에도 "여전히 잡음이
심함". 격리된 IKASCC 칩이 실제로 얼마나 벗어나는지를 **추측 없이** 확정하려고,
openMSX가 실제 연주한 SCC+ 레지스터 쓰기 스트림을 그대로 우리 RTL에 재생해
동일 스트림의 openMSX 오디오와 비교했다.

## 방법 (다음 세션 재현용)
1. **캡처**: `openmsx -machine Sony_HB-F1XV2MB -exta scc+ -extb scc+ -diska
   SCMD110A.DSK`, `SC PASSINGB.SDT`(확장자 필수, 128KB 머신은 Out of memory).
   watchpoint로 A슬롯(primary==1) 0xB800/0x9800 write_mem을 시각·주소·값 로깅
   + 동시에 `record start -audioonly` solo 녹음(다른 음원 volume 0).
   - OPENMSX_HOME 격리 사본 필수: share에 machines/extensions/unicodemaps/
     scripts/icons/init.tcl/settings.xml **복사**(systemroms만 심링크 OK).
     전체 심링크는 openMSX가 segfault.
2. **재생 TB** `tb_sccreplay.sv`: scc_sound에 캡처 스트림을 tick 정확히 주입,
   wave_A를 3.58MHz로 덤프. **iverilog는 5초에 90분(느림)** → **verilator
   `--binary --timing -O3`으로 47초**. 반드시 verilator.
3. **이상 렌더러** `render_ideal.py`: openMSX SCC.cc 알고리즘((wav*vol)>>4,
   period+1 카운터, deform&0x20 pos리셋, freq쓰기시 out즉시갱신)을 1-tick
   해상도 numpy로 구현. **openMSX 녹음과 전 대역 ±0.2dB 일치** = 검증된 레퍼런스.

## 결과

**대역 비교 (500-2000Hz가 핵심 성부대역):**

| | 500-1kHz | 1-2kHz |
|---|---|---|
| 이상 렌더러 vs openMSX | -0.09 dB | +0.02 dB |
| **RTL 빌드 f (수정 전)** vs openMSX | **+6.98** | **+5.54** |
| **RTL 현재(g+h)** vs openMSX | **+1.46** | **+2.87** |

g+h 수정이 재생 계측에서 **실제로 크게 개선**됨(+7→+1.5dB). 사용자의 "조금
좋아졌다"와 정량 일치.

**현재 RTL의 잔여 성격:**
- 합산 wave_A vs 이상: gain 0.96, **파형상관 0.964**, 잔차 **-11.5 dB**.
- **진짜 1-tick 임펄스 = 채널·합산 모두 0건.** crackle성 스파이크 없음.
- 잔차 스펙트럼 저피키니스(2-6dB)=**브로드밴드**, 고역일수록 큼. 하모닉 왜곡
  아님 = 실칩 특유의 미세 타이밍/양자화 성격(openMSX는 이상화라 이게 없음).
- 채널별 잔차: ch1 **-31dB(거의 완벽)**, ch2/3/4 ~-10dB, ch5 -10.7dB.
  ch1은 freq/vol 재기록이 드물어 완벽, 나머지는 상시 재기록 성부.

## 확정된 결론
**격리된 IKASCC 칩(현재 RTL)은 openMSX와 mids +1.5~2.9dB, 파형상관 0.96,
임펄스 0건 = 실질적으로 깨끗.** openMSX는 이상화 모델이지 실기 정답이 아니므로,
실기는 이 브로드밴드 성격이 **더** 많지 덜하지 않다. 남은 "심한 잡음"은 칩
자체일 가능성이 낮다.

## 다음 용의자 (칩 밖)
1. **통합 믹스/포화**: `msx.sv:216` 모노 컴프레서 선형창이 **14비트(±16383)**
   뿐 — cart_sound(16비트 ±32767)가 그 위면 하드클립. SCC 단독은 ±4352라 안전,
   **FM+SCC 합산(Passing Breeze는 FM곡)** 로 진입 가능. Out Run 실측 FM -4.5/SCC
   -5.1 dBFS(project_scmd_outrun_levels)라 합산시 클립 여지 있음. 단 이건 SCC
   전용도 아니고 기존 구조라 회귀 아님.
2. **보드의 레지스터 전달 게이팅**: 재생 스트림은 openMSX 출처. 보드는 T80이
   scc_req/msx_slots 게이팅으로 칩에 씀. 게이팅이 다르면(여분/누락 쓰기) 보드
   칩 출력이 이 깨끗한 재생과 갈림. konami_scc.sv bank-mask는 아직 미커밋.
   full-mapper+chip 재생으로 검증 필요(미착수).

## 미해결/사용자 확인 필요
- 지금 잡음이 **튀는 crackle**인가 **탁한/거친 톤**인가? (원인 계통이 다름:
  crackle=게이팅/임펄스, 톤=믹스포화/실칩성격)
- **SCC만**(FM 뮤트)으로도 잡음이 심한가, **FM 켤 때만**인가? FM 켤 때만이면
  1번(믹스 포화)로 좁혀진다.

## 계측 자산
`$CLAUDE_JOB_DIR/tmp`는 잡 삭제시 소멸. 재생성 스크립트: render_ideal.py,
render_ideal_ch.py, tb_sccreplay.sv, compare_replay.py (이 세션 tmp에 있었음).
캡처 원본만 durable 복사 권장: sccrep.log + sccrep0001.wav.
