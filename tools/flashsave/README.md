# flashsave — 플래시 카트 세이브를 openMSX ↔ MiSTer 로 옮기기

ASCII16X / Yamanooto 카트의 세이브는 두 곳에서 **전혀 다른 모양**으로 저장된다.

| | 무엇 | 크기 |
|---|---|---|
| MiSTer 코어 `.sav` | 8 MB 플래시에 대한 **희소 패치** — 헤더 + 바뀐 64 KB 블록만 | 512 + n×64 KB |
| openMSX `.SRAM` | 플래시 **칩 전체** (`AmdFlash`) | 정확히 8 MB |
| 원본 `.ROM` | 사용자가 올린 미변경 이미지 | ≤ 8 MB |

기준점은 코어가 카트를 올리는 방식이다: **오프셋 0에 ROM, 그 뒤는 끝까지 `0xFF`**
(`memory_upload.sv` 의 `x16_pad`, `pattern 3'd1`). 이것과 다른 블록이 곧 세이브다.

## 쓰는 법

```bash
# openMSX -> MiSTer
./flashsave.py extract --rom GOLVE2_KR.ROM \
    --image ~/.openMSX/persistent/roms/GOLVE2_KR.ROM/GOLVE2_KR.ROM.SRAM \
    -o GOLVE2_KR.sav
scp GOLVE2_KR.sav root@<board>:/media/fat/saves/MSX1/

# MiSTer -> openMSX
./flashsave.py apply --rom GOLVE2_KR.ROM --sav GOLVE2_KR.sav -o GOLVE2_KR.ROM.SRAM

# 들여다보기
./flashsave.py info --sav GOLVE2_KR.sav
```

`.sav` 파일명은 **코어에 로드하는 ROM 이름에서 확장자만 뗀 것과 정확히 같아야** 한다.
펌웨어가 그 이름의 동반 파일을 VD0 에 마운트하고 코어가 부팅 때 읽는다
(`user_io.cpp:2937` 의 하드코딩된 드라이브 인덱스 0).

## `.sav` 형식 (`rtl/flash_dirtysave.sv`)

```
sector 0 (512B)  0..7    매직
                 8       모드, 0x02 = dirty-block
                 16..31  128비트 dirty 비트맵, LSB first, bit i = 블록 i
sector 1..       dirty 64KB 블록들, 블록 번호 오름차순, 각 128섹터
파일 크기 == 512 + popcount(비트맵) × 65536
```

> ⚠️ **디스크상 매직은 `BDX61XFM` 이다.**
> RTL 상수는 `64'h4D_46_58_31_36_58_44_42`(= `"MFX16XDB"`)인데 기록부가
> `MAGIC[8*i +: 8]` 로 내보내므로 **리틀엔디언 = 역순**으로 깔린다. 소스 주석의
> `MAGIC("MFX16XDB")` 는 상수 얘기지 파일 얘기가 아니다. 코어가 실기에서 쓴
> 세이브로 확인했다 (`Final Fantasy (KR).sav`, 블록 13).

## 코어와의 미세한 차이

여기서는 padded ROM 과 **다르기만 하면** dirty 로 잡는다. 코어는 게임이 실제로
바이트를 **프로그램한** 블록만 표시하므로, 지우기만 하고 쓰지 않은 블록은 코어가
놓치고 이 도구는 잡는다. 복원이 그 블록을 그대로 다시 쓰는 것뿐이라 무해하고,
오히려 더 안전한 쪽이다.

## 검증

```bash
node verify.js     # 실제 GOLVE2 파일 + 보드에서 가져온 실기 세이브 헤더로 10개 검사
```

`verify.js` 는 웹앱(`flashsave.html`)의 변환 코어를 그대로 떼어내 돌린다.
`flashsave.py` 와 웹앱은 **바이트 단위로 같은 결과**를 내야 하며, 검사에는
역변환이 원본 openMSX 이미지를 정확히 복원하는지와 네거티브 컨트롤 4종이 포함된다.
(경로가 하드코딩돼 있으므로 다른 게임으로 돌리려면 상단 두 줄을 고칠 것.)

## 웹앱

같은 변환을 브라우저에서: **MSX 플래시 세이브 브리지**
<https://claude.ai/code/artifact/9ec5e0d4-3122-465c-aa64-4875ec50f233>

`flashsave.html` 이 그 소스다. 고칠 때는 이 파일을 고친 뒤 **같은 URL 로 다시 게시**한다
— 다른 대화에서 게시할 때는 반드시 `url` 파라미터에 위 주소를 넘겨야 하고,
빠뜨리면 같은 이름의 **별도 아티팩트**가 새로 생긴다 (실제로 한 번 그렇게 중복됐다).

브라우저 저장은 허용 확장자가 정해져 있어 `.sav` 를 직접 못 준다. 파일이
`.sav.txt` 로 내려오므로 `.txt` 만 떼면 된다. 내용은 이미 정확하다.
