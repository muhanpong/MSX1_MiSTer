# TODO — someday / low priority

Things that are real but that nobody is waiting on. Kept out of the active TODO
files so they do not dilute them. Each entry should say *why* it is parked, so a
future reader can tell whether the reason still holds.

---

## Yamanooto: ECHO and the HOME-key boot

**Parked because:** on current firmware, software cannot reach this feature at all,
and implementing either half alone buys nothing.

ECHO (CFGR bit1) makes the cartridge PSG *also* answer the internal PSG's ports
0xA0/0xA1, so music written for the internal PSG is doubled through the
cartridge's stereo output. The manual's stated purpose is to work around machines
whose internal PSG is badly balanced against the SCC.

Two facts from the 15oct2024 hardware reference decide this:

* the prose reads *"This is **set only** during boot when you press the HOME key"*
  (the 7dec2023 revision said "automatically set during boot" — it was tightened);
* the CFGR bit table marks ECHO **`RC`**, alone among CFGR bits, where SUBOFF, K4,
  ROMDIS and MDIS are all `RW`.

Read together: **software can read and clear ECHO but cannot set it.** The only
path to ECHO on real hardware is a HOME-key boot, which this core does not model.
So today ECHO can only ever be 0 here, and our not implementing the port aliasing
accidentally matches a non-HOME boot exactly.

Consequences of that, both directions:

* Nothing observable is lost right now. No program can set the bit, so no program
  can probe with it either.
* If someone implements the aliasing **without** the HOME path, every title would
  get a doubled PSG that real hardware only gives after a HOME boot — worse than
  leaving it alone. The two go together or neither does.

If it is ever done:

* openMSX registers it **out-only** — `Yamanooto.cc:96`,
  `register_IO_Out_range(0xA0, 2, this)`. Duplicating *reads* would break
  joystick and keyboard input, which come back through the internal PSG.
* Our `psg.sv:21` decodes `cpu_addr[7:3] == 5'b00010` (0x10-0x17) and derives
  bc1/bdir from `cpu_addr[1:0]`, so the alias is an extra `cs` term for 0xA0/0xA1
  with the same bc1/bdir decode.
* CFGR bit1 should become clear-only (`configReg[1] <= configReg[1] & din[1]`).
  Ours and openMSX's both let a write set it, which diverges from the `RC` marking
  — harmless while the bit drives nothing, not harmless once it does.
* A HOME-key boot path would need the key state sampled at reset. Note the core's
  `reset` is not an MSX-style CPU reset (`MSX1.sv:405` is HPS reset + OSD items +
  the ROM-load request), so "at boot" needs defining first.

Source: `Yamanooto Hardware Reference (public) (1).pdf` rev 15oct2024, section 2.3
and the CFGR bit table; official User Manual (the stated purpose).

---

## 영구 보류 (사용자 결정 2026-09-09) — 되살리지 말 것

2026-09-07~08 서브슬롯/매퍼 논의에서 나온 아이디어 세 건. 검토 결과 **득이
없다**고 판정되어 영구 보류한다. someday가 아니라 "하지 않기로 한 것"이므로,
future 세션은 이걸 다시 제안하지 말고, 되살리려면 사용자에게 이 항목을 먼저
보여줄 것.

1. **서브슬롯 ROM 위치 행 재설계** (형제 행에서 ROM/SCC 제거 + "ROM sub-slot"
   위치 행) — 현행 first-wins 동작으로 충분. CFG 인코딩이 바뀌어 기존 사용자
   전원이 서브슬롯 설정을 다시 해야 하는 대가가 이득(표시 정합)보다 크다.
2. **매퍼 헤더 태그** (MSX ROM 헤더 예약영역 0x0A-0x0F에 매퍼 ID) — 태그 붙은
   ROM이 세상에 없고, 태깅 도구·배포까지 세트로 만들어야 실효가 생긴다.
   auto 미검출 매퍼는 지금처럼 OSD Mapper 드롭다운으로 지정하면 된다.
3. **팩 빌더에 openMSX softwaredb SHA1 조회** — 2와 같은 이유. 팩은 머신
   구성용이지 게임 ROM 경로가 아니다.

(관련: ioctl_index 확장자 채널 실측은 2의 대안으로 논의된 것이라 함께 잠든다.)
