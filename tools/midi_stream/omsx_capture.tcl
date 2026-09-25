#  Capture what openMSX's own MSX-MIDI puts on the wire, for the same stimulus
#  the RTL bench gets.  Run it as:
#
#      OMSX_STREAM=<bytes.bin> OMSX_LOG=<out.bin> \
#      openmsx -machine Panasonic_FS-A1GT -script tools/midi_stream/omsx_capture.tcl
#
#  No MSX-side software is involved: the ports are poked directly through the
#  `ioports` debuggable, with the FS-A1GT BIOS's own setup sequence, so both
#  implementations see byte-for-byte the same stimulus and any difference is
#  theirs rather than the test program's.
#
#  Two things that cost an afternoon:
#
#  * openMSX binds every setting to a GLOBAL Tcl variable.  A plain `set` inside
#    a proc makes a LOCAL of the same name, which reads back as the value you
#    just wrote while the setting keeps its default -- midi-out-logger then
#    tries to open /dev/midi and the plug fails with "Error opening log file".
#    Hence the uplevel.
#  * `puts` goes to openMSX's own console, not to stdout, so anything you want
#    to see has to be written to a file.
set renderer none
set throttle off

set ::dbg [open $::env(OMSX_DBG) w]
proc log {m} { puts $::dbg $m ; flush $::dbg }

set fh [open $::env(OMSX_STREAM) rb]
fconfigure $fh -translation binary
binary scan [read $fh] cu* ::bytes
close $fh
set ::n [llength $::bytes]
set ::i 0
log "stream: $::n bytes"

proc io {port val} { debug write ioports $port $val }

#  The FS-A1GT BIOS sequence (PC 1A31-1A6B), then the command byte the BIOS
#  leaves to software: TxEN | DTR | RxEN | ER | RTS.
proc bios_init {} {
    foreach v {0 0 0 64 78 0} { io 0xE9 $v }
    io 0xEF 0x16 ; io 0xEC 0x08
    io 0xEF 0xB4 ; io 0xEE 0x20 ; io 0xEE 0x4E
    io 0xE9 0x37
}

#  400 us between bytes: one character at 31250 baud is 320 us, so the
#  transmitter is never asked to take a byte while the last one is still going.
proc send_one {} {
    if {$::i >= $::n} { after time 0.05 finish ; return }
    io 0xE8 [lindex $::bytes $::i]
    incr ::i
    after time 0.0004 send_one
}

proc finish {} {
    catch {unplug MSX-MIDI-out}
    log "sent $::i bytes"
    close $::dbg
    exit
}

proc go {} {
    uplevel #0 [list set midi-out-logfilename $::env(OMSX_LOG)]
    log "logfile: [uplevel #0 {set midi-out-logfilename}]"
    if {[catch {plug MSX-MIDI-out midi-out-logger} e]} {
        log "PLUG FAIL: $e" ; close $::dbg ; exit 1
    }
    bios_init
    log "init ok, E9 status = [debug read ioports 0xE9]"
    after time 0.001 send_one
}
after time 8 go
