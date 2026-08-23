# SCMD / MFRSD 조사 도구

`docs/mfrsd_scc_sound_cartridge_20260823.md`의 근거를 재현하기 위한 도구들이다.

## 파일

| 파일 | 용도 |
|---|---|
| `z80dis.py` | Z80 역어셈블러. `z80dis.py <파일> <베이스> [시작오프셋] [끝오프셋]` |
| `mrc_parse.py` | 긁어온 msx.org 스레드 HTML → `posts.json` |
| `mrc_find.py` | `posts.json` 정규식 검색 (작성자 필터, 문맥 창 병합) |

## 원자료는 저장소에 없다

SCMD 바이너리(`SC.COM`, `CORE2.SYS`, `CORE2.SY2`, `SCMD110A.DSK`)와 MFRSD 펌웨어는
**상용 소프트웨어**이고, 긁어온 포럼 글은 **msx.org / 각 작성자의 저작물**이다.
따라서 저장소에 커밋하지 않는다.

로컬 아카이브 위치:

```
~/msx_archive/mfrsd_scmd_20260823/
├── thread/       # HTML 108쪽 + posts.json (1,069글)
├── binaries/     # SC.COM, CORE2.SYS, CORE2.SY2, CORER/CORET.SYS, SCMD110A.DSK
└── z80dis.py
```

경로는 `MRC_DIR` 환경변수로 바꿀 수 있다.

## 재현

```bash
A=~/msx_archive/mfrsd_scmd_20260823

# 문서 §4 — 검출 루틴 (CORE2.SY2 는 0xC000 에 로드된다)
./z80dis.py $A/binaries/CORE2.SY2 0xC000 0x134 0x19B

# 문서 §3 — 슬롯 선택 루틴 (CORE2.SYS 는 0x0300 에 로드된다)
./z80dis.py $A/binaries/CORE2.SYS 0x300 0x02 0x50

# 문서 §5 — 플레이어 init / 곡 적재
./z80dis.py $A/binaries/CORE2.SYS 0x300 0x4750 0x4830
./z80dis.py $A/binaries/CORE2.SY2 0xC000 0x400 0x460

# 문서 §7 — Pazos 발언 검색 (핸들 guillian)
./mrc_find.py "64 ?K.{0,30}RAM" guillian 330
./mrc_find.py "sound cartridge|SCC-I" "" 330
```

스레드를 다시 긁어야 한다면 `mrc_parse.py`의 docstring에 curl 루프가 있다.
msx.org는 기본 user-agent에 403을 준다.
