# Draft issues for hra1129/V9968_Cartridge (2026-10-22)

Three issues, each to be posted separately.  Checked against upstream `main` at
**31d82b8** ("Updated V9968 Detect"): all three are still present there.  Line numbers
below are from 31d82b8, path `fpga/V9968_Cartridge_TangNano20K/src/v9968/`.

Context to state once (in each issue, short): found while integrating the V9968 as the
internal VDP of the MiSTer MSX1 core (VRAM on SDRAM through a fixed-latency bridge, same
`vdp_*.v` files).  Each finding was reproduced in a small Verilator bench on the unmodified
upstream logic, with a control run, and the fix was re-run on the same bench.  The
benches drive the V9968 host bus directly; nothing below depends on our SDRAM bridge.

---

## Issue A — An interrupt event on the clock of a status read is lost (FH / F / CE-end)

**Title:** `vdp_cpu_interface.v`: line/frame/command-end interrupt flag is not set when the event falls on the clock of a status-register read

### 日本語

`vdp_cpu_interface.v` 868行目からの割り込みフラグの always ブロックは、

```
if( !reset_n ) ...
else if( w_read && ff_port1 ) begin ... end      // 875: ステータス読み出し(該当フラグのクリア)
else if( w_write && ff_port4 ) begin ... end     // 885: Port#4 書き込み
else begin
    if( intr_frame ) ff_frame_interrupt <= 1;    // 901
    ...
    else if( intr_line ) ff_line_interrupt <= 1; // 912
    if( intr_command_end ) ff_command_end_interrupt <= 1;
end
```

