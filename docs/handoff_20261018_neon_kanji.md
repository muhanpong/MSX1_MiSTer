# 인수인계 2026-10-18: Neon Horizon, 한자 D9h, 스트로브 경쟁 점검

브랜치 `sdram128-study`(worktree `~/data/MiSTer_build/sdram128`), nextz80(03f7653) 위, **push 안 함**.
128.86 MHz 단일 구조(사용자 결정). 앞 문서: `handoff_20261014_neon.md`, `handoff_20261013b_tdm_boot.md`.
이 세션(msx1-handoff)의 작업은 사용자 지시로 **core_builder 세션(다른 기계, muhanpong)이 넘겨받았다**.
그쪽 규칙: nextz80은 건드리지 않음, 빌드·push는 사용자 결정, 결과는 core_builder 앞으로.

## 0. 지금 상태 한눈에

| 항목 | 상태 | 다음 |
|---|---|---|
| 한자 D9h 0-8/4096 (실기, ae02602) | **원인 판정 + 수정(B) 커밋 7b27baf**, 시뮬 PASS. 빌드·실기 안 함 | B 반영 빌드 후 실기 KPROBE 4096/4096 (사용자 결정) |
| Neon Horizon 그림 깨짐 (실기, 128 MB 보드) | 미해결. SDRAM 카트 읽기·VDP RTL·.sav 경로 배제 | 한자 B 빌드에서 함께 확인; 남으면 계측 빌드(VDP 입력 CRC) |
| 스트로브 경쟁 점검 P1-P4 (core_builder 의뢰) | **진행 중**: 지연 주입 20판(3d9250c 하네스) | 결과를 core_builder에, 실패 항목은 수정안 제안만 |
| L1(opl4latch -end 6), L2(NextZ80 2클록) | 미착수(낮은 우선순위) | 시간 되면 |
| buildgate `strobe_race.tcl` | 만들었으나 판별력 없음 → 게이트로 안 씀 | 기능 조건을 보는 방식이 필요 |

## 1. 한자 D9h (확정에 가까움)

- 증상: 1014b(ae02602)에서 D9h 4096회 중 0-8회만 맞음, Z80 정상 속도에서도. 1008a(85.9 MHz)는 4096.
- 기구: 한자 읽기는 **IORQ_n 하나가 SDRAM 요청(`device_kanji_ram_ce`→`sdram_ce`)과 주소 선택
  (`msx_slots` `ram_addr = device_kanji_ram_ce ? kanji : memory`)을 동시에** 바꾼다. 두 컨트롤러 모두
  요청을 처음 본 clk_sdram 에지에 `ch2_addr`를 잡는다. `MSX1.sdc`의 CPU→`*sdram*ch2_*` 6클록 예외가
  STA를 가린다. STA(ae02602 DB, 느린 코너): IORQ_n→요청 9.41 ns, →주소 14.07 ns.
- 시뮬(`tb_msx.sv -DKPROBE`, GT DOS2, 각 4096): 지연 0이면 둘 다 PASS. **주소 선택만 clk_sdram 1클록
  늦추면(-DKDLY)** 기존·tdm128 모두 85/48/85 FAIL(직전 메모리 주소의 코드 바이트), **B를 넣으면 4096 x3**.
  음성대조 KMUT 1/0/920 FAIL. run_turbo ALL PASS, sdram_tdm quick PASS.
- 수정 B(7b27baf): `kanji.sv` `ram_req = ram_ce & ram_ce_q`(요청 상승만 clk21m 1클록 늦춤, 하강 즉시),
  `msx_slots.sv` `sdram_ce`가 `ram_req` 사용, 선택·카운터는 `ram_ce`. `MSX1.sdc` 주석 정정.
- 철회한 것: 첫 KDLY 결과(85/48/85, "B+KDLY도 FAIL") — `msx_slots`의 `clk_sdram`이 미연결(0)이라 선택이
  영구히 꺼진 상태였다. `tb.clk_sdram`으로 다시 걸어 위 결과.

## 2. Neon Horizon (미해결)

