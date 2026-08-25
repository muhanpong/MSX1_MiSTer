# A4 — MSX1_MiSTer Diagnostic Playbook (HPS logs + JTAG)

Reusable, copy-paste-ready procedures for capturing HPS serial logs and JTAG state
on the DE10-Nano board. Proven during the session; no judgement, just the working steps.

- Board (HPS over ssh): `root@192.168.1.86` (ssh works; no password noted)
- MiSTer Main version: **260611**
- PC: Linux (Manjaro), user `muhanpong`

---

## 0. Quick facts / device map

| Thing | Identity | Notes |
|---|---|---|
| **Serial console** | USB **Mini-B** port, FTDI FT232R, USB id `0403:6001` | shows up as `/dev/ttyUSB0` on the PC. This is `console=ttyS0` on the HPS. |
| **JTAG / USB Blaster** | **micro-USB** port, `09fb:6010` Altera DE-SoC | This is **JTAG only — NOT a serial port.** Don't confuse the two ports. |
| Serial settings | `115200 8N1` | boot logs decode cleanly at 115200 |
| `/dev/ttyUSB0` perms | `root:uucp`, mode `660` | PC user not in `uucp` → need `sudo chmod 666` |
| inittab line | `::sysinit:/media/fat/MiSTer &` | **sysinit, NOT respawn** → killing main does **not** auto-restart |
| main stdout/stderr | `/dev/console` (= `ttyS0`) | **fully-buffered** when redirected → printf suppressed during core run |

Confirm the two USB devices on the PC:

```bash
lsusb | grep -Ei '0403:6001|09fb:6010'
# 0403:6001 Future Technology Devices ... FT232R  -> SERIAL  (/dev/ttyUSB0)
# 09fb:6010 Altera DE-SoC                          -> JTAG    (USB Blaster)
ls -l /dev/ttyUSB0
```

---

## (a) Start robust serial capture (PC side, reconnect-safe)

The FTDI cable may re-enumerate (unplug/reboot). This loop re-applies permissions
and line settings on every reconnect and appends to one log file.

```bash
# One-time per boot if you don't want to retype: fix permission (device is root:uucp 660)
sudo chmod 666 /dev/ttyUSB0

# Robust capture loop — survives disconnect/reconnect, appends forever.
PORT=/dev/ttyUSB0
LOG=/tmp/mister_serial.log
while true; do
  if [ -e "$PORT" ]; then
    sudo chmod 666 "$PORT" 2>/dev/null
    stty -F "$PORT" 115200 cs8 -cstopb -parenb -echo raw 2>/dev/null
    echo "=== [$(date)] connected $PORT ===" >> "$LOG"
    cat "$PORT" >> "$LOG"          # blocks until device disappears
  fi
  sleep 1
done
```

Watch it live in another terminal:

```bash
tail -f /tmp/mister_serial.log
```

Bare stty (if you just want a one-shot, no reconnect handling):

```bash
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -echo raw
cat /dev/ttyUSB0 | tee /tmp/mister_serial.log
```

**GOTCHAS**
- Permission resets to `660 root:uucp` on every re-enumeration → the loop re-`chmod`s. (Permanent fix alt: `sudo usermod -aG uucp $USER` then re-login.)
- **Boot logs print fine, but during a running core MiSTer Main suppresses printf** because stdout is fully-buffered when redirected to /dev/console. To see in-core printf, use (b) or (c) below.

---

## (b) gdb fflush — flush main's buffered stdout WITHOUT restarting (HPS side)

Forces libc to flush already-buffered printf output to the console. main is stripped,
but `fflush` is a **libc** symbol so gdb can still call it.

```bash
ssh root@192.168.1.86
PID=$(pidof MiSTer)
gdb -p "$PID" -batch -ex 'call (int)fflush(0)' -ex detach -ex quit
```

One-liner from the PC:

```bash
ssh root@192.168.1.86 'gdb -p $(pidof MiSTer) -batch -ex "call (int)fflush(0)" -ex detach -ex quit'
```

**GOTCHAS**
- Requires `gdb` on the board. Non-destructive: main keeps running, OSD/input untouched.
- Only flushes what's already buffered up to that instant — re-run after each event you want to see, or use (c) for continuous line-buffered output.

---

## (c) Restart main with stdbuf line-buffering (HPS side) — continuous live printf

