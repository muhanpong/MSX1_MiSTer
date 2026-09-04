set fh [open $::env(RLOG) w]
proc lg {s} { global fh; puts $fh "[format %.6f [machine_info time]] $s"; flush $fh }
catch {set throttle off}

after time 30 { type "SC PASSINGB.SDT\r"; lg "MARK typed" }
after time 33 {
    catch { set {Konami SCC+ Cartridge with expanded RAM (1)_volume} 0 }
    catch { set PSG_volume 0 }
    catch { set {MSX Music_volume} 0 }
    catch { set master_volume 100 }
    lg "MARK soloed"
}

proc wlog {} {
    global fh
    puts $fh "W [format %.7f [machine_info time]] [format %04X $::wp_last_address] [format %02X $::wp_last_value] [format %02X [debug read ioports 168]]"
}

set state 0
proc watch {} {
    global state
    set wa 0
    for {set i 0} {$i < 8} {incr i} { incr wa [debug read {Konami SCC+ Cartridge with expanded RAM SCC} $i] }
    lg "poll wA=$wa state=$state"
    if {$state == 0 && $wa != 2040} {
        set state 1
        after time 2 {
            debug set_watchpoint write_mem {0xB800 0xB8FF} {} {wlog}
            debug set_watchpoint write_mem {0x9800 0x98FF} {} {wlog}
            lg "MARK armed"
            set r [catch {record start -audioonly -prefix sccrep} msg]
            lg "MARK record rc=$r msg=$msg"
            lg "SYNC [format %.7f [machine_info time]]"
            after time 20 { catch {record stop}; lg "MARK stopped"; exit }
        }
        return
    }
    if {[machine_info time] > 300} { lg "MARK timeout-noplay"; exit }
    after time 2 watch
}
after time 40 watch