배제됨(근거):
- 실기 NHTEST v3(`tools/nhtest`, .sav 없이): 카트 8 MB 읽기(Neon과 같은 OUTI 18T 포함), 바이트 쓰기 DQM,
  VRAM 128 KB, 매퍼 RAM 512 KB, 플래시 쓰기 모두 정상.
- .sav: 치워도 깨짐(블록 00 차이는 게임의 8 KB 세이브 섹터, savdiff.py 정정 fa62d31).
- fullsys 128 MB 맵(-DTDM128) 대 sdram.sv: C-BIOS Neon 9 s까지 VDP/MoonSound I/O 동일(8.03 s 사이클 동일).
- VDP RTL: openMSX(FS-A1FX) Neon VDP I/O 25 s를 VDP RTL에 재생(91ac10b, `sim/run_vdp_replay.sh`),
  49구간 중 46 일치, 나머지는 명령 속도/진행 중 명령. 음성대조 1바이트 검출.
남은 가설: 실기에서 VDP로 들어가는 입력(값 또는 타이밍)이 다르다. 한자와 같은 종류(스트로브가 바꾸는
필드를 첫 에지에 잡음)가 Neon 경로에도 있는지가 P1-P4 점검의 목적이다. 실기에서 아직 안 한 패턴:
8000h 창 뱅크 전환 직후 읽기(게임 그리기 엔진, NHTEST5 T9 — 만들었고 openMSX 검증, 실기 미실행).

## 3. 스트로브 경쟁 점검 (진행 중, core_builder 2026-10-17 의뢰)

- 하네스(3d9250c): `tb_msx.sv -DINJ_RNW/_DIN/_ADDR/_UNMAP` + `-DRPROBE` + `+zspeed`. 주입 = clk21m 상승 직후
  첫 clk_sdram 주기에 컨트롤러가 그 신호를 직전 값으로 봄. ADDR이 음성대조(PASS여야 함).
- 대상: sdram128-study 7b27baf(tdm128)와 nextz80 3f09aaf(sdram.sv; **별도 worktree
  `~/data/MiSTer_build/nz_3f09aaf`, detached, 하네스 파일만 복사해 미커밋** — tb_msx.sv에
  `logic sdram_busy;` 추가, run_preload.sh가 sdram_tdm_sim.sv 없으면 건너뜀).
- 실행 중이던 20판(각 주입 5종 x zspeed 0/3): 출력은 세션 스크래치 `.../scratchpad/rp128/`,
  `.../scratchpad/rpnz/` (`RPROBE p1 ...`, `RPROBE RESULT`, `INJ_*:` 줄). 다시 돌리는 명령은 6절.
- 무효 조건(사전): 주입 없음이 PASS가 아니거나 ADDR이 FAIL이면 하네스 무효.
- 미추적 관찰: RPROBE가 FFFF에 0Fh(슬롯 3의 페이지 0/1 보조 슬롯)를 쓰면 다음 페이지 0(슬롯 0-0) 인출에서
  RST 38로 빠짐. msx_slots의 FFFF 디코드(`active_slot`)는 소스상 정상. 실기 확인 안 함 — 별도 조사 거리.
- P3/P4는 `mem_unmaped` 하나로 주입(그 안에 mapper_rd/wr, SCC·MFRSD·FM-PAC 레지스터 디코드가 있음).
  B2(konami_scc SCC2 게이트), P4의 rdtog/hs_done 조기 카운트 계측은 아직 없음.

## 4. 이 세션 커밋 (sdram128-study, 9e49224 이후)

| 커밋 | 내용 |
|---|---|
| bedb8bf | fullsys -DTDM128, +iolog 자체검증, cmp_io.sh |
| b122893 | cmp_io.sh 반쯤 쓰인 마지막 줄 |
| 84d22e1 a1bdef1 fa62d31 80e7d6a a838f93 223690d 34067dd c6eacef | tools/nhtest v1-v5, savdiff.py |
| 91ac10b | VDP 재생 벤치와 결과 |
| 9483d23 | fullsys KPROBE, STA kanji_race*.tcl, 증거 |
| 7b27baf | **한자 수정 B**, strobe_race.tcl, 증거 |
| 3d9250c | INJ_* 지연 주입, RPROBE, +zspeed |
| 66450b2 | 스킬 갱신(fullsys-measure, openmsx-oracle) |

