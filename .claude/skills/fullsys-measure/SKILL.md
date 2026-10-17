---
name: fullsys-measure
description: Get a number out of the whole-machine bench (sim/fullsys) instead of guessing — boot a real pack, optionally a .sav, and read a count back. Use when a question is about the machine as a whole rather than one RTL leaf: does the CPU touch X while Y is happening, does a pack allocate what its header says, does the firmware reach this code at all.
---

# fullsys 로 숫자를 재기

블록 벤치 25개는 잎사귀 한두 개만 컴파일한다. "기계 전체가 이럴 때 저렇게 되나" 는
답할 수 없다. `sim/fullsys` 는 `rtl/msx.sv` 를 통째로 돌리고, 실제 `.MSX` 팩과
`.sav` 를 먹인다. **추측을 숫자로 바꾸는 자리다.**

## 순서

    sim/fullsys/prep.sh                                  # RTL 바뀐 뒤 한 번
    SAV=<file> sim/fullsys/run.sh <pack.MSX> [ms]

환경변수: `SAV` 는 VD0 에 올릴 이미지, `SAVLATE=1` 은 업로드 **뒤** 마운트(자동 로딩을
잃는 순서), `SDSLOW=<cycles>` 는 섹터 간 간격, `OUT=<dir>` 은 빌드 디렉터리.
`OUT` 을 나누면 여러 판을 동시에 돌릴 수 있고, 이 머신은 그걸 잘한다.

## 한 판의 값

업로드만 기계 시간 350 ms 근처이고 벽시계로 **40분 이상** 걸린다. 팩이 클수록 길다.
그러니 한 번에 한 질문만 넣고, 계측을 미리 다 붙여서 재실행을 줄인다.

## 먼저 밟은 함정

- **출력은 블록 버퍼링이다.** 파일로 리다이렉트하면 끝날 때까지 아무것도 안 보인다.
  조용한 것을 멈춤으로 오해하지 말고 `ps -o time=` 로 CPU 를 보라.
- **도는 중에 `run.sh` 를 고치지 마라.** bash 가 실행 도중 파일을 다시 읽어 마지막에
  문법 오류를 낸다. 결과는 이미 찍혔어도 놀란다.
- **계측이 스스로를 증명해야 한다.** "창 안의 쓰기 0" 은 기계가 아무것도 안 했을 때도
  0 이다. 반드시 총량도 함께 찍어라. 총량이 0 이면 그 측정은 무효다.
- **`pack:` 줄의 바이트 수를 파일 크기와 대조하라.** 팩이 `PACKSZ` 보다 크면 로더가
  말없이 끊는다. 딱 `2097152` 같은 2의 거듭제곱이 나오면 그게 증거다. 잘린 뒤쪽에는
  DEVICE 레코드와 KBD_LAYOUT, CONFIG 가 들어 있어서, RESET_STATUS 가 사라지면 포트 F4
  가 FF 를 돌려주고 BIOS 가 RAM 매핑 전에 CPU 전환 분기로 빠져 RST 38 루프에 갇힌다.
  그 상태로 잰 CPU 측 숫자는 전부 무의미하다. 400 ms 에 고유 PC 가 여덟 개면 그 모양이다.
- **조용한 실패를 의심하라.** 팩 헤더의 매직이 어긋나면 `memory_upload` 가 아무 말 없이
  IDLE 로 떨어지고, 슬롯 배치 64칸이 빈 채로 기계가 FF 를 읽으며 달린다. 그러니
  `slot_layout` 이 몇 칸 찼는지부터 찍어라. 0 이면 그 실행의 다른 숫자는 전부 무의미하다.
- **DDR3 모델의 계약.** `ddram.sv` 의 `dout` 은 레지스터다. 읽기와 함께 붙잡힌 주소로
  채우고 다음 읽기까지 유지한다. 주소를 좇는 모델은 한 바이트 뒤를 준다.

## 계측 (2026-10-13 추가)

`tb_msx.sv` 끝에 두 줄이 찍힌다. 두 컨트롤러 모두 같은 정의다.
- `sdram demand:` 해제 후 ACTIVE 수, 채널별 요청, 가장 바쁜 1 ms / 100 us.
- `cpu read latency:` 요청 에지(`sdram_ce & ram_rnw`)부터 완료(`rdtog` 뒤집힘 또는 캐시 적중)까지,
  min/max(ns)와 50 ns 히스토그램.
  **첫 버전은 ns를 1000으로 나눠 max 0.2 ns를 찍었고 바로 못 알아챘다.** min이 한두 클록보다
  작으면 그 측정은 무효다.

