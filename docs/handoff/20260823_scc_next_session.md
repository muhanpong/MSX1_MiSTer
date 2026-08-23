# 인계 프롬프트 — 2026-08-23 세션 종료 시점

아래 `---` 사이를 **새 세션에 그대로 붙여넣으면** 이어서 작업할 수 있다.
(`--resume` 불필요. `MEMORY.md`는 새 세션에서 자동 로드된다.)

---

MSX1_MiSTer 코어 작업을 이어간다. 브랜치 `moonsound_ascii16x`, HEAD `68b2a9e`, 원격에 푸시 완료, 트래킹 파일 워킹트리 깨끗함(untracked 112건은 기존 자료라 무시).

## 직전 세션에서 끝난 것 — 다시 조사하지 말 것

**SCMD가 MFRSD의 SCC+를 검출 못 하는 건 우리 코어 무죄로 종결됐다.** 실기 MFRSD에서도 동일하게 실패한다. 크리틱 3인 합의 + openMSX 자체 MFRSD 모델로 증상 재현 확인.

- 전문: `docs/mfrsd_scc_sound_cartridge_20260823.md`
- 이유 두 겹(둘 다 구조적): ① MFRSD 서브슬롯 1은 플래시뿐, RAM 없음 ② 프로브가 한 `(primary,subslot)` 쌍을 페이지 1·2에 통째로 꽂으므로 SCC와 RAM이 **같은 서브슬롯**이어야 하는데 MFRSD는 SCC-I=서브1 / 512K RAM=서브2
- 정답은 OSD **`SLOT A/B = SCC+`** (`CART_TYP_SCC2` = 128KB 쓰기가능 RAM + SCC-I + 비확장 슬롯). RTL 수정 불필요. **실기 확인 완료**이고 상시 사용 중이다 — A·B 동시 배치도 된다. 다시 검증할 것 없음.
- "MFRSD SCC++" 아이디어는 검토 후 **기각**(옵트인 토글 아니면 불가). 사유는 문서 §11.
- `tools/scmd_mfrsd/`의 `CORE2P.SYS`·`MFRSDSCC.BAS`는 **동작 안 함**. 유지하되 사용 비권고(`tools/scmd_mfrsd/README.md`). 다시 손대지 말 것.
- 조사 원자료: `~/msx_archive/mfrsd_scmd_20260823/` (MRC 스레드 108쪽 + SCMD 바이너리). 도구는 `tools/scmd_analysis/`.

## 다음에 할 일 (우선순위)

**1순위 — D5 수정.** `rtl/peripheral/slots/mfrsd.sv:110`의 `scc_mode`에 `sccBanks[3][7]`이 섞여 있다. openMSX는 칩 모드에 **bit5만** 쓴다(`MegaFlashRomSCCPlusSD.cc:621`). 재생 중 `0xA000~0xBFFF`에 bit7 없는 뱅크를 페이징하면 **ch5가 ch4 미러로 들리는 가청 결함**. `cc183c9`가 같은 유형을 절반만 고친 상태. `konami_scc.sv:61`도 같은 형태.

**나머지 D1/D3/D4/D6 + 작업 순서 원칙**은 `docs/TODO_scc_divergences.md`에 파일:행·openMSX 대응·확인 상태(VERIFIED / 대조 미완)까지 정리돼 있다. D2는 원인 아님으로 종결. **D1은 `docs/sccplus_spec.md`의 "창 256B 무해" 논증 재판정이 선결 조건.**

## 실기 미검증으로 남아 있는 것

- `20260823c`/`20260823d` 오디오 트림(주관 평가), 리셋 토글 `No`, OPLL 트림 배선 — `docs/TODO_osd_and_ux.md`

## 보류(사용자 결정)

- 슬롯 B Yamanooto 조합 부팅 불안정, `docs/TODO_boot_flakiness.md` (같은 근본)
- 슬롯 B 세이브 — 펌웨어가 `.sav`를 VD0에 하드코딩 마운트해서 불가
- 슬롯 A/B를 사용자 선택으로 **확장 슬롯**화 + 서브슬롯별 장치 메뉴 — 조사만 함. 인프라(`slot_layout[64]`, 서브슬롯 0~3 순회, 확장 자동 활성화)는 이미 있고, 제약은 ①슬롯당 ROM 파일 1개(`ioctl_size[2]/[3]`, DDR3 스테이징 2구역) ②디바이스 인스턴스가 슬롯당 하나라 **종류별 1개**(`konami_scc`가 `cart_num` 인덱스, `scc_sound` 2채널, OPLL 3개) ③`lookup_SRAM[4]` 중 3개 사용 중. 기기가 이미 확장하는 primary는 제외해야 함(`conf[4][3:0]`를 OR 결과와 분리 보관 필요).

## 작업 규칙 (반드시 지킬 것)

- **모든 작업 요청은 실행 전 복명복창.** 특히 재빌드·배포·덮어쓰기.
- **파일 삭제/덮어쓰기 금지.** 먼저 확인하고, 기본은 새 이름으로 생성.
- **지시 없이 고치지 말 것.** 조사만 요청받았으면 조사만.
- **엔지니어로서 직언.** 사용자 아이디어라도 기술적으로 약하면 기각·반대. silent-failure와 낮은 ROC는 플래그.
- **항상 교차 검증.** 서브에이전트 결과를 그대로 믿지 말고 직접 코드로 독립 확인.
- **RTL 수정 순서: TB(네거티브 컨트롤 포함) → 골든 대조 → 구현.** 이 영역에서 `cc5fa4d`로 되돌린 전례 있음.
- 커밋 메시지는 1~2줄로 짧게. 커밋/푸시는 요청받았을 때만.
- 배포 RBF 이름은 반드시 `MSX1_<YYYYMMDD><letter>_<desc>.rbf`.
- **`FC1` (Load ROM PACK) 절대 손대지 말 것.**
- 사용자의 VHD는 백업 없는 실사용 4.3GB 이미지 — **추가만**, 수정·삭제 금지. 다른 세션에 경로를 알려주지 말고 "p6"라고만 할 것.
- 상용 소프트웨어 파생 파일(SCMD `.DSK`/`.SYS` 등)은 저장소에 커밋하지 않는다.
- Verilator lint는 포트 연결 오류를 못 잡는다. 합성만 잡는다.

먼저 무엇부터 할지 물어봐 줘.

---

## 이 파일 자체에 대한 메모

- 이 파일은 커밋되지 않았다(untracked). 필요하면 커밋할 것.
- 관련 메모리: `project_mfrsd_scc_sound_cartridge.md` (새 세션에서 `MEMORY.md`로 자동 로드됨)