번들(사용자가 core_builder로 전송): `~/data/MiSTer_build/bundles_20261017/`
`sdram128-study_7b27baf.bundle`(md5 b8fd427b…, prerequisite 03f7653), README 브랜치 번들·패치.
7b27baf 이후 커밋(3d9250c, 66450b2, 이 문서)은 아직 번들에 없음.

## 5. 증거·생성물 위치

- `docs/evidence_20261017/`: KPROBE/KDLY/B/KMUT 로그 요약, STA(kanji_race*, strobe_race) 결과.
- `~/data/MiSTer_build/sdram128_evidence_20261017/`(git 밖, 41 MB): openMSX VDP 녹화, fullsys Neon 9 s,
  NHTEST 디스크, Neon ROM(사용자 것), fw.bin.
- rbf(.gitignore): `output_files/MSX1_20261014b_sdram128_ae02602.rbf`(md5 e3decc31…), `..._14a_..._7cd1475.rbf`.
- 보드(mister-super-expert가 관리): NHTEST.ROM, nhtest.dsk(v3), `.sav.bak_*` 두 개.

## 6. 명령

```
cd ~/data/MiSTer_build/sdram128; export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
PX="$HOME/data/MiSTer_build/MSX1_MiSTer/tools/CreateMSXpack/MSX/Panasonic/Panasonic FS-A1GT DOS2.MSX"
# 한자
XDEFS="-DKPROBE [-DKDLY] [-DKNOB] [-DKMUT]" EXTRA="+kprobe=$PWD/sim/fullsys/kprobe/kprobe.hex [+kwave=3]" \
  OUT=/tmp/x sim/fullsys/run_preload.sh <old|tdm128> "$PX" 300
# 스트로브 점검 (nextz80는 같은 명령을 ~/data/MiSTer_build/nz_3f09aaf 에서 old 로)
XDEFS="-DRPROBE [-DINJ_RNW|-DINJ_DIN|-DINJ_ADDR|-DINJ_UNMAP]" EXTRA="+kprobe=$PWD/sim/fullsys/rprobe/rprobe.hex +zspeed=<0|3>" \
  OUT=/tmp/y sim/fullsys/run_preload.sh tdm128 "$PX" 1500
# VDP 재생 (구간 k, 녹화 디렉터리)
START=k UPTO=k+1 OUT=/tmp/w sim/run_vdp_replay.sh ~/data/MiSTer_build/sdram128_evidence_20261017/vdp_recording
# STA (빌드 아님, 끝나면 git checkout -- MSX1.qsf)
quartus_sta -t tools/sdram128/kanji_race3.tcl out.txt ; quartus_sta -t tools/buildgate/strobe_race.tcl out.txt
```

## 7. 주의 (이번에 배운 것)

- 시뮬 전용 플롭을 `msx_slots` 안에 걸 때 그 모듈의 `clk_sdram`은 0이다(msx.sv 미연결) — `tb.clk_sdram`.
- 실행 중인 스크립트를 고치지 말 것: `run_vdp_replay.sh`를 고치는 사이 돌던 판이 비교 단계에서 문법 오류.
- `quartus_sta -t` 의 `project_open`도 `MSX1.qsf`를 건드린다 → 매번 `git checkout -- MSX1.qsf`.
- STA 최소/최대 비교는 "경로가 있다"와 "그 사이클에 값이 바뀐다"를 구분 못 한다(strobe_race 전부 FAIL).
- 실기 시험은 비용이 크다: 결론을 가를 때만, openMSX에서 양성·음성 대조 통과 후에(memory
  feedback_hardware_tests_are_expensive). 보드 파일 조작은 mister-super-expert 세션이 한다.
- mister-super-expert에 긴 base64를 메시지로 보내면 손상된다 — 파일은 사용자에게 보내 전달받게.
