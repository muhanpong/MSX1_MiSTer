# Two-corner signoff.  read_sdc is repeated per model: a fast-model netlist
# created without it is UNCONSTRAINED and once reported a -40 ns hold that did
# not exist (docs/az80_migration_20260913.md).
project_open MSX1 -revision MSX1
foreach model {slow fast} {
  create_timing_netlist -model $model
  read_sdc
  update_timing_netlist
  foreach t {setup hold recovery removal} {
    foreach_in_collection x [get_timing_paths -npaths 1 -$t] { puts "WORST_${model}_$t [get_path_info $x -slack]" }
  }
  delete_timing_netlist
}
project_close
