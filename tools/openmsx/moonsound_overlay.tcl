# moonsound_overlay.tcl
# ----------------------------------------------------------------------------
# openMSX OSD overlay that mirrors the MiSTer MSX1 core's debug_overlay.sv
# (rtl/debug_overlay.sv) — same top-left panel, same 6 colour-bar rows — so
# FPGA vs reference behaviour can be compared side by side while debugging the
# YMF278B/OPL4 (MoonSound) PCM path.
#
# FPGA panel rows (rtl/debug_overlay.sv):
#   1 ROM Base Set   green=base loaded / red=missing
#   2 PCM valid      green (held) when PCM engine produced output
#   3 PCM level      yellow bar (peak-held)
#   4 NEW2           cyan when OPL3 NEW2 set
#   5 per-slot map   24 slots x2px: green=keyon&producing, RED=keyon&DEAD, gray=off
#   6 dead count     red bar (length = #voices keyed-on but silent)
#
# openMSX data sources (debuggables registered by YMF278.cc / YMF262):
#   "<dev> wave regs" 256 OPL4 PCM registers (keyon = reg[0x68+i] & 0x80)
#   "<dev> wave mem"  4 MB OPL4 memory (ROM 0..0x1FFFFF + RAM)  <- header/sample dump
#   "<dev> FM regs"   OPL3 FM registers (NEW2 = reg 0x105 bit1)
# (<dev> is e.g. "Sunrise MoonSound"; resolved at runtime from `debug list`.)
#
# Notes on fidelity:
#   - openMSX is the *reference*: every keyed-on voice produces output, so the
#     DEAD map (row 5 red) / dead count (row 6) are normally empty here.  That
#     is exactly the useful contrast: where the FPGA shows RED, openMSX won't.
#   - ROM Base / PCM level / NEW2 have no exact debuggable; they are derived
#     (see below) and marked PROXY.  The diagnostic value is in rows 5/6 and
#     the info line.
#
# Usage (openMSX console):
#   source <path>/moonsound_overlay.tcl   ;# if not auto-loaded from scripts dir
#   toggle_moonsound_overlay
# ----------------------------------------------------------------------------

