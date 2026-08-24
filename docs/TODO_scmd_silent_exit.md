# TODO — SCMD `SC.COM`이 메시지 없이 DOS로 복귀 (진행 중, 2026-08-25)

MFRSD 플래시에 `SCMD110A.DSK`를 구워 부팅하면 DOS까지는 들어가는데, `sc`를 실행하면
**아무 메시지도 없이** 프롬프트로 돌아온다. openMSX는 같은 구성에서
`"SCC cartridge is not mounted."`를 정상 출력한다. **그 메시지가 안 나오는 것**이
이 문서의 대상이다.

> 이 건은 플래시 결함(`36098b6`)과 **무관**하다. 플래시 쓰기는 실기 90/90으로
> 검증 완료됐고, 그 수정 전후로 이 증상은 동일했다.

## 확정된 것

| | 근거 |
|---|---|
| `SC.COM`은 무죄 | 431바이트 전수 디스어셈블. 종료 경로가 셋뿐이고 **전부 메시지를 출력**한다(MSX1 안내 / `System error:File not found.` / 파나소닉이면 `Z-80 Speed x1.5`). 무음이면 완주하고 `0x0205: JP 0x0300`으로 넘어간 것 |
| `0x4060`의 검출 실패 경로도 아님 | 그 경로는 `"SCC cartridge is not mounted."`를 출력한다 |
| 사망 창 = `0x4000`~`0x4057` | `0x4057`은 `0x0336: CALL 0x4000`이 부르는 루틴 **안**이다 |
| 그 안에서 **첫 `CALL 0xC000`** | 마커 실측(중간빨강). `0xC000`은 전 슬롯/서브슬롯을 순회하며 `0x4018`의 `"APRLOPLL"`을 찾는 루프 |
| 첫 페이징은 통과하고 비교까지 도달 | 마커 실측(중간초록) |
| **MFRSD 단독으로는 openMSX도 SCMD를 못 돌린다** | 사용자가 openMSX에 SCC+ 확장을 **직접 꽂아** 뒀던 것이 초기 오판의 원인. 확장을 빼면 openMSX도 `"not mounted"` |

`docs/mfrsd_scc_sound_cartridge_20260823.md`의 "MFRSD는 SCC+ 사운드 카트리지가 될 수
없다"는 결론은 **유효하다.** 이 세션에서 한때 그것을 뒤집었다고 판단했으나, 근거가
오염된 대조군이었다.

## 관련 코드 (전부 디스어셈블 확인)

```
SC.COM  0x0205  JP 0x0300                     ; CORE2.SYS로 인계

CORE2.SYS
  0x0336  CALL 0x4000                         ; 첫 호출
  0x4013  LD HL,0xC1A3 ... CALL 0xC000        ; "APRLOPLL" 탐색  ← 여기서 죽는다
  0x4028  LD HL,0xC19B ... CALL 0xC000        ; "PAC2OPLL" 탐색
  0x4040  LD HL,0x7FF6 / CALL 0x000C          ; RDSLT  — FM-PAC OPLL enable 레지스터
  0x404A  LD HL,0x7FF6 / CALL 0x0014          ; WRSLT
  0x4057  CALL 0xC06E                         ; SCC+ 스캔
  0x4060  "SCC cartridge is not mounted." 출력 후 JP 0x0000

CORE2.SY2
  0xC000  DI / 슬롯 상태 저장 / primary 3→0 × subslot 3→0 순회
  0xC01A    CALL 0x0302                       ; 후보 슬롯을 페이지에 꽂음
  0xC020    CALL 0xC054                       ; 8바이트 비교
  0xC19B  'PAC2OPLL'   0xC1A3  'APRLOPLL'

CORE2.SYS 0x0302 = 페이지3을 후보 슬롯으로 잠깐 바꾸고 0xFFFF에 쓰는 헬퍼.
  그 구간에 스택 접근이 하나도 없게 정교하게 짜여 있다(DI 상태 전제).
```

즉 이 루틴들은 **OPLL을 찾아서 켜는** 코드다. 우리 코어는 Sony HB-F1XV(MSX2+, 내장
MSX-Music = IKAOPLL) 구성이라 `"APRLOPLL"`이 있어야 정상인데, **그것을 찾는 슬롯
순회에서 죽는다.**

## 다음 한 수 — 계측 디스크가 준비돼 있다

`tools/scmd_mfrsd/mark_core2.py`가 `SC.COM`/`CORE2.SYS`/`CORE2.SY2`에 마커 13개를
심는다. 산출물은 **`p6\SCMDTRC.DSK`** (md5 `ce5df6af0c1326a37e49656ed7079618`,
로컬 `tools/scmd_mfrsd/SCMD110A_TRACE.DSK`).

```
opfxsd SCMDTRC.DSK /d1  →  재시작  →  call system  →  sc  →  화면 맨 윗줄
```

읽는 법:

```
0  SC.COM이 JP 0x0300 직전       1  CORE2.SYS:0x0336
a  0x4013   b  0x401B(CALL 0xC000 #1)   c  0x4028(#2)
d  0x4040(RDSLT 직전)   e  0x404A(WRSLT 직전)
f  0x4052   g  0x4057(SCC+ 스캔 호출)
E  0xC000 진입
숫자  0xC013 = primary / 0xC01A = subslot (0-3)
.  0xC020 = 페이징 통과, 비교 직전
```

