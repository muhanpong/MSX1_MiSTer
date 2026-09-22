set throttle off
set minframeskip 0
set maxframeskip 0
proc s {t} { set f [open "$::DIR/$::TAG.log" a]; puts $f [format "t=%4.1f pc=%04X sp=%04X iff=%s" [machine_info time] [reg pc] [reg sp] [reg iff]]; close $f
  catch {screenshot [format "%s/%s_%02d.png" $::DIR $::TAG $t]} }
foreach t {3 6 9 12 15} { after time $t "s $t" }
after time 15.5 exit
