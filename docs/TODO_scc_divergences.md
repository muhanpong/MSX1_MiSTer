# TODO — SCC / SCC+ 구현이 openMSX와 갈리는 지점 (D1~D6)

2026-08-23 SCMD 조사 중 `scc-rtl` 크리틱이 찾아낸 6건.
**SCMD 증상과는 무관하다** — 그 건은 `docs/mfrsd_scc_sound_cartridge_20260823.md`에서
"우리 코어 무죄"로 종결됐다. 여기 있는 것들은 그 과정에서 **별도로** 드러난 실제 결함이다.

D1·D5는 내가 openMSX 소스와 대조해 독립 확인했다. D3·D4·D6은 우리 쪽 코드 위치만
확인했고 **openMSX 쪽 대조는 미완**이다 (각 항목에 표시).

> ⚠️ **작업 순서 원칙.** 2026-08-23에 이 영역에서 "고치려다 되돌린"(`cc5fa4d`) 전례가 있다.
> 어느 항목이든 **TB(네거티브 컨트롤 포함) → 골든 대조 → 구현** 순으로 간다.
> 기존 `tb_sccplus` / `tb_mfrsd_sccmode` / `tb_mfrsd_sccsound`가 통과 중인 동작을
> 바꾸는 수정은, 먼저 그 TB에 **현 동작을 고정하는 케이스를 추가**한 뒤에 손댄다.

---

## D5 — `scc_mode`가 칩 모드와 창 가시성을 섞는다 ★가청, 1순위

**확인 상태: VERIFIED** (내가 openMSX 소스 직접 대조)

**Now:** `rtl/peripheral/slots/mfrsd.sv:110`

```systemverilog
assign scc_mode = sccMode[5] & sccBanks[3][7];
```

**openMSX:** 두 개념이 분리되어 있다.

| | openMSX | 쓰임 |
|---|---|---|
| 칩 모드 | `MegaFlashRomSCCPlusSD.cc:621` `scc.setMode((value & 0x20) ? Plus : Compatible)` | **bit5만** |
| 창 가시성 | `:503` `if ((sccMode & 0x20) && (sccBanks[3] & 0x80))` | bit5 **AND** bank3 bit7 |

**증상:** IKASCC는 `i_SCCP_MODE`를 오디오 경로에서 **연속으로** 소비한다
(`IKASCC_player_s.v:309` — Plus가 아니면 ch5 파형을 ch4의 공유 RAM에서 래치).
재생 중 `0xA000~0xBFFF`에 bit7 없는 뱅크를 페이징하면 `sccBanks[3][7]`이 떨어지고,
칩이 Compatible로 오해해 **ch5가 ch4 미러로 들린다.**

**같은 유형이 `cc183c9`에서 이미 한 번 고쳐졌다** (`mapper_mfrsd1`이 창 인에이블 대신
모드를 내보내도록). 그때 `EN_SCCPLUS`의 주소 항은 제거했지만 `sccBanks[3][7]`은 남았다.
**절반만 고쳐진 상태.**

`konami_scc.sv:61`도 같은 형태다:
```systemverilog
assign scc_mode = { sccDevice & sccMode[1][5] & bank[1][3][7], ... };
```

**수정 방향:** `scc_mode`에서 `sccBanks[3][7]` / `bank[..][3][7]` 항 제거.
`scc_req`(창 디코드)는 그대로 둔다 — 거기서는 bank3 bit7이 맞다.

**TB:** 기존 `sim/tb_mfrsd_sccsound.sv`가 주소 축만 훑어서 못 잡는다.
필요한 케이스 = *SCC+ 모드로 파형을 쓴 뒤, `0xB000`에 bit7 없는 뱅크를 쓰고,
CPU를 다른 곳에 둔 채 ch5 파형이 여전히 자기 값인지 읽어본다.*
네거티브 컨트롤 = `sccBanks[3][7]` 항 복원 시 실패해야 함.

---

## D1 — SCC+ 창이 256B, openMSX는 2KB

**확인 상태: openMSX 쪽 방증 확보** (`invalidateDeviceRWCache(0xB800, 0x800)` = 2KB)

**Now:**
```systemverilog
rtl/peripheral/slots/mfrsd.sv:98       ... & cpu_addr[15:8] == 8'hB8      // 0xB800-0xB8FF (256B)
rtl/peripheral/slots/konami_scc.sv:66  ... & cpu_addr[15:8] == 8'hB8
```
**openMSX:** `MegaFlashRomSCCPlusSD.cc:624` `invalidateDeviceRWCache(0xB800, 0x800)`
→ `0xB800~0xBFFF` **2KB** 전체가 SCC+ 창. 즉 `0xB900~0xBFFF`는 미러다.

**우리 쪽 기존 논거:** `docs/sccplus_spec.md`가 "창 256B는 무해"라고 적고 있다.
근거는 실제 소프트웨어(SD Snatcher 등)가 `0xB8xx`만 쓴다는 관찰이었다.

> ⚠️ `scc-rtl`이 **그 논증이 인용한 근거와 반대 결론을 낸다**고 지적했다.
> **먼저 `sccplus_spec.md`의 해당 절을 다시 읽고 판정할 것.** 논거가 성립하면
> D1은 "의도된 축소"로 닫고 문서에 근거를 보강, 성립하지 않으면 2KB로 확장.

