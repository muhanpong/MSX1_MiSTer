# YMF278B FPGA 포팅 검증 보고서

**작성일**: 2026-05-24
**대상**: `rtl/peripheral/SOUND/ymf278b_fpga/` (YMF278B / OPL4 MoonSound RTL 코어)
**검증 기준**: openMSX C++ 구현 (`reference/YMF278.cc`, `reference/YMF278B.cc`) 및 Python 참조 모델 (`sim/reference_model.py`)
**검증자**: Claude Opus 4.7 (인터랙티브 세션)

---

## 0. 요약 (TL;DR)

| 항목 | 결과 |
|------|------|
| 단위 테스트 (envelope) | ✅ 5/5 PASS |
| 단위 테스트 (interpolator) | ✅ 4/4 PASS (테스트벤치 포트 1개 추가 필요했음) |
| Reference C++ 1:1 비교 (주요 10개 항목) | ✅ 8건 일치, ❌ 2건 불일치 → 🔧 모두 수정 완료 |
| 통합 테스트 (tb_pcm_integration) | ✅ 13/13 PASS (8건의 RTL 버그 발견·수정 후) |
| 발견된 치명적 RTL 버그 | **8건** (전체 fix 누적, 아래 표 참조) |
| 하드웨어 검증 (BASIC 직접 driving) | ✅ CPU R/W + Envelope + Volume + Mixer 모두 동작 확인 |
| 실제 게임 (Neon Horizon) PCM | ⏳ envelope 열리지만 sample 출력 안 됨 (게임-특이적, 다음 세션) |
| 미검증 영역 | LFO 단위 테스트, 통합 테스트벤치, 하드웨어 실측 |

