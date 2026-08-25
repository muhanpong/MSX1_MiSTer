# mkmsxdsk — 720KB MSX 부팅 디스크 빌더

`.BAS` / `.COM` 같은 소품 파일을 MSX로 넘길 때, VHD를 마운트하지 않고
OSD에서 디스크만 갈아끼워 쓸 수 있도록 부팅 가능한 720KB DSK를 만든다.

```
python3 tools/mkdsk/mkmsxdsk.py OUT.DSK [옵션] FILE...
  --label NAME       볼륨 라벨 (8.3, 최대 11자)
  --autoexec "A;B"   AUTOEXEC.BAT 생성 (';' = 줄 구분)
  --dos1-only        MSXDOS2/NEXTOR/COMMAND2 생략
  --dos2-only        MSXDOS.SYS/COMMAND.COM 생략
  --no-sys           시스템 파일 없음 (데이터 전용, 부팅 불가)
```

## 사양

- 720KB 2DD (80트랙 × 2헤드 × 9섹터), FAT12, 1KB 클러스터, 루트 112 엔트리
- 시스템 파일 포함 시 가용 **약 670KB**, 파일 최대 **105개**
- 파일명은 8.3 대문자만 (위반 시 에러로 중단)
- `MSXDOS.SYS`는 항상 클러스터 2부터 연속 배치 — 디스크롬 부트로더가 이를 가정

## 시스템 파일 (`sys/`)

`YAMARD.DSK`(이 프로젝트에서 실사용된 Nextor 부팅 디스크)에서 가져온 조합.
`MSXDOS.SYS`는 DOS1판(2432B, MSX-DOS 1.05)이 아니라 **DOS2 계열 로더**(같은 크기,
다른 내용)여야 DOS2로 넘어간다. 이 함정 때문에 첫 시도가 DOS 1.05로 떨어졌다.

| 파일 | 크기 | 역할 |
|---|---|---|
| MSXDOS.SYS  | 2432 | DOS2 계열 로더 (DOS1 커널에선 MSX-DOS 1.8로 동작) |
| COMMAND.COM | 7168 | DOS1 모드 셸 (COMMAND 1.12) |
| NEXTOR.SYS  | 4467 | Nextor 커널용 (MFRSD 등) |
| MSXDOS2.SYS | 2286 | MSX-DOS 2.40 |
| COMMAND2.COM| 23935| MSX-DOS 2 셸 2.44 |
| boot720.bin | 512  | YAMARD.DSK 부트섹터 |

## 검증 (openMSX, 20260823)

| 환경 | 결과 |
|---|---|
| Panasonic FS-A1WSX (내장 DOS1 디스크롬) | MSX-DOS **1.8** / COMMAND 1.12, DIR 정상 |
| Panasonic FS-A1GT (turboR, DOS2 내장)   | MSX-DOS kernel **2.31** / MSXDOS2.SYS 2.40 / COMMAND2 2.44, `A:\>` 프롬프트 |
| mtools `mdir`/`minfo` (독립 FAT 파서)    | 구조·파일 목록 정상 |
| 자체 추출기 라운드트립                    | 전 파일 md5 일치 |

※ openMSX의 `-ext msxdos2` 카트리지는 내장 디스크롬을 가진 기기에서 무시된다
(YAMARD.DSK도 동일). DOS2 검증은 DOS2 커널 내장 기기로 해야 한다.