## 두 런을 맞대기

`sim/fullsys/cmp_streams.sh <기준.log> <후보.log>`: 해제 후 분기 스트림이 같은지(짧은 쪽 길이
까지). 업로드 끝 시각이 달라 타임스탬프는 보지 않는다. 같은 로그끼리는 PASS여야 한다(대조군).
**SDRAM 컨트롤러를 바꾸면 이걸로 기존 컨트롤러 런과 맞대라.** sdram128 연구에서 TDM 코어는
타이밍을 통과하고 단독 벤치도 통과했지만, 이 비교에서 5번째 분기에 갈렸다.

**로그 유실 주의 (2026-10-14).** 시뮬레이터 stdout이 가끔 한 덩어리(수백 줄, ~10 ms)를 잃는다.
흔적은 한 줄에 타임스탬프 두 개("1085.7    1091.016  BR  7d60")다. cmp_streams.sh는 순번으로
맞추므로 그 뒤 전부가 어긋나 **가짜 갈림**을 낸다. 실제로 한 번 그렇게 속았다.
`sim/fullsys/cmp_time.sh <기준> <후보>`: 시각 기준 비교, 양쪽 로그의 유실 구간을 모두 빼고
PC 순서열을 맞댄다. 대조군: 같은 로그끼리 PASS, 다른 기종끼리 FAIL. BR 줄 끝의 `#n`(일련번호)이
건너뛰면 그것도 유실이다. 타이밍만 다르고 경로가 같으면 경로가 바뀌는 지점까지 PASS다.

## 큰 카트·펌웨어: 업로드 건너뛰기 (`-DPRELOAD`)

8 MB 카트 + MoonSound는 바이트 단위 업로드만 수 시간이다.
`sim/fullsys/run_preload.sh <old|tdm> <pack.MSX> <ms> [rom 매퍼번호] [fw.bin]`
(`MOONSOUND=1`로 OSD MoonSound 켬, `EXTRA="+plusarg"`): `sim/tb_upload32.sv +dump`가 SDRAM 이미지,
systemRAM 이미지, 업로더 출력(필드별 SV 대입문), 키보드 배치 쓰기를 만들고, tb_msx `-DPRELOAD`가
그걸 칩 모델에 넣은 뒤 **SDRAM 컨트롤러 초기화(200 us)를 기다렸다가** 리셋을 푼다. 초기화를 안
기다린 첫 판은 2번째 분기에서 갈렸다. 검증: GT DOS2 프리로드 vs 정상 업로드 18,236 분기 일치.
fw.bin은 `sim/run_upload32.sh`가 yrw801.rom으로 만든다(헤더 typ 8). ASCII16-X 매퍼 번호는 19.
TDM 빌드는 기존보다 느리다(MoonSound 켬, 기계 1 ms당 십수 초).

`+iolog=<file>`(tb_msx): VDP(98h-9Bh)·MoonSound(7Eh/7Fh, C4h-C7h) 출입 값 순서열.
**2026-10-14 현재 검증 안 됨**: FS-A1FX 1.17 s까지 파일이 0바이트였다(BIOS도 VDP에 쓰므로 비면 안 됨).
쓰기 전에 짧은 판으로 줄이 찍히는지부터 확인할 것.

## sdram128-study 브랜치 전용

`sim/fullsys/run_tdm.sh`: clk_sdram 128.86 MHz, clk21m = clk_sdram/6, `sdram_tdm`(32 MB 맵),
CL3/BL2 칩 모델 `sdram_big_tdm`(tb_msx.sv `-DTDM`). `prep.sh`가 `tb/mkshim_tdm.py`로
`gen/sdram_tdm_sim.sv`를 만든다. 컨트롤러 RTL을 고친 뒤에는 그 파일을 다시 만들 것
(`python3 tb/mkshim_tdm.py rtl/peripheral/sdram_tdm.sv sim/fullsys/gen/sdram_tdm_sim.sv`).

## 무엇이 아직 없나

`.sav` 경로는 `tb_msx.sv` 안에 저장 엔진과 SD 모델로 들어와 있다. 플로피(WD2793)를
통한 디스크 접근은 아직 없다. 분기 스트림을 openMSX 와 대조하는 비교기도 없다
(`docs/handoff_20260926.md` 참조).

## 128 MB 맵, 프로브, 지연 주입 (2026-10-17, sdram128-study)

