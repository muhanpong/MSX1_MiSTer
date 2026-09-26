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

## 무엇이 아직 없나

`.sav` 경로는 `tb_msx.sv` 안에 저장 엔진과 SD 모델로 들어와 있다. 플로피(WD2793)를
통한 디스크 접근은 아직 없다. 분기 스트림을 openMSX 와 대조하는 비교기도 없다
(`docs/handoff_20260926.md` 참조).