Because inittab is **sysinit (not respawn)**, killing main does NOT auto-respawn,
so you can relaunch it yourself with line-buffering and your own log redirect.

```bash
ssh root@192.168.1.86

# 1) Capture the exact rbf/cmdline main was launched with (arg index 2 = the .rbf)
RBF=$(awk -v RS="\0" 'NR==2' /proc/$(pidof MiSTer)/cmdline)
echo "RBF=$RBF"

# 2) Kill the running main (does NOT auto-respawn under sysinit)
kill $(pidof MiSTer)

# 3) Relaunch line-buffered, KEEPING a usable tty on stdin (critical for OSD input)
setsid stdbuf -oL /media/fat/MiSTer "$RBF" </dev/tty1 >/tmp/mlog 2>&1 &

# 4) Watch the line-buffered log
tail -f /tmp/mlog
```

**GOTCHAS**
- **stdin MUST be a real tty** (`</dev/tty1`). A prior attempt used `</dev/null` which **broke OSD input** — keyboard/OSD stopped responding. Keep `/dev/tty1`.
- `stdbuf -oL` makes stdout line-buffered so printf appears immediately (no fflush needed).
- `setsid` detaches it from the ssh session so it survives logout.
- **Permission-guard:** killing main over ssh may require user authorization on this setup — if `kill` is blocked, ask the operator to confirm/authorize.
- This restarts the core (brief reload). Use (b) gdb fflush instead if you must NOT reload the core.

---

## (d) jtagconfig scan (PC side)

Quartus 17.1 (USB Blaster = the micro-USB `09fb:6010`).

```bash
QBIN=/run/media/muhanpong/0eb4bebc-0644-4c2f-9a97-ddca5afcd8f3/intelFPGA_lite/17.1/quartus/bin
"$QBIN/jtagconfig"
```

Expected good output:

```
1) DE-SoC [1-10]
   4BA00477   SOCVHPS
   02D020DD   5CSEBA6(.|ES)/5CSEMA6/..
```

**GOTCHAS**
- If nothing appears: the micro-USB cable is unplugged or you grabbed the Mini-B (serial) port by mistake.
- `5CSEBA6` = the Cyclone V on the DE10-Nano; `SOCVHPS` = the ARM HPS TAP.
- Core BRAM is readable via in-system tools (in-system memory content editor / `quartus_stp`) **only if a debug probe was compiled into the core's .rbf**. No probe → no BRAM read.

---

## (e) Verify which core / build is currently loaded

**From the serial log (most reliable):** on core load the log prints the rbf path and core name.

```bash
grep -E 'Core path|Core name' /tmp/mister_serial.log | tail -n 5
# Core path: /media/fat/_Computer/MSX1_xxxxxxxx.rbf
# Core name is MSX1
```

**From the HPS over ssh:**

```bash
ssh root@192.168.1.86 'cat /tmp/CORENAME; echo'        # e.g. MSX1
# exact rbf the running main was launched with:
ssh root@192.168.1.86 'awk -v RS="\0" "NR==2" /proc/$(pidof MiSTer)/cmdline; echo'
```

Confirmation that a core actually loaded = serial shows **`Core path: ...rbf`** and **`Core name is MSX1`**.

---

## Board filesystem paths (reference)

| Path | Contents |
|---|---|
| `/media/fat/_Computer/` | Computer cores (`MSX1_*.rbf`) |
| `/media/fat/_Console/` | Console cores (`NES_*.rbf`) |
| `/media/fat/cheats/<CoreName>/` | Cheat files per core |
| `/media/fat/games/MSX1/` | MSX1 game images |
| `/tmp/CORENAME` | Name of currently loaded core |
| `/media/fat/MiSTer` | Main binary (launched by inittab sysinit) |

---

## Decision cheat-sheet

- Just want **boot logs** → (a) serial capture; decodes fine at 115200.
- Want **in-core printf** but must NOT reload core → (b) gdb fflush (re-run per event).
- Want **continuous in-core printf** and a core reload is OK → (c) stdbuf restart (keep `</dev/tty1`).
- Want **JTAG / BRAM** → (d) jtagconfig; BRAM read needs a probe baked into the .rbf.
- Want to **confirm the build under test** → (e) serial `Core path/Core name` or `/tmp/CORENAME`.
