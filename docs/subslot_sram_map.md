# 서브슬롯과 SRAM 배정

한 슬롯에 ROM은 왜 하나뿐인가. 조사해 보니 **메모리가 부족해서가 아니었다** — DDR3는
208 MB가 비어 있다. 막고 있는 건 다른 셋이다.

웹 버전(배치도 SVG): https://claude.ai/code/artifact/56d14f47-1995-425a-bef1-8adfb488d2a7
2026-09-04 조사.

---

## 1. 서브슬롯에 무엇을 꽂을 수 있나

`msx_config.sv:118-147`이 규칙을 구현하고 주석으로도 적어뒀다. 서브슬롯 0→3을 훑으며
**먼저 나온 것이 이기고, 뒤의 충돌하는 것은 자동으로 `SUB_NONE`** 이 된다.

```
 확장된 슬롯                    무엇을 두고 다투나             결과
 ───────────                   ──────────────────            ────
 Sub-slot 0 ─ ROM ─────┐
 Sub-slot 1 ─ SCC ─────┴──►  슬롯의 단일 ROM 파일           둘 합쳐 1개만
                              + 매퍼 1개 + SRAM 크기 1개

 Sub-slot 2 ─ FM-PAC ──┐
              GM2 ─────┴──►  lookup_SRAM 인덱스 (슬롯당 1)   둘 합쳐 1개만

 Sub-slot 3 ─ SCC+ ────────►  konami_scc 상태                중복 허용
                              {cart_num, subslot} 8조합       (단, 발음 칩은 슬롯당 1)
```

| 장치 | 문맥 | 중복 |
|---|---|---|
| `ROM` | 슬롯의 **단일 ROM 파일 공유** | ✗ ROM+SCC 합쳐 슬롯당 1 |
| `SCC` | 〃 | ✗ |
| `SCC+` | **(slot, subslot)별 독립** | **✓ 유일** |
| `FM-PAC` | 슬롯의 `lookup_SRAM` 점유, 인스턴스 슬롯당 1 | ✗ FM-PAC+GM2 합쳐 1 |
| `GameMaster2` | 〃, **슬롯 A 전용** | ✗ |

즉 "서브슬롯마다 다른 ROM"은 만들어지지조차 않는다. OSD에 `Load`·`Mapper`·`SRAM`이
슬롯당 하나씩만 있는 것도(`msx_config.sv:44-63`) 그 결과다.

### SCC+만 중복 가능한 이유

`konami_scc.sv:21-26`:

```systemverilog
// State is per (cart slot, subslot), not per cart slot: an expanded slot can hold
// a KonamiSCC game in one subslot and an SCC+ cart in another, and on real
// hardware those are two chips with two register sets.  idx = {cart_num, subslot}.
// The SOUND chip is still one IKASCC per cart slot (scc_sound.sv), so two
// SCC-family devices in one slot share it -- documented limitation.
wire  [2:0] idx = {cart_num, subslot};
logic [7:0] bank[8][4];
```

SCC+가 ROM 파일을 쓰지 않는 것(RAM 기반)이 중복 허용의 조건이다. **뱅크 상태는 둘인데
소리는 하나**라, OSD의 `SCC Slot A/B` 뮤트도 슬롯 단위다.

## 2. DDR3는 제약이 아니다

`ddram.sv:52`가 코어에 `0x30000000` 베이스로 **28비트 = 256 MB**를 준다.

```
 0x0000000    0 MB   ROM PACK (머신팩)
 0x0C00000   12 MB   슬롯 A 카트 ROM     ← CAS까지 10 MB (ASCII16X 8MB가 여기 들어감)
 0x1600000   22 MB   CAS 파일
 0x2000000   32 MB   FW PACK (9 MB)
 0x3000000   48 MB   슬롯 B 카트 ROM
      ~              약 208 MB 미사용
```

좁은 건 **기존 영역 사이의 틈**뿐이고 상단은 통째로 비어 있다. 이 배치는 이미 두 번
이사했다 — FW팩 `0x300000`→`0x2000000`(9MB 영역이 슬롯A를 덮어써 yrw801 상위 1MB를
날렸다), 슬롯 B `0x1100000`→`0x3000000`. 주석에 이유가 남아 있다.

`lookup_RAM[16]`도 러닝 할당자(`ref_ram <= ref_ram + refAdd`)라 여유가 있고,
`slot_layout[64]`는 이미 `{slot, subslot, block}` 전 조합을 갖는다.

## 3. 진짜 제약 셋

**① 프레임워크 규약 — 메뉴 항목 하나당 목적지 하나**
```
"H7H3FS3,ROM,Load,30C00000;"    슬롯 A
"H8H4F4,ROM,Load,33000000;"     슬롯 B
```
MiSTer `F`/`FS` 토큰의 마지막 필드가 DDR3 목적지 상수다. **파일 하나 = 메뉴 항목 하나 =
주소 하나.** 서브슬롯마다 ROM을 꽂으려면 Load 항목이 슬롯당 넷 필요하다. 코어가 바꿀 수
없는 인터페이스 수준의 규약이다.

