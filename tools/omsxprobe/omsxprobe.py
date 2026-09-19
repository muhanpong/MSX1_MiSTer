#!/usr/bin/env python3
"""openMSX probing harness — one driver for the measurements this core keeps needing.

Every subcommand generates a Tcl script, runs openMSX headless-ish, parses the log
and prints a table.  The point is that the openMSX-side traps (see README.md) are
encoded here once instead of being rediscovered per session.

  ports    I/O port census: who reads/writes which port, how often, first PC
  bands    per-frame top/bottom blank-line counts (split/raster regressions)
  sprites  sprite pixel map, by rendering the SAME frame twice with SPD forced
  trace    generic breakpoint/watchpoint logging at given addresses
  run      run a raw Tcl file (escape hatch)

Examples
  omsxprobe.py ports  --machine Panasonic_FS-A1ST --disk game.dsk --seconds 62
  omsxprobe.py bands  --state aso_probe --frames 6
  omsxprobe.py sprites --state aso_tb_06
  omsxprobe.py trace  --state aso_probe --bp 0x6CCC 0x6D30 0x6D9D --seconds 2
"""
import argparse, os, re, shutil, subprocess, sys, tempfile

OPENMSX = shutil.which("openmsx") or "openmsx"


def run_tcl(tcl: str, machine=None, disk=None, timeout=300, workdir=None):
    """Write the script to a temp file and run openMSX on it.  Returns (rc, stdout)."""
    d = workdir or tempfile.mkdtemp(prefix="omsxprobe.")
    path = os.path.join(d, "probe.tcl")
    with open(path, "w") as f:
        f.write(tcl)
    cmd = [OPENMSX]
    if machine:
        cmd += ["-machine", machine]
    if disk:
        cmd += ["-diska", disk]
    cmd += ["-script", path]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr, d
    except subprocess.TimeoutExpired:
        return 124, "(timeout)", d


# --- Tcl preamble ----------------------------------------------------------
# W() appends to a log file.  NEVER build callback bodies by string-substituting
# live values: openMSX substitutes at *schedule* time, so the value is frozen.
# Always call a proc from the callback instead.
PREAMBLE = '''
set OUT "{out}"
proc W {{s}} {{ set f [open $::OUT a]; puts $f $s; close $f }}
proc hexb {{a n}} {{ set l {{}}; for {{set i 0}} {{$i<$n}} {{incr i}} {{
    lappend l [format %02X [debug read memory [expr {{($a+$i)&0xFFFF}}]]] }}; return $l }}
'''


def cmd_ports(a):
    out = os.path.join(a.outdir, "ports.txt")
    tcl = ("set throttle off\n" + PREAMBLE.format(out=out) + f'''
array set rc {{}} ; array set wc {{}} ; array set rf {{}} ; array set wf {{}} ; array set seen {{}}
proc hitr {{}} {{ set p [expr {{$::wp_last_address & 0xFF}}]
  if {{![info exists ::rc($p)]}} {{ set ::rc($p) 0
    set ::rf($p) "t=[format %6.2f [machine_info time]] pc=[format %04X [reg pc]]" }}
  incr ::rc($p) }}
proc hitw {{}} {{ set p [expr {{$::wp_last_address & 0xFF}}]
  if {{![info exists ::wc($p)]}} {{ set ::wc($p) 0
    set ::wf($p) "t=[format %6.2f [machine_info time]] pc=[format %04X [reg pc]]" }}
  incr ::wc($p) }}
debug set_watchpoint read_io  {{0x00 0xFF}} {{}} hitr
debug set_watchpoint write_io {{0x00 0xFF}} {{}} hitw
after time {a.seconds} {{
  foreach p [lsort -integer [concat [array names ::rc] [array names ::wc]]] {{
    if {{[info exists ::seen($p)]}} continue
    set ::seen($p) 1
    set r [expr {{[info exists ::rc($p)] ? $::rc($p) : 0}}]
    set w [expr {{[info exists ::wc($p)] ? $::wc($p) : 0}}]
    set f [expr {{[info exists ::rf($p)] ? $::rf($p) : $::wf($p)}}]
    W [format "%02X %8d %8d %s" $p $r $w $f]
  }}
  exit
}}''')
    rc, log, d = run_tcl(tcl, a.machine, a.disk, a.timeout)
    print(f"{'port':>4} {'read':>9} {'write':>9}  first access")
    for line in open(out):
        p, r, w, rest = line.split(None, 3)
        print(f"  {p}h {int(r):9d} {int(w):9d}  {rest.strip()}")


def cmd_bands(a):
    """Blank-line count at the top/bottom of each captured frame.

    Why this metric: a garbage-colour detector misses the failure mode where the
    split leaves whole lines *blank*.  Counting blank lines catches both.
    """
    out = os.path.join(a.outdir, "bands.txt")
    shots = os.path.join(a.outdir, "shot")
    tcl = (f"loadstate {a.state}\n" if a.state else "set throttle off\n")
    tcl += PREAMBLE.format(out=out) + f'''
set throttle on
set minframeskip 0
set maxframeskip 0
set c 0
proc shot {{n}} {{
  catch {{screenshot {shots}_[format %02d $n].png}}
  W "frame $n t=[format %.3f [machine_info time]] pc=[format %04X [reg pc]]"
  if {{$n < {a.frames}}} {{ after frame "shot [expr {{$n+1}}]" }} else {{ after time 0.05 {{exit}} }}
}}
proc waiter {{}} {{ incr ::c; if {{$::c < {a.settle}}} {{ after frame waiter }} else {{ shot 1 }} }}
after frame waiter'''
    rc, log, d = run_tcl(tcl, a.machine, a.disk, a.timeout)
    from PIL import Image
    print(f"{'frame':>5} {'top blank':>10} {'bottom blank':>13}   (screen lines)")
    for n in range(1, a.frames + 1):
        p = f"{shots}_{n:02d}.png"
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("L"); w, h = im.size; px = im.load(); sc = h / 240.0
        def blank(rng):
            k = 0
            for y in rng:
                if max(px[x, y] for x in range(int(w * .15), int(w * .85), 8)) > 25:
                    break
                k += 1
            return k / sc
        print(f"  {n:3d} {blank(range(h)):10.0f} {blank(range(h-1, -1, -1)):13.0f}")


