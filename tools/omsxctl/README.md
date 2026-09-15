# omsxctl — drive a running openMSX over its control socket

`omsx.py 'tcl cmd' ['tcl cmd' ...]` connects to the newest `/tmp/openmsx-*/socket.*`
and prints each reply. Settings are read with `set <name>` (there is no `get`).

- `vdplog.tcl` — `vdplog_start <file>` / `vdplog_stop`: every VDP register write
  (`W frame line R#=val pc=`) and status read (`S frame line S# pc=`).
- `r19log.tcl` — logs only R#19 writes with frame/line/PC.

Gotchas found on 20260915 (ASO band research):
- `loadstate` restores `z80_freq_locked` — set `z80_freq_locked off` AFTER every loadstate,
  or `set z80_freq` is silently ignored (one run looked "speed independent" because of this).
- read_io watchpoint callbacks must not use `$::wp_last_value` (the callback errors and logs nothing).
- `advance_frame` steps exactly one video frame; `screenshot -raw` gives 320x240.
- Take `savestate <name>` before touching someone's session.