**② 매퍼에 서브슬롯 차원이 없다**
`MSX1.sv:576` — `mapper_typ_t selected_mapper[2]`, 인덱스가 `cart_num`(0/1)뿐이다.
파일을 둘 올릴 수 있게 되더라도 서로 다른 매퍼를 줄 수 없다. 하류인
`slot_layout[].mapper`는 이미 서브슬롯별이므로 막힌 건 설정 쪽뿐이다.

**③ 자동 `.sav` 마운트가 인덱스 0 하나뿐**
저장 자체는 넷 다 된다 — `nvram_backup.sv`가 `lookup_SRAM[4]`를 `num`으로 순회하며
VD0–VD3를 각각 다룬다. 다만 카트를 꽂으면 알아서 붙는 `<rom>.sav`는 **VD0 하나**고
(`MSX1.sv:1096`), 그 인덱스 0은 슬롯 A만 받도록 못이 박혀 있다.

## 4. SRAM을 쓰는 장치 다섯

`msx_slots.sv:236`이 목록 그 자체다:

```systemverilog
wire sram_cs = fmpac_sram_cs | gm2_sram_cs | ascii16_sram_cs | ascii8_sram_cs | halnote_sram_cs;
```

| 장치 | 크기 | 활성 조건 | 정의 |
|---|---|---|---|
| **FM-PAC** | 8 KB 고정 | `sramEnable & ~addr[13]` → 4000–5FFF | `fm_pac.sv:147` |
| **GameMaster2** | 8 KB = 4 KB × 2뱅크 | `bank_base[4]` | `gamemaster2.sv:39` |
| **ASCII8** (+ KOEI, WIZARDY) | 1–32 KB (메뉴) | `sramEnable[cart_num]`의 8K 페이지 비트 | `ascii8.sv:53` |
| **ASCII16** (+ RTYPE) | 1–32 KB (메뉴) | `sramEnable[cart_num][addr[15]]` | `ascii16.sv:61` |
| **Halnote** | 페이지 0 전체 | `sramEnabled & addr[15:14]==00` | `halnote.sv:46` |

계열 묶음은 `msx_slots.sv:179-180`:
`cart_ascii8 = ASCII8 | KOEI | WIZARDY`, `cart_ascii16 = ASCII16 | RTYPE`.

크기는 OSD `SRAM size` 메뉴가 정한다 — `auto, 1kB, 2kB, 4kB, 8kB, 16kB, 32kB, none`
(`msx_config.sv:32`). FM-PAC과 GM2는 실물이 8 KB 고정이라 메뉴와 무관하다.

## 5. `lookup_SRAM[4]` 인덱스 배정

장치 종류가 아니라 **어느 슬롯의 어떤 부류인가**로 갈린다.

| idx | 대상 | 배정 조건 | 자동 `.sav` |
|---|---|---|---|
| **0** | 슬롯 A의 `ROM_ROM` 카트 SRAM | 슬롯 A 전용 (`memory_upload.sv:274`) | **VD0** |
| 1 | 슬롯 A의 비-ROM 카트 (FM-PAC / GM2) | `ref_sram <= 1` | 수동 |
| 2 | 슬롯 B의 비-ROM 카트 | `ref_sram <= 2` | 수동 |
| 3 | 머신팩 내장 슬롯 (`SLOT INTERNAL`) | 머신 XML의 SRAM | 수동 |

수동은 OSD `SRAM Save`/`SRAM Load` (`R[38]`/`R[39]`, `MSX1.sv:295-296`).

> ⚠️ **인덱스 0을 슬롯 A로 고정한 건 의도적이다.** `memory_upload.sv:266-276` 주석이
> 이유를 적어뒀다 — 슬롯 B에도 0을 주면 쓰기가 두 번 나가고 뒤엣것이 이겨서, 두 슬롯의
> `slot_layout`이 같은 인덱스를 가리키고 **슬롯 A의 카트가 슬롯 B의 버퍼를 읽고 쓴다.**
> 슬롯 B 저장을 켜려던 시도가 실제로 이걸 만들었고, 무해한 공백을 살아 있는 상호
> 손상으로 바꿨다.

## 6. 확장하려면 — 메모리가 아니라 배선 작업

| 필요한 것 | 난이도 |
|---|---|
| Load 항목 슬롯당 4개 + DDR3 영역 4개 (상단 208 MB에서) | 중 — 배치 재설계, 이사 이력 2건 주의 |
| `selected_mapper` → `[2][4]`, OSD 매퍼 4개 | 중 — 하류는 이미 준비됨 |
| 서브슬롯별 자동 `.sav` | **높음** — VD 자동 마운트는 코어 밖 |

세이브가 필요 없는 ROM이라면 앞의 둘만 하면 되고, 그건 순수 배선 작업이다.

## 7. 출처

`rtl/msx_config.sv` · `rtl/peripheral/slots/{msx_slots,memory_upload,konami_scc,fm_pac,gamemaster2,ascii8,ascii16,halnote}.sv` · `rtl/peripheral/ddram.sv` · `rtl/nvram_backup.sv` · `MSX1.sv`

관련: [[project_subslot_expansion]], [[project_mfrsd_scc_sound_cartridge]],
[[project_ascii16x_flash]], [[project_boot_flakiness]]
