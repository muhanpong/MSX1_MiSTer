# 2 디스크 드라이브 — **영구 보류** (사용자 결정 2026-09-04)

구현하지 않는다. 아래는 왜 큰 작업인지에 대한 기록이며, 재검토 요청이 없는 한 착수하지 않는다.

## 막고 있는 것 셋

**① `fdc.sv`가 드라이브 0만 인정**
```systemverilog
fdc.sv:13   input  img_mounted,                                    // 1비트
fdc.sv:61   wire fdd_ready = image_mounted & driveReg[7] & ~driveReg[0];
```
`driveReg[0]`이 드라이브 선택 비트인데 그것을 not-ready 조건으로 쓴다 = "1번 드라이브는 없다"를 하드코딩.

**② VD 슬롯이 만석**
```
VD0-3  nvram_backup(.sav)   VD4  SD 카드   VD5  DSK 드라이브 A
```
`VDNUM = 6`. 드라이브 B는 7 필요.

**③ ★ 디스크 ROM이 드라이브 수를 정한다**
MSX에서 DOS가 보는 드라이브 개수는 **디스크 ROM이 보고**한다. 현재 쓰는
`hb-f1xd_disk.rom`은 단일 드라이브 기종(HB-F1XD) 것이라, 하드웨어를 둘 만들어도
DOS는 A: 하나만 보고 B:는 디스크 교체를 요구하는 유령 드라이브가 된다.

2드라이브 기종 ROM은 보유 중:
`sony/hb-f700p_disk.rom`, `national/fs-5500_disk.rom`.
다만 **WD2793 호환 여부 미확인** — 아니면 FS-A1F의 TC8566AF와 같은 벽이다.

## 다시 하게 된다면 첫 단계

`hb-f700p_disk.rom`을 지금 `hb-f1xd_disk.rom` 자리에 넣어 **단일 드라이브로 DOS까지 가는지**
먼저 확인한다. 팩 XML 한 줄이고 코어 빌드가 필요 없다. 그게 되면 나머지는 배선 작업이고,
안 되면 ROM부터 구해야 한다.

관련: [[project_fdc_wd2793_only]]
