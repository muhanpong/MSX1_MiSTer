# 인수인계 2026-10-20: 한자·Neon 실기 해결, 요청 단일 표본(ch2_req_s)

브랜치 `sdram128-study`(worktree `~/data/MiSTer_build/sdram128`), nextz80(03f7653) 위, **push 안 함**.
128.86 MHz 단일 구조. 앞 문서: `handoff_20261018_neon_kanji.md`(그 0절의 미해결 둘이 이번에 풀림).
수정 주체: 이번 RTL·SDC는 사용자 결정으로 이 세션(msx1-handoff)이 만들었고, core_builder가 교차검토함.

## 0. 지금 상태 한눈에

| 항목 | 상태 | 근거 |
|---|---|---|
| 한자 D9h (실기 0-8/4096이던 것) | **해결**. 수정 B(7b27baf) | 실기 20261019a, 19b 모두 4096/4096 x4 |
| Neon Horizon 배경 깨짐 (128 MB 보드) | **해결**. ch2_req_s(b1b2d7f) | 실기 19a 악화 → 19b 3회 깨짐 없음. 논리 차이는 ch2_req_s 하나 |
| 배포 후보 rbf | `output_files/MSX1_20261019b_sdram128_481569a.rbf` md5 170441aa520a33084a922efc8e70da32 | Quartus 17.0.2, SEED 10, TIMING PASS |
| 남은 확인 | 사용자 보드 전원 사이클·긴 플레이(복원한 진행 세이브로 뒤쪽 장면) | mister-super-expert는 코어 재로드만 함 |
| 툴체인 교차 | core_builder 17.1 buildgate로 1f4a7e0 재fit 제안함(미실시) | 이 rbf는 17.0 + compile.sh, buildgate 미경유 |
| 32/64 MB 보드 | stock 기한(tb_tdm E0+28)이 둘째 에지 감지에서 3/36 위상 LATE — fullsys에선 무해(T80 여유 69.8 ns) | 0d7da22, 68ce6cd; 기한 상수 재정의 필요 |
| 준안정 원리적 제거 | 미착수. (d) 고정 위상 표본 또는 2플롭 | ch2_req_s는 1플롭 동기화기, 해소 시간 = req_s→결정 slack +2.0 ns |
| PCM w_word ← rdaddr_reg | seed에 따라 −0.04 ~ +0.6 ns 오가는 배치 운 경로 | SEED 8/9/10 이력은 MSX1.qsf 주석 |
| V9968 + geo3d | **미통합**. sdram_tdm V 포트는 있으나 MSX1.sv에서 v_en=0 | 원본 `~/data/V9968_Cartridge`, `_alexmoncks`(geo3d) |

## 1. 무엇이 원인이었나 (판정 순서)

1. **스트로브 경쟁 점검 무효 → 재실행.** 10-17의 RPROBE 20판은 프로브가 8255 모드 워드를 안 써서 전부 슬롯 0이었다
   (9bf5a0d). "FFFF←0Fh → RST 38"도 같은 원인 — 코어 결함 아님.
2. **경로별 도착 STA(field_race.tcl).** 스트로브와 같이 출발하는 필드(쓰기 rnw, T80 DO, FFFF 게이트)가 첫 에지를
   넘는다. 주소 쪽은 clk21m 하나 먼저 나와(LEAD: NextZ80 6, T80 ≥12 에지) 대조군으로 통과.
3. **core_builder 67576b3/732de12**: rnw 재확인, FFFF 주소 게이트. 732de12 SDC는 c_pend2를 clk21m 전부에 -end 2로
   걸어 −7.82 실패 → 이 세션이 스트로브 -end 2 / 주소 쪽 -end 8로 나눔(601e17d). 그 rbf(20261019a): 한자 정상, Neon 악화.