- **`run_preload.sh tdm128`**: sdram_tdm을 128 MB 보드 맵(칩 2개, 2 KB 뱅크 교차, sdram_size 3)으로.
  `tdm`(32 MB 맵)은 사용자 보드(128 MB)를 검증하지 않는다. 칩 모델 `sdram_big_tdm #(M128)`은 논리 주소로
  저장하므로 프리로드·BIOS 검사가 그대로 쓴다. 대조군 `-DTDM128_MUT_MAP`.
- `XDEFS="-D..."`(대조군·프로브), `VFLAGS`(Verilator 옵션; `--threads 4`는 오히려 느렸다), `EXTRA="+..."`.
- **BIOS 패치 프로브**(`+kprobe=<hex>`, 리셋 벡터 자리에 덮음, 스택·RAM 없이 쓸 것):
  - `-DKPROBE` + `sim/fullsys/kprobe/kprobe.hex`: 한자 D9h 4096회 x {Z80 INIR, Z80 느린 IN, R800 INIR},
    읽기마다 장치 주소의 SDRAM 이미지와 비교. `+kwave=N`: 첫 N회 읽기를 clk_sdram마다 추적.
  - `-DRPROBE` + `sim/fullsys/rprobe/rprobe.hex`: 매퍼 RAM 32세그먼트, FFFF 쓰기/읽기 + 센티널,
    Z80과 R800. 단계별 오류 수는 포트 2Fh. `+zspeed=N`: Z80 터보(0 3.58 ... 3 10.74 ... 4 21.48 MHz).
  - 프로브 쓰기 전 확인: 첫 판의 KPROBE는 스택(F000h)으로 CALL했다가 리셋 직후 페이지 3이 RAM이 아니라
    81 us마다 재시작했다. **BIOS를 대신하는 프로브는 PPI 모드 워드(`OUT (0ABh),82h`)를 먼저 쓸 것** — 안 쓰면
    포트 A가 입력으로 남아(ppi_out_a=0) `OUT (A8h)`가 무효, 모든 페이지가 슬롯 0이다. 첫 RPROBE 20판은 이것
    때문에 전부(주입 없음 포함) 같은 FAIL이었고, "FFFF←0Fh → RST 38"도 같은 원인(FFFF가 슬롯 0 레지스터)이었다.
    `+rwave=N`(8000-BFFF 읽기/쓰기 + 슬롯·매퍼·ram_addr), EDGEHIST(입력이 바뀌는 clk_sdram 위상)로 확인.
- **지연 주입**(`-DINJ_RNW/_DIN/_ADDR/_UNMAP`, `-DKDLY`, `-DKMUT`, `-DKNOB`): clk21m 상승 직후 첫
  clk_sdram 주기에만 컨트롤러가 그 신호를 직전 값으로 본다 = "그 경로가 clk_sdram 하나 늦다". 그 사이엔
  clk_sdram 논리만 표본을 잡으므로 내부 넷도 `force`로 같은 효과. 각 주입은 실제로 값이 달랐던 횟수를
  찍는다(0이면 주입기가 죽은 것). **`msx.sv`는 `msx_slots`의 `clk_sdram` 포트를 연결하지 않는다(0)** —
  그 모듈 안에 시뮬 플롭을 걸려면 `tb.clk_sdram`을 쓸 것. 첫 KDLY는 이걸 몰라 선택이 영구히 꺼진 채로
  "재현"을 보고했다가 철회했다. 주입을 넣은 직후 `+kwave`로 파형이 의도대로인지 먼저 볼 것.
- 결과 비교: `cmp_io.sh`(+iolog 값 순서열), `cmp_time.sh`(분기 시각).

## VDP 단독 재생 (`sim/run_vdp_replay.sh`)

openMSX 녹화(포트 98h-9Bh, clk21m 단위 + 0.5 s마다 physical VRAM/레지스터/포인터/래치)를 VDP RTL에
재생해 VRAM을 맞댄다. 구간(0.5 s)마다 그 시점 상태로 시작, 병렬 실행(벤치는 기계 1 s에 약 1시간).
배선은 msx.sv 그대로: REQ는 **1클록 펄스**(msx.sv `iack`; 레벨로 주면 99h 한 번이 두 바이트로 처리),
VRAM은 PRAMADR(16)로 고르는 두 altsyncram, DLCLK 게이트 없음. 구간 시작에 포인터·포트99 래치·R32-45를
복원하지 않으면 가짜 차이가 난다(w25, w4에서 한 번씩 속음). `MUT=-1`(구간 마지막 98h 쓰기)이 음성 대조 —
그보다 앞선 쓰기는 다음 프레임이 덮을 수 있다. 녹화본: ~/data/MiSTer_build/sdram128_evidence_20261017/.