namespace eval moonsound_overlay {

variable active 0
variable after_id ""
variable d_regs ""       ;# "<dev> wave regs"   (PCM registers)
variable d_mem  ""       ;# "<dev> wave mem"    (4 MB OPL4 memory)
variable d_fm   ""       ;# "<dev> FM regs"     (OPL3 FM regs, NEW2)

# Resolve the MoonSound debuggable names from `debug list` ("" = not found).
# Names look like "Sunrise MoonSound wave regs" / "... wave mem" / "... FM regs".
proc find_dev {} {
	variable d_regs; variable d_mem; variable d_fm
	set d_regs ""; set d_mem ""; set d_fm ""
	foreach dd [debug list] {
		if {![string match "*MoonSound*" $dd]} continue
		if {[string match "*wave regs" $dd]} { set d_regs $dd }
		if {[string match "*wave mem"  $dd]} { set d_mem  $dd }
		if {[string match "*FM regs"   $dd]} { set d_fm   $dd }
	}
	return [expr {$d_regs ne "" && $d_mem ne ""}]
}

proc r {addr} { variable d_regs; return [debug read $d_regs $addr] }
proc m {addr} { variable d_mem;  return [debug read $d_mem  $addr] }

proc create_widgets {} {
	# Scaled root: 320x240 virtual coords, so layout is resolution-independent.
	osd create rectangle moonsound_overlay \
		-x 2 -y 2 -w 66 -h 50 -scaled true \
		-rgba 0x000000c0 -bordersize 1 -borderrgba 0xffffffff

	# Rows are 8px tall, inner area x=1..65 (w=64).
	osd create rectangle moonsound_overlay.base  -x 1 -y 1  -w 64 -h 8 -rgba 0x202020ff
	osd create rectangle moonsound_overlay.valid -x 1 -y 9  -w 64 -h 8 -rgba 0x202020ff
	osd create rectangle moonsound_overlay.lvlbg -x 1 -y 17 -w 64 -h 8 -rgba 0x202020ff
	osd create rectangle moonsound_overlay.lvl   -x 1 -y 17 -w 0  -h 8 -rgba 0xffe000ff
	osd create rectangle moonsound_overlay.new2  -x 1 -y 25 -w 64 -h 8 -rgba 0x202020ff
	# Row 5: 24 per-slot cells, 2px each.
	for {set i 0} {$i < 24} {incr i} {
		osd create rectangle moonsound_overlay.slot$i \
			-x [expr {1 + 2*$i}] -y 33 -w 2 -h 8 -rgba 0x202020ff
	}
	# Row 6: dead-voice count bar.
	osd create rectangle moonsound_overlay.deadbg -x 1 -y 41 -w 64 -h 8 -rgba 0x202020ff
	osd create rectangle moonsound_overlay.dead   -x 1 -y 41 -w 0  -h 8 -rgba 0xff0000ff

	# Diagnostic line below the panel: first active slot's wave# + startAddr,
	# mirroring the FPGA dbg_slot0_wave / dbg_slot0_hdr_start outputs.
	osd create text moonsound_overlay.info \
		-x 1 -y 51 -size 5 -rgba 0x00ff00ff -text ""
}

proc destroy_widgets {} {
	catch {osd destroy moonsound_overlay}
}

# Colour constants (literal 0xRRGGBBAA — never feed a decimal [expr] result to
# osd -rgba; some openMSX builds reject it, which would abort update() and
# freeze the loop).
variable C_GREEN  0x00ff00ff
variable C_DGREEN 0x004000ff
variable C_CYAN   0x00ffffff
variable C_DCYAN  0x003030ff
variable C_GRAY   0x202020ff

# update() is the loop driver: it ALWAYS re-arms after frame, even if redraw
# throws, so a transient read/osd error can never freeze the overlay.
proc update {} {
	variable active
	variable after_id
	if {!$active} return
	if {[catch {redraw} err]} {
		# keep the message visible but don't kill the loop
		catch {osd configure moonsound_overlay.info -text "err: $err"}
	}
	set after_id [after frame [namespace code update]]
}

proc redraw {} {
	variable d_fm
	variable C_GREEN; variable C_DGREEN; variable C_CYAN; variable C_DCYAN; variable C_GRAY

	# --- gather per-slot key-on (reg 0x68+i bit7) ---
	set anyon 0
	set non 0
	for {set i 0} {$i < 24} {incr i} {
		set ko [expr {([r [expr {0x68 + $i}]] & 0x80) != 0}]
		set keyon($i) $ko
		if {$ko} { set anyon 1; incr non }
	}

	# Row 1 ROM Base Set (PROXY): device present => ROM mapped => green.
	osd configure moonsound_overlay.base -rgba $C_GREEN

	# Row 2 PCM valid: green when any voice keyed-on.
	if {$anyon} {
		osd configure moonsound_overlay.valid -rgba $C_GREEN
	} else {
		osd configure moonsound_overlay.valid -rgba $C_DGREEN
	}

	# Row 3 PCM level (PROXY = active-voice count, 0..24 -> 0..48px).
	osd configure moonsound_overlay.lvl -w [expr {$non * 2}]

	# Row 4 NEW2: OPL3 reg 0x105 bit1 (real value from FM regs debuggable).
	set new2 0
	if {$d_fm ne ""} {
		catch {set new2 [expr {([debug read $d_fm 0x105] & 0x02) != 0}]}
	}
	if {$new2} {
		osd configure moonsound_overlay.new2 -rgba $C_CYAN
	} else {
		osd configure moonsound_overlay.new2 -rgba $C_DCYAN
	}

	# Row 5 per-slot map. openMSX reference: keyon => green (never dead/red).
	set firstactive -1
	for {set i 0} {$i < 24} {incr i} {
		if {$keyon($i)} {
			osd configure moonsound_overlay.slot$i -rgba $C_GREEN
			if {$firstactive < 0} { set firstactive $i }
		} else {
			osd configure moonsound_overlay.slot$i -rgba $C_GRAY
		}
	}

	# Row 6 dead-voice count: 0 in the reference.
	osd configure moonsound_overlay.dead -w 0

	# --- info line: wave# + header startAddr for first active slot ---
	if {$firstactive >= 0} {
		set i $firstactive
		set wave [expr {[r [expr {0x08 + $i}]] | (([r [expr {0x20 + $i}]] & 1) << 8)}]
		set wavetblhdr [expr {([r 0x02] >> 2) & 7}]
		if {$wave < 384 || $wavetblhdr == 0} {
			set hdr [expr {$wave * 12}]
		} else {
			set hdr [expr {$wavetblhdr * 0x80000 + ($wave - 384) * 12}]
		}
		set b0 [m $hdr]
		set sa [expr {(($b0 & 0x3f) << 16) | ([m [expr {$hdr+1}]] << 8) | [m [expr {$hdr+2}]]}]
		set bits [expr {($b0 >> 6) & 3}]
		osd configure moonsound_overlay.info -text \
			[format "s%02d w%d b%d hdr%06X sa%06X" $i $wave $bits $hdr $sa]
	} else {
		osd configure moonsound_overlay.info -text "idle"
	}
}

proc toggle {} {
	variable active
	variable after_id
	variable d_regs
	if {$active} {
		set active 0
		catch {after cancel $after_id}
		destroy_widgets
		return "MoonSound overlay OFF"
	}
	if {![find_dev]} {
		return "No MoonSound device found (insert the MoonSound extension first)."
	}
	destroy_widgets
	create_widgets
	set active 1
	update
	return "MoonSound overlay ON (device: $d_regs)"
}

} ;# namespace

proc toggle_moonsound_overlay {} { return [moonsound_overlay::toggle] }
set_help_text toggle_moonsound_overlay \
	"Toggle the MoonSound (YMF278B/OPL4) debug overlay that mirrors the MiSTer core's debug_overlay.sv panel."