4. **악화의 이유 = REQSKEW.** 같은 요청을 받는 ch2_req_1과 ch2_cpend의 도착 차이가 0.4 ns(ae02602)에서 1.09 ns로
   넓어짐(732de12가 cpend 원뿔을 깊게 함, 17.1 fit도 같은 값). 그 창에 에지가 들어오면 req_1은 요청을 보고 cpend는
   못 봐 `req & ~req_1`이 영영 참이 안 됨 → 요청 유실 → stock T80은 버스에 남은 바이트를 읽음.
5. **수정 (a): ch2_req_s 하나만 ch2_req를 본다**(b1b2d7f). 결정은 전부 그 출력, 필드는 그 다음 에지(최소 에지 2).
   SDC: 스트로브 → ch2_req_s -end 2/hold 1, 스트로브 -through ram_rnw → ch2_* -end 2, T80 DO → ch2_din_1/bdin -end 2.
   실기 20261019b: Neon 깨짐 없음.

배제된 것(시뮬로): stock 기한(128 MB 맵 LATE 0, 12부팅 위상 전수 0), 둘째 에지 감지 자체(Neon 9 s VDP·MoonSound
스트림 기준판과 타임스탬프까지 동일, 두 컨트롤러·나쁜 위상 포함). 시뮬은 지연 0이라 REQSKEW를 재현하지 못한다 —
그래서 실기 판별 실험이 필요했다.

## 2. 이번 커밋 (30cddae 이후, 주요한 것)

| 커밋 | 내용 |
|---|---|
| 9bf5a0d | RPROBE PPI 수정, +rwave, EDGEHIST |
| 771591f de3c308 a562550 0a67936 | tools/sdram128/field_race.tcl (tdm/sdram 모드, rnw2, req@레지스터, REQSKEW), LEAD |
| 5dfbafb 606ed4f | core_builder 67576b3, 732de12 merge |
| 2d80d25 b261c10 68ce6cd | fullsys INJ_REQ, +initph/+rstph/FRAMEPOS, +rowxor |
| 601e17d fbe61a4 57ca119 | SDC: c_pend2 스트로브/주소 분리, 리셋→sd_card 2사이클(좁힘) |
| 8e06ef4 1f4a7e0 | relations.tcl 규칙 분리·추가 (REQS_*, RNW_*_ch2, DIN_T80, SD_int_to_ch2 7.760) |
| **b1b2d7f** | **sdram_tdm ch2_req_s + SDC** |
| 481569a | SEED 10 (SEED 9 −0.027 pcm) |
| 증거 | docs/evidence_20261018/, docs/evidence_20261019/ (board_20261019b.txt, reqs_481569a.txt, field_race_*.txt …) |

3f09aaf(nextz80, 85.9 MHz)는 이 세션에서 17.0으로 한 번 빌드함(STA 표용, BUILDGATE PASS, 배포 안 함):
`~/data/MiSTer_build/nz_3f09aaf`(detached, 하네스 파일만 복사·미커밋, build.sh Q 경로는 되돌림).

## 3. 다음 할 일 (제안 순서)

1. 사용자 확인: 전원 사이클 여러 번 + 진행 세이브로 뒤쪽 장면. 깨지면 19b에서도 남는 경쟁 → (d) 착수.
2. core_builder 17.1 buildgate 재fit(1f4a7e0). 두 배치에서 닫히는지, REQSKEW 창(req_s 이후 결정 레지스터는
   내부 단일 사이클이라 REQSKEW 줄은 의미가 바뀜 — field_race는 req_s 출발 기준 slack을 보면 됨).
3. nextz80로 합치기 전 정리: sdram.sv(85.9 MHz)에도 같은 구조가 필요한지(같은 REQSKEW가 출하판에도 STA상 있음,
   실기 무증상), 32/64 MB 맵 기한 상수, PCM w_word 경로 파이프 1단.
4. V9968(+geo3d) 통합 계획: handoff_20261012_sdram128.md 1절의 조건(256 KB 32비트 VRAM 뱅크 3, 12클록 슬롯,
   31 kHz 출력만, 리프레시 7.8 us 미확인)에서 출발.

