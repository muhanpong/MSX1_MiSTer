# FINAL MEMORY EDITS (exact replacement text)

These edits make a memory-only session resume SAFELY. Apply all. Memory path:
`/home/muhanpong/.claude/projects/-home-muhanpong-Documents-github-MSX1-MiSTer/memory/`

================================================================================
## FILE 1: project_cheat_engine.md
================================================================================

### Edit 1a — frontmatter `description` (line 3): fix index + merge state
REPLACE:
```
description: "치트(freeze/POKE) 엔진 구현+실기검증 완료. 레지스터 기반(BRAM 0), d_to_cpu mux 주입, ioctl F9 .CHT 로더. 브랜치 cheat-engine 머지대기"
```
WITH:
```
description: "커스텀 .CHT 치트 엔진=동작+머지완료(moonsound 102c6c1, 4-way BRAM). 로더 ioctl index 6(F6,CHT), d_to_cpu mux 주입. 표준 OSD cheats(.gg/255)=미해결·미머지(worktree cheat-standard)"
```

### Edit 1b — header (line 10): scope "실기검증완료" to custom only
REPLACE:
```
## 치트(freeze/POKE) 엔진 — 구현+실기검증 완료 (20260621)
```
WITH:
```
## 치트 엔진 — 커스텀 .CHT=동작+머지+실기OK / 표준 OSD .gg=미해결 (갱신 20260627)
★두 트랙 구분: (A) 커스텀 .CHT freeze/POKE = 완료·머지(102c6c1)·실기검증. (B) 표준 MiSTer OSD cheats(.gg/zip/ioctl255/"C,Cheats;") = OPEN, 미머지(worktree cheat-standard).
```

### Edit 1c — line 15: fix stale line number (register-era)
REPLACE `(~line 276, ...)` and `(line 183)` and `(line 156)` references with current values:
- d_to_cpu mux = `rtl/msx.sv:347`, `.DI(d_to_cpu)` = `:186`, Z80 addr `a` = `:159`,
  cheat_dl = `:320`, cheat_act = `:313`. (현 HEAD 102c6c1 4-way 기준.)

### Edit 1d — line 17: fix loader index F9/9 → F6/6
REPLACE:
```
- **로더 = ioctl index 9** ("F9,CHT,Load Cheats" CONF_STR). clk21m서 cheat_dl=download&index==9. ...
```
WITH:
```
- **로더 = ioctl index 6** ("F6,CHT,Load Cheats" CONF_STR, MSX1.sv:294). rtl/msx.sv:320 cheat_dl=download&ioctl_index[5:0]==6'd6. 코드주석 "CHT moved F9→F6 (F9 entry didn't show in OSD)"=F9는 OSD 미표시라 F6으로 옮김. (표준엔진은 worktree서 index 255, rtl/msx.sv:324.)
```
Also globally replace any remaining "F9"/"index 9"/"idx9" in this file (lines 23,31,32,35,44 era)
with the F6/index-6 form (custom engine) or index-255 (standard worktree engine) as appropriate.

### Edit 1e — lines 46-48: RETRACT "F1이 정답 확정" (the critical fix)
REPLACE the whole `**★★진범(안뜬 이유)**` / NES block (lines 46-48) WITH:
```
- **store_name 게이트 = 사실(메커니즘)**: menu.cpp:2685 `if(!store_name)`일 때만 cheats_init 호출, :2364서 F/S옵션 뒤의 C가 store_name=1로 셋. "FC1,MSX,Load ROM PACK"의 F뒤 C가 store_name=1 → 그 슬롯 로드론 cheats_init 미호출.
- **★★해결책은 FC1 수정이 아님(폐기된 오판)**: 한때 "FC1→F1으로 고치면 cheats 산다"고 결론냈으나 **틀림**. FC1=머신/BIOS 전용(MSX1.sv:255)·store_name=1·건드리면 머신 ROM 자동로딩/부팅 깨짐(F1빌드 cheatStd3 부팅fit 실패 확인). cheats는 게임을 **Slot A "Load"(H3FS3, MSX1.sv:259, store_name=0)** 로 로드하면 그 경로서 cheats_init이 이미 발화 — FC1/F1과 무관.
- **★worktree cheat-standard HEAD(102c6c1)는 이미 F1 포함**(MSX1.sv:256 = "F1,MSX,Load ROM PACK"). 폐기된 위험변경. 재빌드/머지 전 F1→FC1 복원 필수.
- **"메뉴 안뜸"의 진짜 원인 = 미해결(OPEN)**. 결정적 다음 한 수: 부팅되는 "C,Cheats;" 빌드(MSX1_20260625b_cheatStd.rbf, FC1)에서 게임을 Slot A "Load"로 로드 후 OSD Cheats 항목이 **회색(cheats_init 실행·0엔트리) vs 완전부재(cheats_init 미도달)** 관찰. 지금껏 (a)부팅 AND (b)Slot A store_name=0 둘 다 만족하는 빌드를 시험한 적 없음(미검증 갭). 보드는 현재 20260626b_cheatF1s2 → 20260625b 재선택 필요. 매칭 zip = cheats/MSX1/"Twinbee (1986) (Konami) (J).zip"(이름/CRC 일치 ROM 로드, 아니면 빈 메뉴=거짓음성).
- NES 대조(20260626): NES 코어선 OSD cheats 뜸=보드/Main260611/표준 경로 정상. 단 "NES되니 MSX1=코어버그"는 **확정 아님**(리드일 뿐). 미해결.
- ★진단: 코어 실행중 console printf 억제는 **미확정(UNVERIFIED)** — 화면 OSD 관찰이 권위 신호, 시리얼(stdbuf -oL)은 보조. 시리얼=PC측 ttyUSB0(FT232R), 보드 콘솔=ttyS0.
```