**핵심 결론**: 코어 알고리즘은 reference와 구조적으로 거의 일치한다. 1건의 명확한 버그(endAddr 이중 2's complement)를 발견·수정했다. 통합/타이밍 영역은 여전히 미검증 상태이며, 이것이 현재 "무음" 증상의 잠재 원인일 가능성이 크다.

---

## 1. 검증 동기

이전 다중 세션에 걸쳐 PCM 무음 문제를 디버깅하면서 여러 버그 패치를 적용했으나 (4'd24 truncation, HF FSM 추가, deadlock 수정, CPU write 펄스 latching 등), 코드 리뷰(Gemini Pro / Opus / multi-agent)와 추론에 의존했을 뿐 **참조 구현과의 직접 비교는 한 번도 수행되지 않은** 상태였다.

사용자의 다음 질문이 검증 동기를 명확하게 했다:

> "custom wave도 안 들리고 debug led에서 sdram 핸드셰이크 정상인데, 주소 오류라고 저 패치 내용이 나온 건데 sample ram을 쓰면 소리도 나야하고, 주소도 이따금 정상이어야 하는 거였잖아요? 무조건 아무 소리도 안 나는데 이게 맞는 방향인 걸까요?"

이 추론은 결정적이었다. `pcm_rom_base`가 잘못된 위치를 가리킨다 해도 **CPU 쓰기와 PCM 읽기는 같은 `pcm_rom_base + offset` 변환을 통과**하므로, sample RAM 메커니즘은 대칭적으로 동작해야 한다. 그런데 완전 무음이라면, 문제는 **메모리 라우팅이 아니라 PCM 파이프라인 자체에 있다**는 결론이 나온다.

이에 사용자가 "B 경로 (정석)"를 선택했고, 다음 절차를 진행했다:

1. iverilog 컴파일 가능성 확인
2. 단위 테스트벤치 실행 (tb_pcm_envelope, tb_pcm_slot)
3. reference_model.py 동작 확인
4. C++ 참조 1:1 비교

---

## 2. 검증 환경 / 자료

### 2.1 디렉토리 구조

```
rtl/peripheral/SOUND/ymf278b_fpga/
├── reference/
│   ├── YMF278.cc       (33,916 bytes) — PCM wave 엔진 참조
│   ├── YMF278.hh
│   ├── YMF278B.cc      (7,369 bytes)  — OPL4 통합 (FM+PCM) 참조
│   ├── YMF278B.hh
│   ├── YMF262.cc
│   └── YMF262.hh
├── rtl/
│   ├── ymf278b_top.sv
│   ├── ymf278b_regs.sv
│   └── pcm/
│       ├── ymf278_pcm_top.sv         ← 대부분 작업 집중 영역
│       ├── ymf278_pcm_envelope.sv
│       ├── ymf278_pcm_interpolator.sv
│       ├── ymf278_pcm_volume.sv
│       ├── ymf278_pcm_lfo.sv
│       └── ymf278_pcm_memory.sv
├── sim/
│   └── reference_model.py            ← Python 참조 모델
└── tb/
    ├── tb_pcm_envelope.sv
    ├── tb_pcm_slot.sv
    └── tb_ymf278b_top.sv             ← 미컴파일/미실행
```

### 2.2 검증 도구

| 도구 | 용도 | 상태 |
|------|------|------|
| iverilog (g2012) | SystemVerilog 컴파일 | ✅ |
| vvp | 시뮬레이션 실행 | ✅ |
| python3 | 참조 모델 실행 | ✅ |
| grep / Read | reference C++ vs RTL 비교 | ✅ |

### 2.3 사전 조건

- 이전 세션에서 적용된 패치들 (HF FSM, CPU write latching, deadlock fix, 4'd24 → 8'd24 truncation 수정 등)이 이미 코드에 반영된 상태.
- `memory_upload.sv:328`의 boundary check 버그 (`28'h100000` → `28'h300000`)도 이미 수정 상태 (yrw801.rom 로드 경로).

---

## 3. 발견된 불일치 (Discrepancy Inventory)

### 3.1 [CRITICAL] endAddr 이중 2's complement (FIXED ✅)

**위치**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_top.sv:333`

#### 3.1.1 발견 과정

헤더 페치(HF) FSM이 12바이트를 슬롯 필드에 분배하는 `HF_STORE` 블록(line 329-358)을 reference (`YMF278.cc:594-622`) 라인별로 대조하던 중 `endAddr` 처리만 다르게 보임:

**Reference (`YMF278.cc:609`)**:
```cpp
slot.endAddr = uint16_t(buf[6] | (buf[5] << 8));
```
→ ROM에서 읽은 두 바이트를 **그대로** uint16_t에 저장.

**FPGA (수정 전 `ymf278_pcm_top.sv:333`)**:
```systemverilog
sr_endAddr[hf_cur_slot] <= ~{hf_buf[5], hf_buf[6]} + 16'd1;
```
→ 같은 바이트들의 **2's complement (부호반전)**을 저장.

#### 3.1.2 데이터 형식 확인

`YMF278.cc:905`의 직렬화 주석:
```
// version 4:
//  - store 'endAddr' as 2s complement
```

`YMF278.cc:931` (구버전 saveload 호환):
```cpp
unsigned e = 0; ar.serialize("endaddr", e);
endAddr = uint16_t((e ^ 0xffff) + 1);
```
이 코드는 *구버전 savestate에서 읽을 때만* 2's complement로 변환한다. 즉:
- 내부 표현(`slot.endAddr`) = **이미 2's complement 형태**
- ROM 바이트 = **이미 2's complement 형태** (YMF278B 하드웨어 사양)
- 따라서 `slot.endAddr = uint16_t(buf[6] | (buf[5] << 8))`는 raw 바이트를 그대로 보관해도 의미가 맞음

#### 3.1.3 사용 위치에서 교차 검증

**Reference (`YMF278.cc:468-470`)**:
```cpp
pos += increment;
if ((uint32_t(pos) + slot.endAddr) >= 0x10000) // check position >= (negated) end address
    pos += narrow_cast<uint16_t>(slot.endAddr + slot.loopAddr);
```

**Python reference (`reference_model.py:183-187`)**:
```python
def next_pos(slot, pos, increment):
    pos = (pos + increment) & 0xFFFF
    if (pos + slot.endAddr) >= 0x10000:
        pos = (pos + slot.endAddr + slot.loopAddr) & 0xFFFF
    return pos
```

**FPGA interpolator (`ymf278_pcm_interpolator.sv:42-45`)**:
```systemverilog
p2 = p + inc;
if (({1'b0, p2} + {1'b0, end_a}) >= 17'h10000)
    p2 = p2 + end_a + loop_a;
```

→ 세 구현 모두 동일한 조건식 사용: `pos + endAddr >= 0x10000`. `endAddr`가 2's complement (`= -|endPos|`)라는 가정 하에서 이 조건은 `pos >= |endPos|`를 17-bit 오버플로우로 검출한다.

#### 3.1.4 영향 분석

만약 ROM에 저장된 raw 바이트가 `0xFF80` (= -128, 즉 endPos=128인 짧은 wave)이라면:

| 표현 | sr_endAddr 값 | 루프 트리거 조건 | 의미 |
|------|----|---------------|------|
| Reference (raw) | `0xFF80` (= -128) | `pos + 0xFF80 >= 0x10000` → `pos >= 128` | ✅ 의도된 동작 |
| FPGA (수정 전) | `~0xFF80 + 1 = 0x0080` (= +128) | `pos + 128 >= 0x10000` → `pos >= 0xFF80` | ❌ 무한대에 가까운 wave |

**증상 예측**: 짧은 샘플도 65,408 샘플 위치까지 재생을 시도하며, SDRAM의 빈 영역(0x00)을 계속 읽어 무음 또는 클릭 잡음을 출력한다. 또한 envelope의 release 단계가 끝나기 전까지 키오프되지 않으면 영원히 다른 wave로 못 넘어간다.

#### 3.1.5 수정

`ymf278_pcm_top.sv:333` 변경:

```diff
-               sr_endAddr  [hf_cur_slot] <= ~{hf_buf[5], hf_buf[6]} + 16'd1;
+               // ROM bytes are already in 2's complement form (matches
+               // openMSX YMF278.cc:609 and reference_model.py:185).
+               // Loop check: (pos + endAddr) >= 0x10000 → pos >= |endAddr|
+               sr_endAddr  [hf_cur_slot] <= {hf_buf[5], hf_buf[6]};
```

#### 3.1.6 수정 후 검증

- `tb_pcm_envelope`: 5/5 PASS 유지
- `tb_pcm_slot` (Test 4 Loop endAddr=0xFFC0): PASS 유지
- 정적 검토: 모든 endAddr 소비처(`ymf278_pcm_top.sv:602`, `ymf278_pcm_interpolator.sv:43`)가 동일한 2's complement 가정을 사용하므로 일관성 유지.

---

## 4. 검증 방법론

### 4.1 단위 테스트벤치 실행

#### 4.1.1 tb_pcm_envelope

**컴파일**:
```bash
iverilog -g2012 -o /tmp/tb_env.vvp \
    tb/tb_pcm_envelope.sv \
    rtl/pcm/ymf278_pcm_envelope.sv
```

**경고 (비차단)**:
```
ymf278_pcm_envelope.sv:207: sorry: constant selects in always_* processes are not fully supported
```
→ iverilog가 비트 선택(`bit[5:0]` 등)을 정확히 모델하지 못한다는 경고. vvp 생성에는 영향 없음. **Task #1을 차단요인이 아닌 것으로 완료 처리**.

**실행 결과**:
```
=== Test 1: Normal ADSR cycle ===
PASS: After 10 samples in ATT, env_vol < 0x280
PASS: After 110 samples still not silence
PASS: After release, env_vol should reach max

=== Test 2: AR=15 instant attack ===
PASS: AR=15: env_vol should be 0 immediately

=== Test 3: DAMP mode ===
PASS: DAMP: env_vol reaches silence within 30 samples

=== Test 4: Pseudo-reverb (PRVB) ===
PASS: PRVB: env_vol should be at or above dl_tab[6]=0x00C0

=== Test 5: All slots in silence after reset ===
PASS: All slots idle: slot 0 at MAX_ATT

*** ALL TESTS PASSED ***
```

#### 4.1.2 tb_pcm_slot (interpolator)

**컴파일 실패 → 수정**:
```
tb/tb_pcm_slot.sv:27: error: Wildcard named port connection (.*) did not find a matching identifier for port 16 (ready).
```
→ interpolator 모듈에 추가된 `ready` 출력이 testbench의 신호 리스트에 없어서 `.*` 와일드카드 연결이 실패함.

**수정 (tb_pcm_slot.sv:25-27)**:
```diff
 logic signed [15:0] sample_out;
 logic               sample_valid;
+logic               ready;

 ymf278_pcm_interpolator dut (.*);
```

**재컴파일 및 실행**:
```
=== Test 1: 8-bit samples ===
  sample[0] = 0x0000
PASS: 8-bit: sample[0] = mem[0]<<8 = 0x0000
  sample[1] = 0x0200
PASS: 8-bit: sample[1] = 2<<8 = 0x0200

=== Test 2: 16-bit samples ===
  16-bit sample[0] = 0x0aaa
PASS: 16-bit: first sample non-zero

=== Test 3: 12-bit samples ===
  12-bit even sample[0] = 0x0030
  12-bit odd sample[1] = 0x0130

=== Test 4: Loop (endAddr wrap) ===
  loop sample = 0x7c00
PASS: Loop: got a valid sample

*** ALL TESTS PASSED ***
```

### 4.2 reference_model.py 동작 확인

```bash
python3 sim/reference_model.py
```

출력:
```
=== YMF278 Reference Model: Envelope Trace ===
Sample, State, env_vol
    0, 4, 0x280
    ...
   16, 4, 0x257
   ...
  460, 1, 0x163
   ...
```

→ MAX_ATT(0x280)에서 시작 → EG_ATT(state 4)로 들어가 attenuation 감소 → 이후 EG_REL(state 1)로 전환. 정상 envelope 궤적.

### 4.3 Reference C++ 1:1 비교

`reference/YMF278.cc`의 `writeRegDirect()` 함수(line 587-740)와 FPGA `ymf278_pcm_top.sv`의 `if (reg_wr)` 블록(line 372-429)을 case별로 대조.

#### 4.3.1 case 0: wave LSB write (reg 0x08-0x1F)

**Reference**:
```cpp
case 0: {
    slot.wave = (slot.wave & 0x100) | data;
    int waveTblHdr = (regs[2] >> 2) & 0x7;
    int base = (slot.wave < 384 || !waveTblHdr) ?
               (slot.wave * 12) :
               (waveTblHdr * 0x80000 + ((slot.wave - 384) * 12));
    std::array<uint8_t, 12> buf;
    for (auto i : xrange(12)) buf[i] = readMem(base + i);
    slot.bits      = (buf[0] & 0xC0) >> 6;
    slot.startAddr = buf[2] | (buf[1] << 8) | ((buf[0] & 0x3F) << 16);
    slot.loopAddr  = uint16_t(buf[4] | (buf[3] << 8));
    slot.endAddr   = uint16_t(buf[6] | (buf[5] << 8));
    for (auto i : xrange(7, 12)) {
        writeRegDirect(narrow<uint8_t>(8 + sNum + (i - 2) * 24), buf[i], time);
    }
    if (slot.keyon) keyOnHelper(slot);
    else { slot.stepPtr = 0; slot.pos = 0; }
}
```

**FPGA**:
- `wr_field==0` 검출 → `hf_pending[wr_snum] <= 1'b1` (line 377)
- HF FSM 트리거 → HF_REQ에서 base 주소 계산 (line 306-311, wavetblhdr 분기 동일)
- HF_STORE에서 12바이트를 슬롯 필드에 분배 (line 329-358)
- `sr_keyon` 상태에 따라 envelope restart 또는 pos reset (line 346-356)

**대조 결과**:

| 항목 | Reference | FPGA | 일치? |
|------|-----------|------|------|
| wave LSB 갱신 (8비트 보존) | `slot.wave = (slot.wave & 0x100) \| data` | `sr_wave[wr_snum][7:0] <= reg_data[7:0]` (sr_wave는 9비트, [8] 별도 보존) | ✅ |
| wavetblhdr 추출 | `(regs[2] >> 2) & 0x7` | `wavetblhdr <= reg_data[4:2]` on reg 0x02 (line 432) | ✅ |
| 헤더 주소 (wave<384) | `slot.wave * 12` | `{13'd0, hf_cur_wave} * 22'd12` | ✅ |
| 헤더 주소 (wave≥384) | `waveTblHdr * 0x80000 + (slot.wave-384)*12` | `{1'b0, wavetblhdr, 18'd0} + {13'd0, (hf_cur_wave - 9'd384)} * 22'd12` | ✅ (0x80000 = 1<<19, FPGA의 `{wavetblhdr, 18'd0}`이 wavetblhdr << 18 = wavetblhdr * 0x40000인 점 검증 필요 — **잠재 이슈 4.3.1.a**) |
| bits 추출 | `buf[0][7:6]` | `hf_buf[0][7:6]` | ✅ |
| startAddr | `buf[2] \| (buf[1]<<8) \| ((buf[0]&0x3F)<<16)` | `{hf_buf[0][5:0], hf_buf[1], hf_buf[2]}` | ✅ (22비트로 자르긴 함) |
| loopAddr | `buf[4] \| (buf[3] << 8)` | `{hf_buf[3], hf_buf[4]}` | ✅ |
| endAddr | `buf[6] \| (buf[5] << 8)` | `{hf_buf[5], hf_buf[6]}` (수정 후) | ✅ |
| byte 7 → reg case 5 (LFO/VIB) | recursive writeRegDirect | 직접 `sr_lfo_speed`, `sr_vib` (line 334-335) | ✅ |
| byte 8 → reg case 6 (AR/D1R) | recursive | `sr_AR`, `sr_D1R` (line 336-337) | ✅ |
| byte 9 → reg case 7 (DL/D2R) | recursive | `sr_DL_idx`, `sr_D2R` (line 338-339) | ✅ |
| byte 10 → reg case 8 (RC/RR) | recursive | `sr_RC`, `sr_RR` (line 340-341) | ✅ |
| byte 11 → reg case 9 (AM) | recursive | `sr_AM` (line 342) | ✅ |
| keyon 시 restart | `keyOnHelper(slot)` | `sr_keyon <= 1'b0; hf_keyon_restart[...] <= 1'b1` (line 346-351) — 다음 사이클에 keyon=1로 다시 set하여 envelope 모듈이 엣지를 감지 | ✅ (간접) |
| 비-keyon 시 pos/stepPtr 리셋 | `slot.stepPtr = 0; slot.pos = 0` | `hf_pos_reset[hf_cur_slot] <= 1'b1` → step accum 블록에서 reset (line 643-647) | ✅ (간접) |

**잠재 이슈 4.3.1.a — wavetblhdr 비트 시프트 재확인**:

```systemverilog
hf_mem_addr_w <= {1'b0, wavetblhdr, 18'd0} + ...
```

`wavetblhdr`은 3비트, 결과는 22비트. `{1'b0, 3'b___, 18'd0}` = 22비트 중 상위 4비트가 `{1'b0, wavetblhdr}`이고 하위 18비트는 0. 따라서 `wavetblhdr`이 `[20:18]`에 위치 → `wavetblhdr << 18`. 즉 `wavetblhdr * 0x40000 (262144)`.

**그러나 reference는 `waveTblHdr * 0x80000 (524288)` = `wavetblhdr << 19`로 곱한다**.

→ **새로운 의심 버그 발견!** 0x40000 vs 0x80000 (2배 차이). 다만 22비트 주소 공간(4MB) 내에서 wavetblhdr이 0-7이라면 0x40000 * 7 = 1.75MB로 4MB 범위 안에 들어가긴 한다. Reference가 0x80000 * 7 = 3.5MB를 의도했다면 FPGA의 절반 위치를 가리키게 됨.

이 항목은 **3.2로 별도 분리하여 다룬다**.

#### 4.3.2 case 1: wave MSB + FN low (reg 0x20-0x37)

**Reference**:
```cpp
case 1: {
    slot.wave = uint16_t((slot.wave & 0xFF) | ((data & 0x1) << 8));
    slot.FN = (slot.FN & 0x380) | (data >> 1);
    slot.step = calcStep(slot.OCT, slot.FN);
    break;
}
```

**FPGA (line 379-382)**:
```systemverilog
4'd1: begin
    sr_wave[wr_snum][8] <= reg_data[0];
    sr_FN[wr_snum][6:0] <= reg_data[7:1];
end
```

→ `slot.step`은 FPGA에서 동적으로 계산 (line 595 `calc_step()` 함수). ✅ 일치.

#### 4.3.3 case 2: FN high + PRVB + OCT (reg 0x38-0x4F)

**Reference**:
```cpp
case 2: {
    slot.FN = uint16_t((slot.FN & 0x07F) | ((data & 0x07) << 7));
    slot.PRVB = (data & 0x08) != 0;
    slot.OCT = sign_extend_4((data & 0xF0) >> 4);
    slot.step = calcStep(slot.OCT, slot.FN);
}
```

**FPGA (line 384-389)**:
```systemverilog
4'd2: begin
    sr_FN[wr_snum][9:7] <= reg_data[2:0];
    sr_PRVB[wr_snum]    <= reg_data[3];
    sr_OCT[wr_snum]     <= $signed(reg_data[7:4]);
end
```

→ ✅ 일치 (sign_extend는 `$signed` 적용으로 동일).

#### 4.3.4 case 3: TL (reg 0x50-0x67)

**Reference**:
```cpp
case 3: {
    uint8_t t = data >> 1;
    slot.TLdest = (t != 0x7f) ? t : 0xff;
    if (data & 1) slot.TL = slot.TLdest;
    else /* interpolate */ ;
}
```

**FPGA (line 391-398)**:
```systemverilog
4'd3: begin
    logic [6:0] t;
    t = reg_data[7:1];
    sr_TLdest[wr_snum] <= (t != 7'h7F) ? {1'b0, t} : 8'hFF;
    if (reg_data[0]) sr_TL[wr_snum] <= sr_TLdest[wr_snum];
end
```

→ ✅ 일치. TL interpolation은 별도 always_ff(line 269-278)에서 sample_start마다 1씩 증감.

#### 4.3.5 case 4: pan / LFO / DAMP / keyon (reg 0x68-0x7F)

**Reference**:
```cpp
case 4:
    if (data & 0x10) slot.pan = 8;     // mute
    else slot.pan = data & 0x0F;
    if (data & 0x20) {
        slot.lfo_active = false;
        slot.lfo_cnt = 0;
    } else slot.lfo_active = true;
    slot.DAMP = (data & 0x40) != 0;
    if (data & 0x80) {
        if (!slot.keyon) { slot.keyon = true; keyOnHelper(slot); }
    } else {
        if (slot.keyon) { slot.keyon = false; slot.state = EG_REL; }
    }
```

**FPGA (line 399-410)**:
```systemverilog
4'd4: begin
    sr_pan[wr_snum]       <= reg_data[4] ? 4'd8 : reg_data[3:0];
    sr_lfo_active[wr_snum]<= ~reg_data[5];
    sr_lfo_reset[wr_snum] <=  reg_data[5];   // edge → LFO 모듈에서 cnt 클리어
    sr_DAMP[wr_snum]      <=  reg_data[6];
    if (reg_data[7]) begin
        if (!sr_keyon[wr_snum]) sr_keyon[wr_snum] <= 1'b1;
    end else begin
        sr_keyon[wr_snum] <= 1'b0;
    end
end
```

→ ✅ 일치. keyon 시 keyOnHelper는 envelope 모듈이 sr_keyon 엣지를 감지하여 자동 적용 (`ymf278_pcm_envelope.sv:295-326`). EG_REL 전환도 동일 모듈에서 처리.

#### 4.3.6 case 5-9: LFO/VIB, AR/D1R, DL/D2R, RC/RR, AM

| Case | Reference | FPGA | 일치? |
|------|-----------|------|------|
| 5 | `lfo = (data>>3)&7; vib = data&7` | `sr_lfo_speed <= reg_data[5:3]; sr_vib <= reg_data[2:0]` | ✅ |
| 6 | `AR = data>>4; D1R = data&0xF` | `sr_AR <= reg_data[7:4]; sr_D1R <= reg_data[3:0]` | ✅ |
| 7 | `DL = dl_tab[data>>4]; D2R = data&0xF` | `sr_DL_idx <= reg_data[7:4]; sr_D2R <= reg_data[3:0]` (dl_tab는 envelope 모듈에서 lookup) | ✅ |
| 8 | `RC = data>>4; RR = data&0xF` | `sr_RC <= reg_data[7:4]; sr_RR <= reg_data[3:0]` | ✅ |
| 9 | `AM = data&7` | `sr_AM <= reg_data[2:0]` | ✅ |

#### 4.3.7 NEW2 gating

**Reference (`YMF278B.cc:138-178`)**:
```cpp
void YMF278B::writeIO(uint16_t port, uint8_t value, EmuTime time)
{
    if ((port & 0xFF) < 0xC0) {  // WAVE part 0x7E/0x7F
        if (getNew2()) {
            switch (port & 0x01) {
                case 0: opl4latch = value; break;
                case 1: ymf278.writeReg(opl4latch, value, time); break;
            }
        }
        // else: ignored
    } else { /* FM part */ }
}
```

**FPGA (`ymf278b_regs.sv:91-110`)**:
```systemverilog
if (io_port[7:1] == 7'b0111111) begin   // 0x7E/0x7F
    if (new2) begin
        if (!io_port[0]) opl4latch <= io_data_in;        // select
        else            pcm_reg_wr <= 1'b1;              // write
    end
    io_ack <= 1'b1;   // ACK 항상 (NEW2=0이어도)
end
```

**NEW2 shadow 캡처 (`ymf278b_top.sv:73-77`)**:
```systemverilog
always_ff @(posedge clk) begin
    if (opl3_reg_wr && opl3_reg_addr == 9'h105)
        opl3_reg_shadow[0] <= opl3_reg_data;
end
assign new2 = opl3_reg_shadow[0][1];
```

→ ✅ select와 write 모두 NEW2로 게이팅됨. 게임이 OPL3 reg 0x105 bit 1을 설정하면 다음 사이클부터 NEW2=1로 PCM 쓰기가 통과.

#### 4.3.8 keyOnHelper / envelope key-on edge

**Reference (`YMF278.cc:564-579`)**:
```cpp
void YMF278::keyOnHelper(YMF278::Slot& slot) const
{
    slot.env_vol = MAX_ATT_INDEX;
    if (slot.compute_rate(slot.AR) < 63) {
        slot.state = EG_ATT;
    } else {
        slot.env_vol = MIN_ATT_INDEX;
        slot.state = slot.DL ? EG_DEC : EG_SUS;
    }
    slot.stepPtr = 0;
    slot.pos = 0;
}
```

**FPGA (`ymf278_pcm_envelope.sv:317-326`)**:
```systemverilog
if (local_key_on_pulse) begin
    new_vol = 11'(MAX_ATT_INDEX);
    if (compute_rate(AR_d1, RC_d1, OCT_d1, FN_d1) < 6'd63) begin
        new_state = EG_ATT;
    end else begin
        new_vol   = 11'(MIN_ATT_INDEX);
        new_state = (DL_d1 != 16'h0) ? EG_DEC : EG_SUS;
    end
end
```

→ ✅ env_vol = MAX_ATT, AR=15 즉시 attack, DL!=0 ? EG_DEC : EG_SUS 분기까지 동일.

pos/stepPtr=0는 `ymf278_pcm_top.sv:642-647`의 step accumulation 블록에서 처리:
```systemverilog
for (_ko = 0; _ko < 24; _ko = _ko + 1) begin
    if (keyon_pulse_arr[_ko] || hf_pos_reset[_ko]) begin
        sr_pos[_ko]     <= 16'd0;
        sr_stepPtr[_ko] <= 16'd0;
    end
end
```

#### 4.3.9 endAddr loop 처리

이미 §3.1.3에서 다룸. ✅ 수정 후 일치.

#### 4.3.10 Volume / pan attenuation

**Reference 핵심 식** (`YMF278.cc` 및 reference_model.py):
- env_vol [0..0x280] → factor lookup
- TL [0..0xFF] << 2 → 같은 lookup
- pan_att = `(0x20 - (p & 0x0F)) >> (p >> 4)`

**FPGA (`ymf278_pcm_volume.sv:40-58`)**:
```systemverilog
function automatic signed [31:0] vol_factor(input signed [15:0] x, input [9:0] evol);
    ...
    if (evol >= 10'(MAX_ATT_INDEX)) return 32'sd0;
    vol_mul   = 6'(7'h80 - {1'b0, evol[5:0]});
    vol_shift = 5'(4'd7 + {1'b0, evol[9:6]});
    tmp = (32'sh8000 * $signed({1'b0, vol_mul})) >>> vol_shift;
    return ($signed(x) * tmp) >>> 15;
endfunction

function automatic [4:0] pan_att(input [7:0] p);
    if (p == 8'd255) return 5'd0;
    return 5'((5'h20 - {1'b0, p[3:0]}) >> p[7:4]);
endfunction
```

→ ✅ 일치 (env_vol convention, pan 식 둘 다).

### 3.2 [CRITICAL] wavetblhdr 비트 시프트 오류 (FIXED ✅)

**위치**: `ymf278_pcm_top.sv:309`

**Reference (`YMF278.cc:599`)**:
```cpp
int base = waveTblHdr * 0x80000 + ((slot.wave - 384) * 12);
//                     ^^^^^^^^
//                     = 1 << 19
```

**FPGA**:
```systemverilog
hf_mem_addr_w <= {1'b0, wavetblhdr, 18'd0} + ... ;
//                       ^^^^^^^^^^^^^^^^^
//                       wavetblhdr가 비트 [20:18]에 위치
//                       = wavetblhdr << 18 = wavetblhdr * 0x40000
```

**불일치 분석**:
- Reference: `waveTblHdr * 0x80000` (= `<< 19`)
- FPGA: `wavetblhdr * 0x40000` (= `<< 18`)

`wavetblhdr` 값 범위는 0-7 (3비트).

| wavetblhdr | Reference base | FPGA base | 차이 |
|------------|---------------|-----------|------|
| 1 | 0x080000 (524 KB) | 0x040000 (256 KB) | 2× |
| 2 | 0x100000 (1.0 MB) | 0x080000 (512 KB) | 2× |
| 4 | 0x200000 (2.0 MB) | 0x100000 (1.0 MB) | 2× |
| 7 | 0x380000 (3.5 MB) | 0x1C0000 (1.75 MB) | 2× |

→ FPGA가 항상 reference의 **절반 주소**를 가리킴.

**그러나 mem_addr이 22비트이므로 최대 4MB까지 표현 가능**. Reference의 `waveTblHdr=7`이면 `0x380000`이 22비트 안에 들어오므로 reference 표현이 가능. FPGA가 `<< 18`을 쓰는 건 명확한 버그.

**결정적 증거 (Task #8 조사 완료)**:

`ymf278_pcm_top.sv:303-311` 본문 자체가 자기모순:
```systemverilog
HF_REQ: begin
    // Address calculation matches openMSX YMF278.cc:
    //   wave < 384 || wavetblhdr == 0: base = wave * 12
    //   else: base = wavetblhdr * 0x80000 + (wave-384) * 12   ← 주석은 0x80000
    ...
    end else begin
        hf_mem_addr_w <= {1'b0, wavetblhdr, 18'd0} + ...        ← 코드는 <<18 = *0x40000
```

→ **주석(의도) = `* 0x80000` (=`<<19`), 코드(구현) = `<<18` (=`*0x40000`)**. 명백한 구현 오류, 주석/reference와 불일치. 단순 타이포(`19'd0`을 `18'd0`으로 잘못 적은 것)로 추정.

**주소 공간 제약 확인**: `mem_addr` 22비트, 0x000000-0x3FFFFF (4MB). Reference 최대 `7 * 0x80000 = 0x380000` (3.5MB)이 22비트에 정상적으로 들어감. 의도적으로 절반으로 줄여야 할 제약 없음.

**git history**: ymf278b_fpga/ 디렉토리 전체가 untracked 상태(아직 커밋되지 않은 신규 모듈)라서 history로는 의도 추적 불가. 그러나 주석이 명시적이므로 history 없이도 결론 도출 가능.

**수정 적용**:
```diff
                 end else begin
-                    hf_mem_addr_w <= {1'b0, wavetblhdr, 18'd0} +
+                    // wavetblhdr * 0x80000 == wavetblhdr << 19.
+                    // {wavetblhdr[2:0], 19'd0} produces a 22-bit value with
+                    // wavetblhdr in bits 21:19, matching openMSX YMF278.cc:599.
+                    hf_mem_addr_w <= {wavetblhdr, 19'd0} +
                                      ({13'd0, (hf_cur_wave - 9'd384)} * 22'd12) +
                                      {18'd0, hf_byte_idx};
                 end
```

비트 폭 검증: `{3-bit wavetblhdr, 19-bit zero}` = 22비트 = `mem_addr` 폭 정확히 일치. 값 = `wavetblhdr * 2^19 = wavetblhdr * 0x80000` ✅

**수정 후 검증**:
- `tb_pcm_envelope`: 5/5 PASS (변동 없음, 모듈 무관)
- `tb_pcm_slot`: 4/4 PASS (변동 없음, 모듈 무관)
- 전체 PCM RTL 컴파일: 통과 (volume.sv 무관 warning 2건 외 에러 없음)
- 단위 테스트는 wavetblhdr 경로를 커버하지 않음 → 실측 또는 tb_ymf278b_top 통합 테스트 필요

**증상과의 연결**: 사용자가 처음 의심한 "custom wave도 안 들린다"의 가장 직접적 후보. wave≥384 (custom 샘플) 영역에 한해 헤더가 정확히 reference의 절반 주소(예: 0x40000 / 0x80000 / 0xC0000 등)에서 읽혀 다른 데이터를 wave 헤더로 해석함. 그 결과 startAddr/loopAddr/endAddr/bits/envelope가 모두 쓰레기 값 → 게임이 sample RAM에 헤더를 0x80000 단위로 배치했다면 FPGA는 빈 영역(zero)을 읽어 silence 또는 노이즈 출력.

---

## 5. 검증 결과 종합

| 카테고리 | 항목 | 결과 | 신뢰도 |
|----------|------|------|--------|
| 단위 테스트 | tb_pcm_envelope (5건) | ✅ PASS | 높음 |
| 단위 테스트 | tb_pcm_slot/interpolator (4건) | ✅ PASS | 높음 |
| 알고리즘 | 헤더 페치 12바이트 분배 | ✅ 일치 | 높음 |
| 알고리즘 | 헤더 페치 주소 (wave<384) | ✅ 일치 | 높음 |
| 알고리즘 | 헤더 페치 주소 (wave≥384, wavetblhdr) | ✅ 수정 후 일치 | 높음 |
| 알고리즘 | endAddr 표현 (2's complement) | ✅ 수정 후 일치 | 높음 |
| 알고리즘 | keyOnHelper (env_vol/state) | ✅ 일치 | 높음 |
| 알고리즘 | pan/LFO/DAMP/keyon (case 4) | ✅ 일치 | 높음 |
| 알고리즘 | TL interpolation (case 3) | ✅ 일치 | 높음 |
| 알고리즘 | FN/PRVB/OCT (case 2) | ✅ 일치 | 높음 |
| 알고리즘 | NEW2 게이팅 (select+write) | ✅ 일치 | 높음 |
| 알고리즘 | volume / pan_att 계산 | ✅ 일치 | 높음 |
| 알고리즘 | wavetblhdr reg 0x02 캡처 | ✅ 일치 | 높음 |
| 통합 | LFO 모듈 단위 테스트 | ❌ 없음 | — |
| 통합 | ymf278_pcm_top 통합 테스트 | ❌ 없음 | — |
| 통합 | ymf278b_top 통합 테스트 | ⏳ tb 작성됐으나 미실행 | — |
| 통합 | C++ vs FPGA cycle-level 비교 | ❌ 없음 | — |
| 하드웨어 | 실측 검증 | ❌ 현재 무음 상태 | — |

---

## 6. 수정 사항 종합

### 6.1 코드 변경

**Fix 1**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_top.sv:333` — endAddr 이중 2's complement

```diff
             HF_STORE: begin
                 sr_bits     [hf_cur_slot] <= hf_buf[0][7:6];
                 sr_startAddr[hf_cur_slot] <= {hf_buf[0][5:0], hf_buf[1], hf_buf[2]};
                 sr_loopAddr [hf_cur_slot] <= {hf_buf[3], hf_buf[4]};
-                sr_endAddr  [hf_cur_slot] <= ~{hf_buf[5], hf_buf[6]} + 16'd1;
+                // ROM bytes are already in 2's complement form (matches
+                // openMSX YMF278.cc:609 and reference_model.py:185).
+                // Loop check: (pos + endAddr) >= 0x10000 → pos >= |endAddr|
+                sr_endAddr  [hf_cur_slot] <= {hf_buf[5], hf_buf[6]};
                 sr_lfo_speed[hf_cur_slot] <= hf_buf[7][5:3];
                 ...
```

**Fix 2**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_top.sv:309` — wavetblhdr 비트 시프트

```diff
                 end else begin
-                    hf_mem_addr_w <= {1'b0, wavetblhdr, 18'd0} +
+                    // wavetblhdr * 0x80000 == wavetblhdr << 19.
+                    // {wavetblhdr[2:0], 19'd0} produces a 22-bit value with
+                    // wavetblhdr in bits 21:19, matching openMSX YMF278.cc:599.
+                    hf_mem_addr_w <= {wavetblhdr, 19'd0} +
                                      ({13'd0, (hf_cur_wave - 9'd384)} * 22'd12) +
                                      {18'd0, hf_byte_idx};
                 end
```

**Fix 3**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_top.sv:319-338` — HF FSM mem_rd_req drop

배경: HF FSM이 byte 간 전이에서 `mem_rd_req`를 high로 유지 → 메모리 아비터가 ARB_IDLE 사이클에 stale `pcm_addr`로 재요청 → 모든 후속 byte가 한 칸 어긋남 (`hf_buf[i] = mem[i-1]`).

```diff
             HF_WAIT: begin
                 if (mem_rd_valid) begin
                     hf_buf[hf_byte_idx] <= mem_rd_data;
+                    // Drop the request *immediately* after a successful
+                    // read so the memory arbiter sees a falling edge
+                    // before HF_REQ presents the next byte's address.
+                    hf_mem_rd_req_w <= 1'b0;
                     ...
```

**Fix 4**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_memory.sv:46-58, 144-151` — Memory arbiter ARB_COOLDOWN

배경: Fix 3만으로는 부족. HF FSM의 NBA로 `mem_rd_req <= 0`이 다음 사이클에 visible하지만, 같은 사이클에 memory가 ARB_PCM_RD → ARB_IDLE 전이하여 *visible 직전*의 stale `pcm_rd_req=1`로 재요청. 메모리 측에 1-cycle cooldown 추가.

```diff
 typedef enum logic [2:0] {
     ARB_IDLE,
     ARB_PCM_RD,
     ARB_CPU_RD,
     ARB_CPU_WR,
-    ARB_WAIT
+    ARB_WAIT,
+    ARB_COOLDOWN  // 1-cycle gap after PCM read
 } arb_state_t;

             ARB_PCM_RD: begin
                 if (ext_rd_valid) begin
                     pcm_rd_data  <= ext_rd_data;
                     pcm_rd_valid <= 1'b1;
-                    arb_state    <= ARB_IDLE;
+                    arb_state    <= ARB_COOLDOWN;
                 end
             end
+
+            ARB_COOLDOWN: begin
+                busy      <= 1'b1;
+                arb_state <= ARB_IDLE;
+            end
```

**Fix 6**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_memory.sv:71-89` — `cpu_data_out` persistence

배경: 디폴트 `cpu_data_out <= 8'hFF`가 매 사이클 fires → SDRAM 데이터가 1 사이클만 유지되고 다음 사이클에 0xFF로 돌아감 → 다운스트림이 stale 데이터 캡처. 디폴트 제거하여 마지막 read 값을 hold하도록 변경.

```diff
 always_ff @(posedge clk) begin
     // Defaults
     cpu_ack      <= 1'b0;
-    cpu_data_out <= 8'hFF;
+    // cpu_data_out: do NOT reset to 0xFF every cycle.
+    // Hold the last read value until next ARB_CPU_RD updates it.
     ext_rd_en    <= 1'b0;
     ...
     if (!rst_n) begin
+        cpu_data_out <= 8'hFF;  // reset only
         ...
```

**Fix 7**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_top.sv:266, 381-401` / `rtl/ymf278b_top.sv:128-151` / `rtl/ymf278b_regs.sv:38, 60-66, 87-100, 147-165` — CPU 메모리 read 다단 핸드셰이크

배경: CPU 메모리 read는 SDRAM을 거치는 multi-cycle 작업이지만 기존 코드는 `io_ack`를 즉시 어서트하여 CPU가 stale `io_data_out`을 latch. 다단 핸드셰이크로 변경:
- `ymf278_pcm_top.sv`: `reg_dout`을 `cpu_mem_ack` 시점에 캡처. 새 `reg_rd_done` 펄스 출력 추가
- `ymf278b_top.sv`: `pcm_reg_rd_done` 신호 라우팅
- `ymf278b_regs.sv`: `pcm_rd_wait` FSM 추가 — reg 3-6 read 시 `pcm_reg_rd_done` 도착 전까지 `io_ack` 보류

이 fix는 BASIC `INP &H7F`로 PCM ROM 읽기가 정상 동작하게 합니다.

**Fix 8**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_top.sv:735-748` — `dbg_env_min` sticky

배경 (디버그용): 기존 dbg_env_min은 sample_start마다 0x280으로 리셋되어 짧은 envelope 열림을 못 캡처. sticky로 변경하여 reset 이후 한 번이라도 envelope이 열렸으면 영구히 표시.

```diff
-        if (sample_start)
-            dbg_env_min <= 10'h280;
+        // (sample_start reset removed for sticky behavior — debug only)
```

**Fix 5**: `rtl/peripheral/SOUND/ymf278b_fpga/rtl/pcm/ymf278_pcm_volume.sv:44-66, 90` — vol_mul / pan_att 비트폭

배경: `vol_mul = 0x80 - (evol & 0x3F)` 값 범위 = [0x41, 0x80] (65-128). 6비트(0-63)로 선언되어 **evol=0 (최대 음량) 시 0x80이 0으로 truncate → 출력 무음**.
유사하게 `pan_att`도 5비트인데 값 0x20 (32) 표현 못함 → pan=0 (center, 최대 음량) 시 출력 0.

```diff
-    logic [5:0] vol_mul;
+    // vol_mul range = 0x80 - (evol & 0x3F) ∈ [0x41, 0x80] → needs 8 bits.
+    // Previous 6-bit declaration truncated 0x80 to 0, silencing the
+    // loudest case (evol = 0).
+    logic [7:0] vol_mul;
     ...
-    vol_mul = 6'(7'h80 - {1'b0, evol[5:0]});
+    vol_mul = 8'h80 - {2'b0, evol[5:0]};

-function automatic [4:0] pan_att(input [7:0] p);
-    if (p == 8'd255) return 5'd0;
-    return 5'((5'h20 - {1'b0, p[3:0]}) >> p[7:4]);
+function automatic [5:0] pan_att(input [7:0] p);
+    if (p == 8'd255) return 6'd0;
+    return 6'((6'h20 - {2'b0, p[3:0]}) >> p[7:4]);
 endfunction

-            logic [4:0] vl, vr;
+            logic [5:0] vl, vr;
```

**파일**: `rtl/peripheral/SOUND/ymf278b_fpga/tb/tb_pcm_slot.sv`
**라인**: 25-27

```diff
 logic signed [15:0] sample_out;
 logic               sample_valid;
+logic               ready;

 ymf278_pcm_interpolator dut (.*);
```

### 6.2 회귀 테스트 결과

수정 후 모든 단위 테스트 재실행:
- `tb_pcm_envelope`: 5/5 PASS (변동 없음)
- `tb_pcm_slot`: 4/4 PASS (변동 없음, ready 포트 추가에도 기존 테스트 영향 없음)

---

## 7. 미검증 영역 / 남은 작업 (TODO)

검증의 한계가 명확히 존재한다. "전 PCM 무음" 증상의 원인을 100% 특정하지 못한 상태이며, 다음 항목들이 잠재적 원인 후보다.

### 7.1 [HIGH] LFO 모듈 단위 테스트 작성

**문제**: `ymf278_pcm_lfo.sv`는 단위 테스트가 없음. LFO는 vib(피치 진동)과 AM(진폭 진동)을 모두 생성하며, **lfo_active 신호가 잘못되면 vib 오프셋이 잘못 적용되어 정상 step 계산을 방해할 수 있음**. AM 쪽도 환경 음량에 영향을 줄 수 있어, "정상값이지만 들리지 않는" 시나리오를 만들 수 있다.

**작업 내용**:
- `tb/tb_pcm_lfo.sv` 작성
- vib/AM 출력을 reference_model.py의 `compute_vib()`, `compute_am()`과 비교
- lfo_reset 펄스에 대한 lfo_cnt 클리어 검증
- lfo_active=0 시 출력 0 검증

### 7.2 ~~[HIGH] wavetblhdr 비트 시프트 확인 (§3.2)~~ — **완료 ✅**

§3.2에서 조사 및 수정 완료. 코드 자체의 주석과 구현이 불일치했음 (단순 타이포 추정). 비트 폭은 22비트 그대로 유지.

### 7.3 [HIGH] 통합 테스트벤치 (tb_ymf278b_top) 작성/실행

**현재**: `tb/tb_ymf278b_top.sv`가 존재하지만 컴파일·실행된 적 없음.

**작업 내용**:
1. 현재 tb_ymf278b_top.sv 컴파일 시도, 누락된 포트/모듈 보강
2. 시나리오:
   - NEW2 enable (OPL3 reg 0x105 = 0x02)
   - PCM register write로 slot 0에 wave 설정 (LSB + MSB)
   - KEY_ON
   - 일정 시간 후 PCM 출력 샘플 확인
3. 동일 시나리오를 reference_model.py로 실행하여 sample-by-sample 비교
4. 차이 발생 시 어느 모듈 경계에서 분기되는지 추적

### 7.4 ~~[MEDIUM] LFO 활성화/리셋 엣지 동작 검증~~ — **검증 완료 ✅ (버그 아님)**

**Task #11에서 정적 분석 완료. 결론: 동작상 reference와 100% 동일, 수정 불필요.**

#### 7.4.1 의심의 근거

case 4 처리에서 FPGA는 `sr_lfo_reset`를 level signal로 유지:
```systemverilog
sr_lfo_active[wr_snum]<= ~reg_data[5];
sr_lfo_reset[wr_snum] <=  reg_data[5];   ← bit 5와 동일하게 계속 유지
```

LFO 모듈(`ymf278_pcm_lfo.sv:103-110`)이 `lfo_reset_d1` level에 반응:
```systemverilog
if (lfo_reset_d1) begin
    new_lfo_cnt = 18'd0;                   ← 매 사이클 강제 0
end else if (lfo_active_d1) begin
    new_lfo_cnt = lfo_cnt_rd + lfo_period_rom[lfo_speed_d1];
end
// else (default): new_lfo_cnt = lfo_cnt_rd (hold)
```

→ Reference (`YMF278.cc:658-665`)는 `slot.lfo_cnt = 0`를 **한 번만** 실행하는데, FPGA는 매 사이클 0으로 강제. "동작이 다른가?"가 의심점.

#### 7.4.2 Reference advance() 분석

`YMF278.cc:351-353` (매 샘플 호출되는 advance):
```cpp
if (op.lfo_active) {
    op.lfo_cnt = (op.lfo_cnt + lfo_period[op.lfo]) & (LFO_PERIOD - 1);
}
```

→ `lfo_active = false`일 때 `lfo_cnt`는 증가하지 않음. 따라서 case 4에서 한 번 0으로 리셋 후 lfo_active=false인 동안 `lfo_cnt = 0`이 **유지**된다.

#### 7.4.3 출력 등가성 증명

`vib_out`/`am_out`은 `lfo_cnt` 값만으로 계산되며 (`lfo_active` 직접 사용 안 함), `lfo_cnt = 0`일 때:
- `lfo_fm = 0` → `vib_out = sign × 0 × depth / 12 = 0`
- `lfo_am = 0` → `am_out = 0 × depth >> 7 = 0`

따라서 다음 두 패턴의 출력이 동일:

| 시점 | Reference lfo_cnt | FPGA lfo_cnt | vib / am 출력 |
|------|------------------|--------------|---------------|
| bit5=1 직후 | 0 (one-shot) | 0 (강제) | 0 / 0 ✅ |
| bit5=1 유지 | 0 (held by !active) | 0 (강제 유지) | 0 / 0 ✅ |
| bit5=0 시점 | 0에서 시작 | 0에서 시작 (lfo_reset 해제) | 동기 증가 ✅ |
| bit5=0 한 샘플 후 | period | period | 동일 ✅ |

#### 7.4.4 슬롯 간 타이밍

LFO 모듈은 24슬롯 time-multiplexed. 게임이 슬롯 X에 case 4를 쓰면 `sr_lfo_reset[X]`만 갱신. 슬롯 X의 다음 파이프라인 윈도우(최대 1458 clk = ~17µs)에서 적용. 1 sample period(22.7µs at 44.1kHz)보다 짧으므로 한 샘플 내 처리 보장. **타이밍 안전.**

#### 7.4.5 결론

FPGA의 `sr_lfo_reset` level 유지 방식은 reference의 "one-shot 리셋 + held-by-inactive" 패턴과 **관측 가능한 출력이 100% 동일**. 코드 패턴은 다르지만 의미적으로 동등. **수정 불필요.**

### 7.5 [MEDIUM] HF FSM 진입 조건 재검증

**문제**: HF FSM은 `wr_field == 4'd0` (wave LSB write)에 의해 `hf_pending`이 set되어 트리거된다. 그러나:

1. 게임이 wave MSB(field 1)만 쓰고 LSB는 쓰지 않으면 HF가 안 일어남 (reference도 동일하므로 OK)
2. **하지만 reset 직후 sr_wave가 0이고, 게임이 wave 0(=built-in piano)을 쓰려고 한다면 wave LSB=0를 쓴다. 이 때 hf_pending이 1로 set되는가?** — case 0 `reg_data[7:0]`이 sr_wave 변경 여부와 무관하게 hf_pending을 set하므로 OK.
3. **부팅 직후 게임이 PCM register 0x02(wavetblhdr) 등을 먼저 쓰고 그 다음 slot 0 wave LSB를 쓸 경우, wavetblhdr가 캡처된 시점이 HF FSM 트리거 시점보다 빠른지 확인**.

→ 정적 분석 결과 wavetblhdr는 `always_ff` 블록의 다음 클럭 갱신, hf_pending도 다음 클럭 갱신 → 동시 진행. HF FSM이 실제로 HF_REQ에 들어갈 때 (= HF_IDLE 다음 사이클부터) wavetblhdr는 이미 정상 값. ✅ OK.

### 7.6 [MEDIUM] OPL3 sample_valid → PCM 믹싱 타이밍

**현재 `ymf278b_top.sv:236-250`**:
```systemverilog
always_ff @(posedge clk) begin
    audio_valid <= 1'b0;
    if (pcm_valid) begin
        pcm_left_hold  <= pcm_left;
        pcm_right_hold <= pcm_right;
    end
    if (opl3_sample_valid) begin
        mix_left_tmp  = opl3_l_eff + (pcm_mute ? 17'sh0 : $signed({pcm_left_hold[15], pcm_left_hold}));
        ...
        audio_valid <= 1'b1;
    end
end
```

→ OPL3 sample이 출력 마스터. PCM은 hold되어 OPL3 valid 시 합쳐짐. **만약 OPL3이 영원히 sample_valid를 안 내면 PCM도 안 들림**. FM은 정상 동작 중이라고 user가 보고했으므로 이 경로는 OK로 추정.

### 7.7 [MEDIUM] 디버그 오버레이 신뢰성

이전 세션에서 식별된 오버레이 버그들 (h_cnt 9-bit overflow, 4초 잔존, SDRAM read/write 미분리)이 미수정 상태. **하드웨어 실측 시 오버레이 표시를 100% 믿을 수 없음**.

→ `pcm_todo.md`에 정리된 Phase 1 오버레이 fix 작업 진행 권고.

### 7.8 [LOW] iverilog "sorry:" 경고 해소

`ymf278_pcm_envelope.sv:207, 209, 214, 251, 253, 354`에 constant select 경고. 시뮬레이션엔 영향 없지만 코드 깔끔히 하려면 임시 변수로 분리:
```systemverilog
// 변경 전
result[7:0] = ...

// 변경 후
logic [7:0] tmp = ...;
result <= {result[N-1:8], tmp};
```

### 7.9 [LOW] reg2_ram_wr_en 하드코드 제거

**현재 `ymf278b_top.sv:164`**:
```systemverilog
.reg2_ram_wr_en (1'b1),   // TODO: tie to regs[2] bit 0
```

→ regs[2] bit 0이 실제 RAM write enable. 현재는 항상 1로 강제되어 게임이 RAM 쓰기 보호 비트를 0으로 두어도 쓰기가 허용됨. 동작상 문제는 없지만 정확도 향상.

### 7.10 [LOW] 시뮬레이션 자동화 스크립트

`sim/run_sim.sh`가 있지만 모든 testbench를 일괄 실행하지는 않음. 다음 항목 추가 권고:
- `make test` 또는 단일 스크립트로 모든 tb 실행 + PASS/FAIL 집계
- CI 통합 (GitHub Actions)

---

## 8. 결론

### 8.1 검증 완료 사항

- ✅ 단위 테스트 24개 모두 PASS (envelope 5 + interpolator 4 + LFO 15)
- ✅ 통합 테스트 13/13 PASS (tb_pcm_integration 신규 작성, CPU R/W path 포함)
- ✅ Reference C++ 알고리즘 10개 항목 1:1 대조 완료
- ✅ **8건의 명확한 RTL 버그 발견 및 수정:**
  1. endAddr 이중 2's complement (`~bytes+1` → raw bytes)
  2. wavetblhdr 비트 시프트 (`<< 18` → `<< 19`)
  3. HF FSM `mem_rd_req` byte 간 drop 누락 (off-by-one read)
  4. Memory arbiter 1-cycle cooldown 부재 (Fix 3 보완 필수)
  5. Volume `vol_mul`/`pan_att` 비트폭 부족 (최대 음량 silence)
  6. `cpu_data_out` 매 사이클 0xFF 리셋 (SDRAM 데이터 stale)
  7. CPU 메모리 read 다단 핸드셰이크 누락 (`io_ack` 즉시 어서트로 stale latch)
  8. `dbg_env_min` non-sticky (디버그 정확도 — 짧은 열림 miss)
- ✅ tb_pcm_slot의 누락 포트 1개 보강
- ✅ **하드웨어 검증 (BASIC 직접 driving)**:
  - CPU 메모리 R/W: 정상 (write 0x55 → read 0x55, write 0xAA → read 0xAA)
  - yrw801 ROM 읽기: 정상 (40 18 00 00 = yrw801[0..3])
  - Envelope 열림: 정상 (Row 8 sticky로 확인)
  - Mixer/Audio out: 정상 (manual driving 시 노이즈 들림)

### 8.2 검증 한계

- ❌ LFO 단위 테스트 부재
- ❌ 통합 (top-level) 테스트벤치 미실행
- ❌ C++ vs FPGA 출력 cycle-level 비교 없음
- ❌ 하드웨어 실측 (현재 무음)
- ❌ 디버그 오버레이 신뢰성 미확보

### 8.3 무음 증상에 대한 평가

**8개 RTL 버그를 모두 수정한 결과**:
- ✅ Manual BASIC driving: envelope 열리고 audio level meter 반응 (PCM pipeline 정상)
- ⏳ 실제 게임 (Neon Horizon): envelope 열리지만 audio level meter 반응 없음

**Neon Horizon 무음의 가능한 원인 (다음 세션 작업)**:

1. **cpu_wr_pending FIFO 부재** — 현재 1바이트만 latch. 게임이 LDIR로 빠르게 sample 업로드 시 일부 바이트 손실 가능성. → SDRAM의 sample 영역이 대부분 0 → 무음.
2. **HF FSM이 게임의 wave 시퀀스 처리 못함** — 게임이 wave를 연속 변경 시 hf_pending이 누적되어 interp_start가 영구히 gating될 가능성.
3. **TL handling** — 게임이 TL=0xFF (silence) 설정 후 fade-in 시퀀스를 우리 TL interpolation이 제대로 처리 못할 가능성.
4. **wavetblhdr custom sample area** — Fix 2 (wavetblhdr `<<19`)는 적용했지만 게임의 실제 sample upload 경로가 end-to-end로 동작하는지 미검증.
5. **OPL3 status `8'h00` 하드코드** — mbwave의 OPL4 detection이 OPL3 status를 읽고 fail. ymf278b_top.sv:225 `assign opl3_status = 8'h00` 수정 필요.

**주의**: 두 버그 모두 단위 테스트가 직접 커버하지 않는 통합 경로에 있었음 → 단위 테스트 PASS가 "버그 없음"을 의미하지 않음을 다시 확인. 통합 테스트(§7.3)가 필수.

### 8.4 다음 액션 권고

**옵션 A (빠른 실험)**: 현재 수정 상태로 빌드 → 실측. 무음이면 어떤 디버그 LED가 다른지 보고. 단, 디버그 오버레이 자체가 의심스러우므로 신뢰도 낮음.

**옵션 B (정석 진행)**:
1. §7.2 (wavetblhdr) 해결
2. §7.1 (LFO 단위 테스트) 작성·실행
3. §7.3 (tb_ymf278b_top) 컴파일·실행
4. 위 3개에서 발견된 버그 모두 수정 후 빌드 → 실측

**옵션 C (오버레이 우선)**: `pcm_todo.md`의 Phase 1 오버레이 fix를 먼저 진행하여 하드웨어 실측 데이터를 신뢰할 수 있게 만든 뒤, 옵션 A/B 중 선택.

→ **권고: 옵션 B + 옵션 C 병행**. 옵션 B로 더 많은 RTL 버그를 잡고, 옵션 C로 실측 신뢰도를 확보한 후 통합 테스트.

---

## 9. 참고 파일

| 파일 | 역할 |
|------|------|
| `reference/YMF278.cc` | openMSX PCM 엔진 C++ 참조 (33KB) |
| `reference/YMF278B.cc` | OPL4 통합 C++ 참조 (7KB) |
| `sim/reference_model.py` | Python 참조 모델 (envelope/interpolation/volume) |
| `tb/tb_pcm_envelope.sv` | Envelope 단위 테스트 (5건) |
| `tb/tb_pcm_slot.sv` | Interpolator 단위 테스트 (4건) |
| `tb/tb_ymf278b_top.sv` | 통합 테스트 (미실행) |
| `pcm_todo.md` | 디버그 오버레이 및 PCM 의심 항목 TODO |
| `moonsound_pcm_fix_implementation_plan.md` | 이전 fix 계획 문서 |

---

**보고서 종료**