끊긴 자리가 죽은 자리. 숫자 뒤에 `.`이 없으면 `CALL 0x0302`(페이징)에서, `.` 뒤에
아무것도 없으면 비교(`0xC054`)에서 죽은 것이다.

**openMSX 기준선(같은 디스크로 실측)**: `01abE33.fg` + `"SCC cartridge is not mounted."`
— 슬롯 3-3에서 매치하고 루프를 빠져나온다.

## 계측 설계에서 배운 것 (반복하지 말 것)

1. **테두리 색은 값이 하나만 남는다.** 라운드당 비용(빌드→peer 배치→재플래시→재부팅
   →실행→픽셀 측정)이 큰데 산출이 1비트라 트레이드가 거꾸로다. 마커 개수는 거의
   공짜다 — 한 번에 많이 심어라. 이 세션은 그 판단을 늦게 바꿔 4라운드를 썼다.
2. **MSX 색 0은 투명**이라 손 안 댄 검정과 구분되지 않는다. 인코딩에 절대 쓰지 말 것.
3. **마커 두 개를 서로 다른 루프 깊이에 두면** 안쪽이 바깥쪽을 항상 덮어써서 판별이
   무너진다.
4. **`NAMBAS`(0xF3B3)는 MSX-DOS 아래서 0으로 방치된다.** 실제 이름 테이블은 R#2가
   가리킨다 — BIOS 섀도우 **`RG2SAV`(0xF3E1)** 를 읽어 `(v & 0x0F) << 10`으로 계산할 것.
   이걸 몰라 첫 VRAM 시도가 패턴 영역에 쓰고 있었다.
5. **R#14**(VRAM 주소 상위 비트)를 0으로 강제할 것.
6. 마커가 `LD (nn),A` 같은 저장 명령을 대체할 때 **그 변수를 읽으면 스테일한 값**이
   나온다(저장은 마커 뒤에 실행된다). 레지스터에서 읽어라.
7. 바이트 삽입은 불가. 3바이트 명령을 `CALL 트램폴린`으로 덮고 트램폴린에서 원래
   명령을 재실행한다. `CORE2.SYS`는 **파일 오프셋 + 0x300 = 실행 주소**.
8. **로더 상한 4352에 닿아가고 있다** — 현재 `CORE2.SY2` 4,333B, 여유 19B. 더 붙이려면
   스텁을 압축해야 한다. 그리고 **초과하면 잘리는지 로드가 실패하는지 미확인**이다.
   상한에 닿은 판이 이상하게 동작하면 그 지점부터 의심할 것.
9. 스텁은 반드시 `CORE2.SY2`(0xC000, 페이지3)에 둔다. `CORE2.SYS`는 페이지 1·2에
   걸쳐 있고 스캔 중 그 페이지가 후보 슬롯으로 덮인다. 여유는 214바이트
   (`SC.COM`이 4352까지 읽는데 파일이 4138).

## 유력 가설 (미검증)

우리 코어가 어떤 슬롯을 확장으로 잘못 보고하거나 페이지3 거동이 달라
`CALL 0x0302`가 폭주한다. `cart_slot_expander_en`(`memory_upload.sv`)과 머신팩
XML의 슬롯 구성을 openMSX `Sony_HB-F1XV.xml`과 대조할 것 —
openMSX는 primary 1·2가 `external="true"`(비확장), primary 0·3이 확장이다.

## openMSX 대조 하네스 (재사용 가능)

```
격리 홈:  <scratchpad>/omsx   (~/.openMSX/share 를 심링크, extensions/systemroms만 덮어씀)
확장:     MFRSD_official.xml  (공식 펌웨어 sha1 1621f623… — releases/CreateMSXpack/ROM/mfrsd.rom)
머신:     Sony_HB-F1XV
SD:       media/sd1.img  (MBR + FAT16, mtools로 생성)
제어:     ctl.tcl 이 cmd.txt 를 폴링해 Tcl 실행, 결과는 out.txt
플래시:   persistent/MFRSD_official/untitled1/megaflashromsccplussd.sram
          DSK 슬롯1 = 오프셋 0x18000 (720KB). 여기에 직접 덮어쓰면 OPFXSD 없이 교체 가능
```

⚠ **`pkill openmsx` 금지.** 다른 세션도 openMSX를 띄운다. 자기 PID만 kill 할 것.

## 별건으로 남은 것

- **MG2 재시작 루프** — 플래시 쓰기는 무손실 확인됨(전 블록 스윕 유실 0). 원인은 부팅
  구성 쪽. 첫 실험은 `/X` 옵션 유무.
- **`flash.sv`에 리셋 포트 미연결** — `msx_slots.sv:7`의 `reset`이 인스턴스에 안 붙어
  있다. OPFXSD가 굽고 곧바로 소프트 리셋하는 워크플로라 실재 위험.
- `docs/TODO_scc_divergences.md`의 D1/D4/D5 — 이 건과 별개로 유효.
