#!/usr/bin/env bash
#  Standalone area of one VDP block on the MiSTer device (5CSEBA6U23I7), all ports virtual
#  pins, the MSX1.qsf optimisation settings.  mk.sh <name> <top> <files...>
set -u
n=$1; top=$2; shift 2
Q=/home/sysop/data/intelFPGA_lite/17.0/quartus/bin
rm -rf $n; mkdir -p $n; cd $n
{
echo 'set_global_assignment -name FAMILY "Cyclone V"'
echo 'set_global_assignment -name DEVICE 5CSEBA6U23I7'
echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
echo 'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"'
echo 'set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED'
echo 'set_global_assignment -name ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP ON'
echo 'set_global_assignment -name PRE_MAPPING_RESYNTHESIS ON'
echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
echo 'set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005'
for f in "$@"; do
  case $f in *.vhd) echo "set_global_assignment -name VHDL_FILE $f -hdl_version VHDL_2008";; *) echo "set_global_assignment -name VERILOG_FILE $f";; esac
done
} > $n.qsf
echo "PROJECT_REVISION = \"$n\"" > $n.qpf
t0=$(date +%s)
$Q/quartus_map $n -c $n > map.log 2>&1 || { echo "$n MAP FAIL: $(grep -m3 '^Error' map.log)"; exit 1; }
$Q/quartus_fit $n -c $n > fit.log 2>&1 || { echo "$n FIT FAIL: $(grep -m3 '^Error' fit.log)"; exit 1; }
r=output_files/$n.fit.rpt; [ -f $r ] || r=$n.fit.rpt
echo "$n ($(( $(date +%s)-t0 ))s): $(grep -m1 'Logic utilization (ALMs needed' $r | tr -s ' ;' ' ') | regs $(grep -m1 'Total registers' $r | tr -s ' ;' ' ') | $(grep -m1 'M10K blocks' $r | tr -s ' ;' ' ') | $(grep -m1 'Total block memory bits' $r | tr -s ' ;' ' ') | $(grep -m1 'Total DSP Blocks' $r | tr -s ' ;' ' ')"
