# B4 Memory Audit — Cheat Work Consistency

Audit only. No memory files were edited. Goal: flag where memory contradicts the
known session facts about cheats so the next session is not misled.

## Known facts used as the reference baseline
1. TWO cheat implementations coexist:
   - MAIN REPO custom `.CHT` — `F6` / `O[51]`, ioctl index **6**, MERGED (`102c6c1`), HW-works.
   - WORKTREE standard `.gg` — `C,Cheats` / ioctl **255**, UNMERGED, OSD menu does not appear.
2. `FC1` = machine/FW only, never game. Game load = Slot A `H3FS3`, store_name=0. FC1 must NOT be changed.
3. "F1 fixes cheats" idea was WRONG — FC1 is machine-only; F1 broke boot / machine-autoload.
4. Standard MiSTer OSD cheats were never done on any MSX core before (first attempt).
5. The standard-cheats menu-absent root cause is STILL UNRESOLVED.
6. 6-agent findings: our `.gg` layout vs NES-standard layout mismatch (but self-consistent); `use_cheats=1` only in worktree (main repo has no `C,Cheats`).

## Ground-truth checks I ran (main repo, branch `moonsound`)
- `MSX1.sv:294` = `"F6,CHT,Load Cheats;"`, `:295` = `"O[51],Cheats,Off,On;"` → confirms fact 1 (custom = F6/O51).
- `rtl/msx.sv:320` = `cheat_dl = ioctl_download & (ioctl_index[5:0]==6'd6);` with comment **"CHT moved F9→F6 (F9 entry didn't show in OSD)"** → confirms ioctl index **6**, and that the F9 path was abandoned.
- `git log`: `c5dea71` = register-based (merged), `102c6c1` = 4-way set-associative BRAM (merged). Both present.

---

## File-by-file findings

### project_cheat_engine.md — NEEDS MAJOR CORRECTION (most misleading file)

**A. Stale ioctl index (F9/index 9) — wrong throughout.**
- Claims "로더 = ioctl index 9 (F9,CHT)" (line 17), "F9,CHT" (lines 23, 31, 32, 35), and the standard transition says "index9→255" (line 44).
- REALITY: merged main repo uses **F6 / ioctl index 6**. The code comment explicitly notes "F9 entry didn't show in OSD" → the index was changed for exactly that reason. This is load-bearing history that the memory omits and contradicts.
- Mismatch with fact 1 (F6/ioctl 6).

**B. CONTRADICTS facts 3 & 5 — presents the disproven F1 fix as "confirmed".**
- Lines 46–48 state the menu-absent root cause is FOUND: FC1's `C`=store_name flag → store_name=1 → `cheats_init` never called → entry greyed; "수정=FC1→F1"; "**F1이 정답 확정**"; "◆◆NES 대조로 진범 100% 실증"; "**F1이 정답 확정.**"
- This is exactly the idea fact 3 says was WRONG, and fact 5 says the root cause is UNRESOLVED. This file still asserts it as 100% proven.
- It also DIRECTLY CONTRADICTS `project_msx1_rom_load_menus.md:23` ("FC1을 F1으로 바꿔 cheats 살린다고 한 것은 완전 오판 … FC1 절대 손대지 말 것"). The two memory files give opposite conclusions on the same question. cheat_engine.md is the stale/wrong side.
- The file's own explanation for the broken F1 build (line 48: "SDRAM_DQ IOB roulette → Quartus SEED 재빌드") is also misleading: per fact 3 the real problem is that touching FC1 breaks machine-ROM autoload, not an IOB placement lottery.

**C. Over-confident "완료" headline without the custom-vs-standard split.**
- Header (line 10) "치트 엔진 — 구현+실기검증 완료" and frontmatter both read as if cheats are globally done. True only for the custom `.CHT`. The standard-OSD `.gg` attempt is unresolved (fact 5) and unmerged (fact 1). No caveat distinguishes them.
- Frontmatter `description` (line 3) still says "브랜치 cheat-engine 머지대기" (awaiting merge) — stale; body says merged. Inconsistent within the file.

**D. Two-source distinction blurred.**
- The file narrates register → 4-way → standard as a single evolving line ("표준 .gg/ioctl-255 전환"), implying standard replaces custom. Fact 1 says they are TWO separate coexisting sources: custom `.CHT` lives merged in MAIN REPO; standard `.gg` is a SEPARATE UNMERGED WORKTREE attempt that is broken. Should be stated as two parallel tracks, not a completed migration.

**E. Correct / keep:** d_to_cpu mux injection, register→4-way BRAM design, O[51] master (status[51]), 4-way merged at `102c6c1`, real-HW pass for the custom path, flash/msx_slots untouched. These match ground truth.

### project_msx1_rom_load_menus.md — ACCURATE (keep)
- Lines 12–26 correctly state FC1/FC2 = machine/FW only, game = Slot A `H3FS3` store_name=0, and explicitly label "FC1→F1" as "완전 오판 / FC1 절대 손대지 말 것." Fully consistent with facts 2 & 3. No edits needed. (This is the file the next session should trust over cheat_engine.md.)