## 4. 명령

```
cd ~/data/MiSTer_build/sdram128; export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
PX="$HOME/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack/MSX/Panasonic/Panasonic FS-A1GT DOS2.MSX"
# 컨트롤러 RTL을 바꾼 뒤에는 반드시 벤치 사본을 다시 만든다
python3 tb/mkshim_tdm.py rtl/peripheral/sdram_tdm.sv sim/fullsys/gen/sdram_tdm_sim.sv
python3 tb/mkshim.py     rtl/peripheral/sdram.sv     sim/fullsys/gen/sdram_sim.sv
# RPROBE + 주입 (INJ_RNW/DIN/ADDR/UNMAP/REQ; 음성대조 -DSDRAM_NO_REQS, -DSDRAM_NO_RNW2)
XDEFS="-DRPROBE -DINJ_DIN" EXTRA="+kprobe=$PWD/sim/fullsys/rprobe/rprobe.hex +zspeed=0 [+initph=5 +rstph=0] [+rowxor=1]" \
  OUT=/tmp/y sim/fullsys/run_preload.sh tdm128 "$PX" 1500
# 한자
XDEFS="-DKPROBE" EXTRA="+kprobe=$PWD/sim/fullsys/kprobe/kprobe.hex" OUT=/tmp/k sim/fullsys/run_preload.sh tdm128 "$PX" 300
# 단위 벤치
OUT=/tmp/q sim/sdram_tdm/run.sh quick
# 빌드 (사용자 승인 후): Quartus 17.0, compile.sh는 asm을 안 돌림
tools/sdram128/compile.sh ; FROM=fit tools/sdram128/compile.sh   # seed만 바꿨을 때
/home/sysop/data/intelFPGA_lite/17.0/quartus/bin/quartus_asm MSX1 -c MSX1 ; git checkout -- MSX1.qsf
# STA 스크립트 (빌드 아님, 끝나면 git checkout -- MSX1.qsf)
quartus_sta -t tools/buildgate/relations.tcl
quartus_sta -t tools/sdram128/field_race.tcl out.txt tdm
```

## 5. 배운 것 (다음에 같은 실수를 안 하도록)

- **시뮬 PASS는 REQSKEW를 증명하지 못한다.** 지연 0 모델에서는 레지스터 간 도착 차이가 없다. STA로 레지스터별
  도착(field_race req@*)을 재고, 판별은 실기로. 이번에 "시뮬 동일 + STA 창 확대 + 실기 악화 → 단일 표본 + 실기 소거"로 확정.
- **SDC 다중 사이클은 "검사 안 함"이다.** -end 6은 중간 에지의 경쟁을 가렸다(한자, REQSKEW 둘 다). 예외는 실제
  표본 에지에 맞춰 좁히고(-end 2), 좁힌 뒤에는 relations.tcl 규칙으로 그 예외가 살아 있는지 감시(-through 넷 이름).
- **예외 범위는 목적지를 레지스터로.** 클록 전체(-to get_clocks)로 걸면 원하지 않는 소비자(PCM 리셋)까지 풀린다.
- **gen/ 사본**: fullsys는 컨트롤러 RTL이 아니라 mkshim 사본을 컴파일한다. merge·수정 뒤 재생성 안 하면 옛 컨트롤러로 돈다.
- **BIOS를 대신하는 프로브는 PPI 모드 워드(OUT (0ABh),82h)부터.**
- **Quartus 17.0 fit과 17.1 fit은 배치가 다르다**(18분 vs 95분). 17.0 rbf는 판정용, 배포는 17.1 buildgate 재fit으로.
- 번들은 메시지로 보낼 수 있다: base64 -w76, 조각별 md5, 보내기 전 본문을 파일로 다시 써서 cmp (memory reference-bundle-by-message).