### Edit 1f — line 23 (변경 파일): fix CONF_STR token
REPLACE `MSX1.sv: CONF_STR "F9,CHT"+"O[51]" ...` WITH `MSX1.sv: CONF_STR "F6,CHT,Load Cheats"(:294)+"O[51]"(:295) + .cheat_en_master(status[51])`.

================================================================================
## FILE 2: MEMORY.md — index line for 치트 엔진 (currently line 22)
================================================================================

REPLACE:
```
- [치트 엔진](project_cheat_engine.md) — freeze/POKE 치트 구현+◆실기검증완료(20260621d). 레지스터기반(BRAM 0, M10K 530유지), d_to_cpu mux 주입(wired-AND회피), ioctl F9 .CHT로더(4B/엔트리), status[51] master. moonsound 머지완료(c5dea71). flash/msx_slots 무접촉. MFRSD부팅 실기OK
```
WITH:
```
- [치트 엔진](project_cheat_engine.md) — 두 트랙. (A)커스텀 .CHT freeze/POKE=◆동작+머지완료(moonsound 102c6c1, 4-way BRAM 512set×4way≈2048, 4 M10K, 335/553)+실기OK. 로더 ioctl **index 6**(F6,CHT)·master status[51]·d_to_cpu mux주입(rtl/msx.sv:347). flash/msx_slots/SDRAM 무접촉. (B)표준 OSD cheats(.gg/zip/ioctl255/"C,Cheats;")=**미해결·미머지**(worktree cheat-standard, ioctl 255). ★★FC1→F1=폐기된 오판(FC1=머신전용·건드리면 부팅깨짐, cheats와 무관). cheats는 게임을 Slot A "Load"(H3FS3 store_name=0)로 로드시 발화. ★worktree HEAD는 이미 F1(MSX1.sv:256)→재빌드前 FC1복원. 결정적 미검증=부팅 C,Cheats빌드(20260625b)+Slot A로드+OSD 회색vs부재 관찰. printf억제=미확정.
```

================================================================================
## FILE 3 & 4: confirm authoritative (no change OR soften)
================================================================================

### project_msx1_rom_load_menus.md — AUTHORITATIVE, keep as-is
This file (esp. line 23: "FC1을 F1으로 바꿔 cheats 살린다 = 완전 오판, FC1 절대 손대지 말 것")
is CORRECT and is the authority on the FC1 rule. Where it conflicts with cheat_engine.md, it wins.
No edit needed. (Optional: add a one-line cross-ref noting cheat_engine.md was corrected to match.)

### project_msx_vs_msx1_cores.md — SOFTEN line 22-23 (hypothesis, not settled)
Line 22-23 state "표준OSD방식은 HPS수정 필요(코어RTL만으론 불가)" as settled. Downgrade to hypothesis:
REPLACE the tail of line 23:
```
결론=표준OSD방식은 HPS수정 필요(코어RTL만으론 불가), 현실해=커스텀 .CHT(이미동작, c5dea71/102c6c1 머지됨)+웹앱 per-cheat.
```
WITH:
```
가설(미확정)=표준 OSD가 MSX1 구조(ROM PACK/DDR로딩)와 안 맞을 수 있음 — 단 게임을 Slot A "Load"(H3FS3 store_name=0)로 로드하면 cheats_init은 발화하므로 아직 OPEN(결정적 실험: 부팅 C,Cheats빌드 20260625b+Slot A로드+OSD 관찰). 현실해=커스텀 .CHT(동작·머지 102c6c1)+웹앱 per-cheat.
```
Keep line 15 (CoreName2=MSX1, cheats/MSX1/) as the authority that **we work on MSX1** — this
correctly contradicts any doc that says "we are not MSX1".