### project_msx_vs_msx1_cores.md — MOSTLY OK, one over-confident line
- "MSX 계열은 표준 MiSTer OSD cheats 원래 미지원 … 처음 시도" matches facts 4. Good.
- Line 23: "결론=표준OSD방식은 HPS수정 필요(코어RTL만으론 불가)" is stated as a settled conclusion. Given fact 5 (root cause UNRESOLVED), this should be downgraded to a hypothesis. Also worth noting fact 6: `use_cheats=1` only fires in the worktree (main repo has no `C,Cheats`), and our `.gg` byte layout differs from the NES-standard layout (self-consistent but unverified against HPS expectations).
- Line 22 "MSX 구조 자체가 표준 cheats와 안 맞는 것" — directionally fine vs fact 4, but it presents a likely-but-unproven cause as fact while the true root cause is still open. Soften.

### MEMORY.md (index) — line 22 cheat entry NEEDS UPDATE
- Current: "freeze/POKE 치트 구현+◆실기검증완료(20260621d) … ioctl F9 .CHT로더(4B/엔트리) … moonsound 머지완료(c5dea71) … MFRSD부팅 실기OK".
- Problems: (a) "F9" → should be **F6 / ioctl 6**; (b) cites only `c5dea71`, omits final 4-way merge `102c6c1`; (c) blanket "실기검증완료" with no mention that this is the custom `.CHT` only and that the standard-OSD attempt is unresolved & unmerged.
- Index lines 3 (rom_load_menus) and 4 (msx_vs_msx1) are accurate and consistent with facts 2/4 — keep.

---

## Recommended edits (text only — do NOT apply in this task)

### MEMORY.md, line 22 — replace cheat entry with:
> - [치트 엔진](project_cheat_engine.md) — **두 갈래로 분리할 것**: (1) **커스텀 .CHT = 동작+실기검증+머지완료** — `F6`/`O[51]`, ioctl idx **6**, register→4-way BRAM(102c6c1, c5dea71 토대), d_to_cpu mux 주입, BRAM 0(register)/4 M10K(4-way), flash/msx_slots 무접촉, MFRSD부팅 실기OK. (2) **표준 OSD .gg = 미해결·미머지(worktree)** — `C,Cheats`/ioctl 255, OSD 메뉴 안 뜸, 근본원인 UNRESOLVED. ★주의: 과거 "FC1→F1로 cheats 살림" 결론은 **오판**(FC1=머신전용, F1은 부팅/머신오토로드 깨짐 — project_msx1_rom_load_menus 참조). MSX코어 표준OSD cheats=전례없는 첫 시도.

### project_cheat_engine.md — required corrections:
1. Global: replace every "F9 / ioctl index 9" with "F6 / ioctl index 6", and add a one-line note: "F9였으나 OSD에 항목이 안 떠 F6로 이동(msx.sv:320 주석). index 변경만으로 '안 뜨는' 문제가 다 풀린 건 아님."
2. Frontmatter `description` (line 3): remove "브랜치 cheat-engine 머지대기"; state "커스텀 .CHT 머지완료(102c6c1); 표준 OSD는 별개·미해결."
3. Lines 46–48 (standard .gg section): retract the "FC1→F1 = 진범/정답 확정" and "NES 대조로 100% 실증" claims. Replace with: "★★표준 OSD 메뉴가 안 뜨는 근본원인은 **미해결(OPEN)**. 가설로 store_name/FC1을 의심했으나 **FC1→F1은 오판으로 폐기**(FC1=머신전용, 변경 시 머신 ROM 오토로드/부팅 깨짐 — project_msx1_rom_load_menus). 6-에이전트 조사: 우리 .gg 레코드 레이아웃이 NES-표준과 불일치(내부적으론 self-consistent), use_cheats=1은 worktree에서만(메인엔 C,Cheats 없음). 다음 세션 과제로 OPEN."
4. Header (line 10) + add caveat: "완료된 것은 **커스텀 .CHT 경로뿐**. 표준 OSD .gg는 별도 worktree·미머지·미해결."
5. State the two sources explicitly as parallel tracks (main repo custom = merged/working; worktree standard = unmerged/broken), not a completed migration.

### project_msx_vs_msx1_cores.md — soften line 22–23:
- Change "결론=표준OSD방식은 HPS수정 필요(코어RTL만으론 불가)" to "가설(미확정): 표준OSD가 안 뜨는 근본원인 UNRESOLVED. use_cheats=1은 worktree에서만 트리거, .gg 레이아웃이 NES-표준과 불일치. 현실 동작해는 커스텀 .CHT(F6, 머지됨)."
- Keep the "MSX는 표준 cheats 첫 시도" framing (matches fact 4) but mark the structural-mismatch claim as probable, not proven.

---

## Bottom line
- The single most dangerous artifact is **project_cheat_engine.md lines 46–48**: it asserts the disproven "FC1→F1" fix as "100% 실증/정답 확정", directly contradicting the corrected `project_msx1_rom_load_menus.md` and the known facts. A next session reading cheat_engine.md first would be actively misled into editing FC1.
- Secondary: pervasive **F9/ioctl-9 staleness** (reality = F6/ioctl-6, and F9's removal is itself a clue about the menu-absent bug).
- Third: no memory file cleanly separates **custom .CHT (works/merged)** from **standard OSD (unresolved/unmerged)**; the "실기검증완료/완료" headlines overstate scope.
- `project_msx1_rom_load_menus.md` is correct and should be treated as the authority on the FC1 rule.
