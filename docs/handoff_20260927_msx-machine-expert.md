# 인수인계 — msx-machine-expert (2026-09-27)

이 세션의 역할: **openMSX 기준계측·머신 팩·실물 대조 담당**. 코어 RTL·sim·빌드게이트는 `stable_Turbo-R` 세션 영역(워크트리 `MSX1_MiSTer/.claude/worktrees/readcache`, 브랜치 nextz80). 파일 영역 분담: 이쪽 = `tools/CreateMSXpack/**`, `tools/omsxprobe/**`, `tools/turbor_diskrom/**`, `docs/**`, 계측 산출물.

먼저 읽을 것: 메모리 인덱스(`~/.claude/projects/-home-muhanpong-Documents-github-MSX1-MiSTer/memory/MEMORY.md` — 맨 위 "행동 전 트리거" 표), 그리고 `docs/handoff_20260927_mupack.md`(stable_Turbo-R 쪽 정본).

## 작업 위치·git
- 워크트리: `/home/muhanpong/Documents/github/MSX1_MiSTer-sonydos2`, **detached HEAD**(현재 feeecdc = origin/nextz80 = origin/mupack). nextz80은 readcache가 체크아웃하고 있어 여기선 못 씀.
- 커밋은 여기서 만들고 `git fetch origin nextz80` → ff 확인 → `git push origin HEAD:nextz80`. 강제 push 금지. push하면 stable_Turbo-R에 한 줄 통보.
- 옮길 때 스테이징이 풀릴 수 있음(20260924 실수): 커밋 후 `git show --stat HEAD`로 전부 들어갔는지 확인.
- untracked `tools/CreateMSXpack/Computer/Panasonic/Panasonic FS-A1_Turbo-R_XML.zip`은 출처 모름 — 건드리지 말 것.
- 공개 리포임(muhanpong/MSX1_MiSTer, public). **ROM·합성 ROM·.MSX 팩 커밋 금지.** `tools/turbor_diskrom/.gitignore`가 *.rom/*.bin 막음.

## 보드 (root@192.168.1.86, ssh 별칭 `mister`)
- 최신 RBF: `/media/fat/_Computer/MSX1_20260927c_mupack.rbf`(다른 곳에서 빌드·배포 완료). RBF 삭제·덮어쓰기 금지.
- 팩: `/media/fat/games/MSX1/MSX/Panasonic/` — turbo R DOS2 변종 9종 + `Panasonic FS-A1GT DOS2-ILLUK.MSX`(환영도시 한글판 전용 한자 폰트).
- FW 팩: `/media/fat/games/MSX1/CART_FW_*.MSX` 4종 + `MSX/` 아래 4종 — **μ·PACK 포함판으로 교체 완료**(타 세션, 16:20 / 17:21). md5 JP 4e3cd697 / JP_2slot e201fdf4 / EN a3b8166c / EN_2slot 6bde3678 — 이쪽에서 따로 만든 것과 8개 모두 일치. 옛 판(04fda78c/5d95539b/ff0ff1eb/87798f1b) 백업은 타 세션 스크래치 `fw_backup_board_20260927/`. ★사용자는 `MSX/` 쪽을 로드함(`config/MSX1.f2`) — 보드 파일 교체 전엔 `find`로 사본 전부 찾고 `config/MSX1.f1/.f2`부터 볼 것.
- 란마 1/2 한글판: `games/MSX1/Ranma 1-2 (1-8)(k)(fix).dsk`, `DSKS/…(fix).dsk` 추가함(원본 두 개는 그대로, 루트 쪽 원본은 오염본).

## μ·PACK(슬롯 B) — 종결
- 코어 `MSX1_20260927c_mupack.rbf`(md5 2b8a3bb4…, 8443c50에서 빌드, BUILDGATE PASS) — 다른 곳에서 빌드·배포.
- **실기 확인 완료(사용자)**: ST + 슬롯 B MU-PACK에서 ARMI v1.02, 환영도시 한글판 μ·PACK 이식판 연주, OSD "MIDI: MU-PACK (Slot B) active", `CALL RAMDISK` **352**, 여유 바이트 **25269** — 이쪽 openMSX 기준값(352 / 25269)과 정확히 일치.
- 커밋: mupack 4커밋(bbdf660·10b98bc·e6ea084·8443c50)은 nextz80에 fast-forward로 들어가 있음(origin/nextz80 = origin/mupack = feeecdc). 정본 핸드오프 `docs/handoff_20260927_mupack.md` §0·§3. (그 문서 34행 "origin/mupack not merged"는 feeecdc 시점 이후엔 낡은 문장.)
- 검토 보고서(설계 불일치 0, 실기 계획 10항목): 스크래치 `…/scratchpad/mupack/REVIEW_mupack_20260927.md` — 리포 커밋 여부는 사용자 결정 대기. 실기 계획 중 남은 것은 음성대조·GT·회귀·옛 FW 팩 항목(#7~#10), 필요 시.

## 보류·열린 것
- 3-3 PANASONIC 매퍼 팩: 보류(펌웨어 스위치 OFF 고정이라 이득 없음, GT MSX-View는 메인 RAM 뱅크 필요). 해제 시 첫 확인 = SRAM 크기(ST 16KB/GT 32KB).
- rz80 워크트리: 보류(백업 없음·push 불가, 삭제 금지).
- ASO 하단 2~4줄 깜빡임: 계측 제안만 한 상태.

## openMSX 계측 환경 (스크래치, 재부팅 시 소멸)
- 빌드된 openMSX(BankedSonyFDC 추가): `…/scratchpad/omsxsrc/derived/x86_64-linux-opt/bin/openmsx`, 실행 시 `OPENMSX_SYSTEM_DATA=/usr/share/openmsx`.
- **격리 홈**: `…/scratchpad/omsxhome_iso`(persistent 로컬 사본). `omsxhome2`는 persistent가 **실제 ~/.openMSX/persistent로의 링크**라 쓰면 사용자 설정이 오염됨(20260924 firmwareswitch 사고, 원복 완료).
- 머신: ST_synthB/GT_synthB(보드 DOS2 팩 등가), ST_pack_nodos 등. 스크린샷은 `SDL_VIDEODRIVER=offscreen`.
- Tcl 함정: `debug set_watchpoint <type> <addr> {} {body}` 조건 인자 필수 / `get_selected_slot` 없음(A8·FFFF로 계산) / read 워치포인트의 wp_last_value 불안정 / I/O 주소는 16비트라 `& 0xFF` / 8254 peek는 LSB·MSB 순서를 안 넘김.
- openMSX 소스: `/home/muhanpong/Documents/github/openMSX`(= `/home/muhanpong/github/openMSX`, 같은 2712dbd1c).

## 지켜야 할 것 (메모리에 근거 있음)
- 작업 요청은 복명복창 후 실행. 빌드는 사용자 "해"가 있을 때만(`tools/buildgate/build.sh`, 배포 `deploy.sh`).
- kill은 직접 띄운 리터럴 PID만. 보드 파일은 덮어쓰기·삭제 전에 확인, 기본은 새 이름.
- 타 세션 결과는 직접 교차검증. "0회" 결과는 검출기부터 의심.
- 답변은 음슴체로 간결하게.