**바꿀 때 주의:** 창을 넓히면 `0xB900~0xBFFF`가 ROM/RAM에서 SCC로 넘어간다.
그 영역을 데이터로 쓰는 소프트웨어가 있으면 회귀한다. **골든 대조 필수.**

---

## D4 — SCC 창이 매퍼 모드로 게이트되지 않는다

**확인 상태: 우리 쪽 확인 / openMSX 대조 미완**

**Now:** `rtl/peripheral/slots/mfrsd.sv:98-99` — `EN_SCCPLUS` / `EN_SCC` 어디에도
`mapperReg[7:5]` 검사가 없다. (모드 레지스터 **쓰기**는 `:83` `if (mapperReg[7:5] == 3'd0)`로
게이트되지만, **창 디코드**는 아니다.)

**openMSX:** 읽기·쓰기 경로 전부가 `isKonamiSCCmapperConfigured()` 안에 들어 있다
(`MegaFlashRomSCCPlusSD.cc:534, 551, 568, 617`).

**증상:** ASCII8/ASCII16/linear64로 전환한 뒤에도 `sccMode`/`sccBanks` 잔존값에 따라
`0xB800~0xB8FF`(또는 `0x9800~0x9FFF`)가 ROM 대신 SCC로 잡혀 **ROM에 256B 구멍**이 생긴다.
Pazos p100 발언과도 맞는다 — "ASCII8 ROM을 구우면 SCC는 사용할 수 없다".

**할 일:** `EN_SCC`/`EN_SCCPLUS`에 `mapperReg[7:5] == 3'd0` 추가.
먼저 openMSX 경로를 직접 읽어 조건이 정확히 같은지 확인할 것.

---

## D3 — `0xBFFE` 쓰기가 플래시로도 샌다

**확인 상태: 우리 쪽 확인 / 영향 낮음**

**Now:** `rtl/peripheral/slots/mfrsd.sv:172` `assign flash_rq = cs & flashAddrValid;`
— 모드 레지스터 주소여도 플래시 요청이 그대로 나간다.

**openMSX:** `:635`
```cpp
return; // Pazos: when SCC registers are selected flashROM is not seen, so it does not accept commands.
```

**영향:** 낮음. JEDEC 언락은 `0xXAAA`/`0xX555`를 요구하는데 `0xBFFE`는 그 패턴이 아니라
FSM 상태를 진전시키지 못한다. 다만 **언락 시퀀스 중간에 `0xBFFE`를 건드리는 코드가 있으면**
FSM이 어긋날 수 있다.

**할 일:** `flash_rq`에서 SCC 레지스터 선택 시를 빼는 한 줄. 우선순위 낮음.

---

## D6 — ASCII-16 뱅크가 8비트, Pazos 명세는 10비트

**확인 상태: 우리 쪽 확인 / 상한 계산 재검 필요**

**Now:** `rtl/peripheral/slots/mfrsd.sv:150-157`
```systemverilog
3'b110, 3'b111: begin //Ascii16
   if (cpu_addr[15:11] == 5'b01100) begin
      bank[0] <= {din[6:0],1'b0};      // din 상위 1비트 버림
      bank[1] <= {din[6:0],1'b1};
   end
```
`bank`는 `logic [7:0] bank[4]`다.

**Pazos 명세** (openMSX `MegaFlashRomSCCPlusSD.cc` 헤더의 VHDL 발췌):
SCC/ASC8/ASC16 모드에서 `Bank0(9 downto 0) & adr(12 downto 0)` — **10비트 뱅크**.

**증상:** 큰 ASCII-16 이미지에서 상위 뱅크에 닿지 못한다.
(`scc-rtl`은 "2MB 초과"라고 했으나 **계산을 다시 할 것** — 8비트 뱅크 × 8KB = 2MB가
맞는지, ASCII16이 16KB 단위라 4MB인지 확인 필요.)

**참고:** Pazos p98 — 2015년 이전 생산분은 ASCII16 매퍼가 1MB로 제한되어 있었고
FPGA 재구성으로 4MB를 지원하게 바뀌었다. **어느 리비전을 재현할지 먼저 정할 것.**

**할 일:** `bank`/`bankValue` 폭 검토. `bankValue`는 이미 16비트이므로
(`mfrsd.sv:167`) 주로 `bank[4]` 배열 폭과 ASCII16 대입부의 문제다.

---

## D2 — 원인 아님 (닫음)

`0xBFFE` **읽기**가 SCMD 판정에 쓰인다는 가설. **기각.**
`CORE2.SY2:0xC15A`의 `LD A,(0xBFFE) / LD B,A`는 저장용이고, 끝에서 `LD A,B`로 복원만 한다.
실제 판정은 `0xC16F`의 `JR NZ`다. (`docs/mfrsd_scc_sound_cartridge_20260823.md` §4-3)

D1과 묶여 보고됐으므로, D1 작업 시 함께 닫힌 것으로 처리한다.

---

## 함께 처리할 검증 항목

- [ ] **`docs/sccplus_spec.md`의 "창 256B 무해" 절 재판정** (D1의 선결 조건)