という一つの if / else-if の連鎖になっています。そのため、`intr_line`(1クロックのパルス)、
`intr_frame`、`intr_command_end` が **ポート1の読み出し(どの S#n でも)または Port#4 書き込みと
同じクロック** に来ると、else 側が実行されずフラグが立ちません。イベントはそのまま失われます。

S#1 をポーリングして FH を待つソフトは、FH を取りこぼすとその場で永久に待ち続けます。
実例: ASO (sharksym 2022) の 224 ライン版(R#19=C6h をセットして S#1 をループで読む)が、
SPACE で開始した直後に黒画面で停止しました。同じソフトは V9958 実装と openMSX(V9958/V9968
どちらも)では正常に動きます。

**再現:** ASO のゲーム中 1 フレームの VDP 操作(openMSX のトレースから取得)をベンチで再現しました。
内容は、ライン割り込み 4 本(R#19 = DBh/68h/D2h/C6h、R#23 = 18h/00h、R#9 LN の切り替え)を
使い、各ラインで S#1 を読み続けて FH を待つ、というものです。FH を待つ時間は 1.5 フレームを
上限とし、来なければ「停止」と数えます。

- 修正前: 30 フレームで 11 回、FH が来ませんでした。4 つの段すべてで起きます。
- この 11 回はいずれも、`intr_line` のパルスは出ているのに `ff_line_interrupt` が一度も立って
  いませんでした(信号ログで確認)。
- 修正後: 0 回。

**修正案:** CPU によるクリアを先に書き、イベントによるセットを後に書きます(同じクロックなら
イベントが勝つ)。読み出しで返していない新しいイベントは消さない、という意味になります。

```verilog
else begin
    //  clears by the CPU
    if( w_read && ff_port1 ) begin
        if( ff_status_register_pointer == 4'd0 ) ff_frame_interrupt <= 1'b0;
        else if( ff_status_register_pointer == 4'd1 ) ff_line_interrupt <= 1'b0;
    end
    if( w_write && ff_port4 ) begin
        if( ff_bus_wdata[0] ) ff_frame_interrupt <= 1'b0;
        if( ff_bus_wdata[1] ) ff_line_interrupt <= 1'b0;
        if( ff_bus_wdata[2] ) ff_command_end_interrupt <= 1'b0;
        ff_lock_extregs <= ff_bus_wdata[7];
    end
    //  events (assigned last: they win over a clear on the same clock)
    if( intr_frame ) ff_frame_interrupt <= 1'b1;
    if( clear_line_interrupt || intr_frame ) ff_line_interrupt <= 1'b0;
    else if( ff_register_write && (ff_register_num == 6'd0 || ff_register_num == 6'd19) ) ff_line_interrupt <= 1'b0;
    else if( intr_line ) ff_line_interrupt <= 1'b1;
    if( intr_command_end ) ff_command_end_interrupt <= 1'b1;
end
```

### English

The interrupt-flag block in `vdp_cpu_interface.v` (line 868 on) is one if / else-if chain:
reset, then the port-1 read (875), then the Port#4 write (885), and only in the final
`else` the events (`intr_frame` 901, `intr_line` 912, `intr_command_end`). When the
one-clock `intr_line` pulse, `intr_frame` or `intr_command_end` falls on the clock of
**any** status read (port 1) or a Port#4 write, the `else` branch does not run and the
event is lost for good.

Software that polls S#1 for FH then waits for ever. Seen with ASO (sharksym 2022), 224-line
version: it sets R#19 = C6h and polls S#1; on the V9968 it froze to a black screen right
after SPACE. The same program runs on the V9958 and in openMSX (V9958 and V9968).

Repro: one in-game frame of ASO's VDP activity, taken from an openMSX trace (four line
IRQs: R#19 = DBh/68h/D2h/C6h, R#23 = 18h/00h, R#9 LN toggled). Each step waits for FH by
polling S#1, with a 1.5-frame limit before it counts as "stuck". Unfixed: 11 FH never seen
in 30 frames, at all four steps. In every one of those, the `intr_line` pulse fired but
`ff_line_interrupt` never rose (signal log). Fixed (clears first, events last, as above):
0 in 30 frames.


### Addendum (2026-10-22, later): a second window, one clock after the event

`ff_status_register` is latched one clock behind the flags (the "Read data latch" block).
A port-1 read on the clock *after* `ff_line_interrupt` rose returns FH = 0 from the stale
latch and still clears the flag, so the CPU never sees that FH. The same applies to F on
S#0. The same-clock fix above does not cover this.

Repro: the `+aso` bench with `+pollpad=0..11` (extra clocks per S#1 poll, which moves the
read phase), 30 frames each, 1440 FH events in total.
- With the same-clock fix only: 17 FH lost, at 5 of the 12 phases. Each costs one frame.
- With the fix below: 0 lost. Reads on the critical clock still happen (12), but they no
  longer clear.

Fix: a status read clears F / FH only when the byte it returns shows the flag.

```verilog
if( ff_status_register_pointer == 4'd0 ) begin
    if( ff_status_register[7] ) ff_frame_interrupt <= 1'b0;
end
else if( ff_status_register_pointer == 4'd1 ) begin
    if( ff_status_register[0] ) ff_line_interrupt <= 1'b0;
end
```

---

## Issue B — Sprite VRAM request held across display-off freezes VDP commands

**Title:** `vdp_sprite_select_visible_planes.v`: `ff_vram_valid` held while the display is off can block VDP commands for ever

### 日本語

`vdp_sprite_select_visible_planes.v` 193行目の分岐

```verilog
else if( !screen_v_active || !screen_h_active || !reg_display_on || w_screen_pos_x[9]  ) begin
    //  hold
end
```

は `ff_vram_valid` も保持します。セレクタが要求を立てた次のクロックで R#1 により表示が OFF に
なると、要求が立ったまま残ります(128 クロック周期のうち 2 クロック)。この状態は、表示が再び
ON になるまで続きます。

`vdp_vram_interface.v` は毎スロット、スプライトの要求をコマンドや CPU より先に出します
(154/219 行目付近)。そのため、VRAM を読むコマンド(LRMM, LMMM など)はデータを受け取れず、
CE = 1 のまま止まります。続く Port#0 の書き込みも待たされます。

**再現:** R#1 を 40h にして表示 ON・スプライト ON の状態で 20 ms 動かします。次に、
セレクタの (phase 2, sub_phase 0) の後 N クロック目に R#1 = 00h(表示 OFF)が入るようにし、
その直後に LRMM(256×212)を実行します。N = 0..127 をすべて試しました。

- 修正前: N = 29 と N = 125 の 2 か所だけで LRMM が終わりません(100 ms 以上 CE = 1)。
  このとき `ff_vram_valid = 1` のままでした。
- 修正前でも、他の 126 か所は 12.66 ms で終わります。
- 修正後: 128 か所すべて 12.66 ms で終わります。

実際のソフトでは SUPER CAT / COASTAL FLIGHT(kanon-ai V9968 デモ)の最初の LRMM で発生しました。
ゲームでは表示 OFF の瞬間が毎回違うため、症状は「たまにフリーズ」になります。
#7(ドラスレファミリー、ダンジョン突入でフリーズ)や #4 のような「コマンド待ちで固まる」症状の
候補の一つかもしれません。ただし、こちらでは確認していません。

**修正案:** hold 分岐で要求を落とします。

```verilog
else if( !screen_v_active || !screen_h_active || !reg_display_on || w_screen_pos_x[9]  ) begin
    //  hold -- except the VRAM request
    ff_vram_valid <= 1'b0;
end
```

### English

The hold branch at line 193 of `vdp_sprite_select_visible_planes.v` also holds
`ff_vram_valid`. If R#1 turns the display off on the clock right after the selector raised
its request, the request stays up until the display is turned on again. This happens in 2
of the 128 clocks of its cycle.

`vdp_vram_interface.v` issues the sprite request ahead of the command and CPU paths on
every slot. A command that reads VRAM (LRMM, LMMM, ...) therefore never gets its data and
stays at CE = 1, and later Port#0 writes stall behind it.

Repro: run with the display and sprites on (R#1 = 40h) for 20 ms. Then let R#1 = 00h land
N clocks after the selector's (phase 2, sub_phase 0) edge, and start a 256×212 LRMM right
after. N was swept over 0..127.
- Unfixed: the LRMM never finishes at N = 29 and N = 125 (CE still 1 after 100 ms, with
  `ff_vram_valid` stuck at 1). The other 126 offsets finish in 12.66 ms.
- Fixed (clear `ff_vram_valid` in the hold branch): all 128 offsets finish in 12.66 ms.

In real software we hit it at the first LRMM of SUPER CAT / COASTAL FLIGHT (kanon-ai V9968
demo). Because the display-off moment varies, it shows up as an occasional freeze; it
may be one candidate for "frozen at a command wait" reports such as #7. We have not
verified that.

---

## Issue C — Changing R#9 LN mid-frame moves the display start at once (V9958 does not)

**Title:** `vdp_timing_control_ssg.v`: the display start (`ff_top_line`) follows R#9 LN on every clock; a mid-frame LN change shifts the rest of the frame by 10 lines

### 日本語

`vdp_timing_control_ssg.v` の `ff_top_line`(318行目から)は、R#9 の LN と 50Hz ビットから毎クロック
選び直されています。`w_screen_pos_y = v_count/2 - ff_top_line + adjust`(340行目)なので、
フレームの途中で LN を変えると、その瞬間に画面ラインが 10 ライン飛びます。

224 ラインのオーバースキャン技法(Fix-It Felix Jr.、ASO 224、Knightmare 224 など)は、カウンタが
192 を過ぎて 212 に届く前に LN を 1 から 0 にして表示を終わらせない、というものです。V9968 では
この書き込みの瞬間にライン 207 が 197 に戻ります。その結果、その後の表示(HUD など)が 10 ライン
下にずれます。LN を 1 に戻す時は逆に 10 ライン進みます。

V9958、ESE の VDP、openMSX はいずれも表示開始をフレームごとに一度だけ決めます。LN の途中変更は
表示終了の判定にだけ効きます。

**再現:** 212 ライン、表示 ON の状態で、画面ライン 207 で R#9 = 00h を書きます。
- 修正前: `screen_pos_y` が 206 → 197 と飛びます。230 で R#9 = 80h に戻すと 229 → 240 と飛びます。
- 修正後: 飛びはなく、表示は 211 を過ぎても続きます(技法どおり)。
- LN を変えない対照では、修正前後で同じ 212 ラインです。

**修正案:** `ff_top_line` をフレーム境界でだけ更新します。

```verilog
else if( !(w_h_count_end && w_v_count_end) ) begin
    //  hold: the display start is fixed once per frame, as on the V9958
end
else if( reg_212lines_mode ) begin
    ...
```

(表示終了の判定 `w_v_count_end_line` は今まで通り LN をそのまま見ます。技法にはこちらが必要です。)

### English

`ff_top_line` (line 318 on) is re-selected on every clock from R#9 LN and the 50 Hz bit.
Since `w_screen_pos_y = v_count/2 - ff_top_line + adjust` (line 340), an LN change in the
middle of a frame makes the screen line jump by 10 at once.

The 224-line overscan trick (Fix-It Felix Jr., ASO 224, Knightmare 224, ...) sets LN from 1
to 0 after the counter passed 192 and before it reaches 212, so that the display does not
end. On the V9968 that write takes line 207 back to 197, and everything below (the HUD)
appears 10 lines lower. Setting LN back to 1 later jumps the other way.

The V9958, the ESE VDP and openMSX fix the display start once per frame; a mid-frame LN
change only affects where the display ends.

Repro: 212 lines with the display on; write R#9 = 00h at screen line 207.
- Unfixed: `screen_pos_y` goes 206 → 197; R#9 = 80h at 230 then gives 229 → 240.
- Fixed (update `ff_top_line` only at the frame boundary, as above; the display-end
  compare still follows LN live, which the trick needs): no jump, and the active area runs
  past 211 as intended.
- Control without the LN write: identical before and after (212 lines).

---

## Issue D — FH is cleared at the frame-interrupt timing (a late line-interrupt handler reads FH = 0)

Added 2026-10-24.  Hardware-confirmed fix on the MiSTer core (ASO 224 runs).

### 日本語

`vdp_cpu_interface.v` の割り込みフラグ処理で、走査線割り込みフラグ FH (`ff_line_interrupt`) が
フレーム割り込みのタイミングで消されています。

```verilog
if( clear_line_interrupt || intr_frame ) begin
    ff_line_interrupt <= 1'b0;
end
```

`clear_line_interrupt` は `vdp_timing_control_ssg.v` の `w_intr_frame_timing` (250行, 431行) を
1クロック遅らせたものです。このため、R#19 が画面下端付近の走査線を指している場合、FH が立ってから
CPU が S#1 を読む前にフラグが消えます。実機 (V9938/V9958) と openMSX は FH をリセット、IE1=1 での
S#1 読み出し、IE1 を 0 にする R#0 書き込みでのみクリアします (openMSX VDP.cc の irqHorizontal.reset())。

ASO (turbo R) で発生します: 104ライン目の割り込み処理で R#19 = D2h (210)、R#9 = 212ライン に設定。
210ライン目で FH が立ち、1248 clk (14.5 µs) 後のフレーム割り込みタイミングで消えます。ゲームの割り込み
経路 (0038h → H.KEYI FD9Ah → 80BBh、S#1 読み出しは 80F2h、bit0 が 1 のときだけコールバック 058Bh) は
S#1 を読むまで R800 で約 48 µs (openMSX では約 87 µs) かかるため、常に FH = 0 を読みます。コールバックが
呼ばれず、メインループ (065Dh) が (9402h) を待ち続け、SPACE 後に黒画面のまま止まります。

修正案 (この1行のクリアを削除するだけ):

```verilog
if( ff_register_write && (ff_register_num == 6'd0 || ff_register_num == 6'd19) ) begin
    ff_line_interrupt <= 1'b0;
end
else if( intr_line ) begin
    ff_line_interrupt <= 1'b1;
end
```

### English

In `vdp_cpu_interface.v` the line-interrupt flag FH is cleared at the frame-interrupt timing
(`clear_line_interrupt || intr_frame`; `clear_line_interrupt` is `w_intr_frame_timing` delayed
one clock, vdp_timing_control_ssg.v:250/431). With R#19 near the bottom of the screen, FH is
gone before the CPU reads S#1. The V9938/V9958 and openMSX clear FH only on reset, on the S#1
read with IE1 on, and on an R#0 write that turns IE1 off.

ASO (turbo R): its line-104 handler sets R#19 = D2h (210) and 212 lines. FH rises at line 210
and is cleared 1248 clk_vdp (14.5 µs) later. The game's IRQ path (0038h → H.KEYI FD9Ah →
80BBh, S#1 read at 80F2h, callback 058Bh only if bit0) needs ~48 µs on an R800 (~87 µs in
openMSX), so it always reads FH = 0, the callback never runs, the main loop waits on (9402h)
at 065Dh for ever: a black screen after SPACE.

Fix: drop that clear (diff above). Repro (our bench): display off, R#0 = 16h, R#9 = 80h,
R#19 = D2h; on int_n falling wait D µs, then R#15 = 1 and read S#1. Unfixed: FH = 0 in 6 of 6
frames at D = 20, 48, 90 µs (FH = 1 at 5 and 10 µs). Fixed: FH = 1 at every D. Control
R#19 = 68h: FH = 1 on both. On hardware (MiSTer, V9968 build) ASO 224 plays after the fix.

Related, not changed on our side yet: the same block also clears FH on ANY write to R#0 or
R#19 (openMSX: only an R#0 write that turns IE1 off), and that clear takes priority over an
`intr_line` on the same clock, so a line match coinciding with such a write is lost.

---

## Notes for posting (not part of the issues)

- Bench names on our side, if asked: `sim/v9968_vram/tb_v9968_vram.sv` with `+aso=30` (A),
  `+cmd=3 +demo=1 +ct55=1 +offat=N` (B), `+lnsw=207` / `+lnsw=0` (C), `sim/v9968_vram/run_irq.sh`
  (D, with its own mutant), branch V9968_Geo3D of github.com/muhanpong/MSX1_MiSTer.
- Not reported: HS=0 command speed vs the V9938 (by design; openMSX offers `timing=1`
  for that); our local additions (scanline levels, per-command wait port, Geo3D wiring).
- Licence: the repository `LICENSE` is MIT, but the `vdp_*.v` headers carry Takayuki Hara's
  3-clause terms (incl. no commercial use without written permission). The diffs above are
  offered under whatever terms the file they patch carries.