def cmd_sprites(a):
    """Sprite pixel map: render the SAME frame twice, once with SPD forced on.

    Both runs start from the same savestate, so the only difference is the
    sprite plane — comparing two *consecutive* frames instead would fold in
    scrolling and give a useless map.
    """
    on = os.path.join(a.outdir, "spr_on.png")
    off = os.path.join(a.outdir, "spr_off.png")
    base = f'''loadstate {a.state}
set throttle on
set minframeskip 0
set maxframeskip 0
set c 0
proc step {{}} {{ incr ::c
  if {{$::c < {a.settle}}} {{ after frame step }} else {{ catch {{screenshot %s}}; after time 0.05 {{exit}} }} }}
%s
after frame step'''
    run_tcl(base % (on, ""), a.machine, a.disk, a.timeout)
    # Re-assert SPD every frame: the game rewrites R#8 from its split code.
    forced = f'debug set_bp {a.spd_bp} {{}} {{ vdpreg 8 [expr {{[vdpreg 8] | 2}}] }}'
    run_tcl(base % (off, forced), a.machine, a.disk, a.timeout)
    from PIL import Image, ImageChops
    A = Image.open(on).convert("L"); B = Image.open(off).convert("L")
    d = ImageChops.difference(A, B); w, h = d.size; px = d.load(); sy = h / 240.0; sx = w / 320.0
    rows = {}
    for row in range(240):
        y = int(row * sy); xs = []
        for X in range(320):
            x = int(X * sx)
            if any(px[min(x + k, w - 1), min(y + j, h - 1)] > 12
                   for k in range(2) for j in range(max(1, int(sy)))):
                xs.append(X - 32)
        if xs:
            rows[row] = (min(xs), max(xs))
    if not rows:
        print("sprite pixels: none (check --spd-bp, or the scene has no sprites)")
        return
    print("capture row ranges (240-line buffer) with sprite pixels, x in screen coords 0..255")
    groups, prev = [], None
    for r in sorted(rows):
        if prev is None or r > prev + 1:
            groups.append([r, r])
        else:
            groups[-1][1] = r
        prev = r
    for g in groups:
        xs = [rows[r][0] for r in range(g[0], g[1] + 1)]
        xe = [rows[r][1] for r in range(g[0], g[1] + 1)]
        print(f"  rows {g[0]:3d}~{g[1]:3d}  x {min(xs):3d}~{max(xe):3d}")
    print(f"(top border is 14 rows for a 212-line screen: rows < 14 are overscan)")


def cmd_trace(a):
    out = os.path.join(a.outdir, "trace.txt")
    tcl = (f"loadstate {a.state}\n" if a.state else "") + "set throttle off\n"
    tcl += PREAMBLE.format(out=out) + '''
proc hit {tag} { W "[format %8.3f [machine_info time]] $tag pc=[format %04X [reg pc]] AF=[format %04X [reg af]] HL=[format %04X [reg hl]]" }
'''
    for addr in a.bp:
        tcl += f'debug set_bp {addr} {{}} "hit {addr}"\n'
    for port in a.rdio:
        tcl += f'debug set_watchpoint read_io {port} {{}} "hit rd{port}"\n'
    for port in a.wrio:
        tcl += f'debug set_watchpoint write_io {port} {{}} "hit wr{port}"\n'
    tcl += f"after time {a.seconds} {{ exit }}\n"
    run_tcl(tcl, a.machine, a.disk, a.timeout)
    sys.stdout.write(open(out).read() if os.path.exists(out) else "(no hits)\n")


def cmd_run(a):
    rc, log, d = run_tcl(open(a.script).read(), a.machine, a.disk, a.timeout)
    print(log)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--outdir", default="/tmp/omsxprobe")
    p.add_argument("--machine"); p.add_argument("--disk"); p.add_argument("--state")
    p.add_argument("--timeout", type=int, default=400)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("ports"); s.add_argument("--seconds", type=float, default=62); s.set_defaults(fn=cmd_ports)
    s = sub.add_parser("bands"); s.add_argument("--frames", type=int, default=6)
    s.add_argument("--settle", type=int, default=40); s.set_defaults(fn=cmd_bands)
    s = sub.add_parser("sprites"); s.add_argument("--settle", type=int, default=3)
    s.add_argument("--spd-bp", default="0x6D9D", help="bp where the game rewrites R#8 (ASO: end of its restore block)")
    s.set_defaults(fn=cmd_sprites)
    s = sub.add_parser("trace"); s.add_argument("--bp", nargs="*", default=[])
    s.add_argument("--rdio", nargs="*", default=[]); s.add_argument("--wrio", nargs="*", default=[])
    s.add_argument("--seconds", type=float, default=10); s.set_defaults(fn=cmd_trace)
    s = sub.add_parser("run"); s.add_argument("script"); s.set_defaults(fn=cmd_run)

    a = p.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    for f in ("ports.txt", "bands.txt", "trace.txt"):
        try: os.remove(os.path.join(a.outdir, f))
        except FileNotFoundError: pass
    a.fn(a)


if __name__ == "__main__":
    main()
