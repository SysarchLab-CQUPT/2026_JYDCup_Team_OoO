if {$argc != 1} {
  error "usage: diagnose_backend_module.tcl <top>"
}
set top [lindex $argv 0]
set root_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root_dir build diagnose_backend $top]
file mkdir $out_dir

read_verilog -sv [list \
  [file join $root_dir rtl pkg soc_cfg_pkg.sv] \
  [file join $root_dir rtl pkg core_types_pkg.sv] \
  [file join $root_dir rtl pkg rv32_pkg.sv] \
  [file join $root_dir rtl pkg backend_types_pkg.sv] \
  [file join $root_dir rtl core rename physical_regfile_lane.sv] \
  [file join $root_dir rtl core rename physical_regfile.sv] \
  [file join $root_dir rtl core rename rename_map.sv] \
  [file join $root_dir rtl core rename branch_checkpoints.sv] \
  [file join $root_dir rtl core backend rob.sv] \
  [file join $root_dir rtl core backend issue_queue.sv] \
  [file join $root_dir rtl core lsu load_queue.sv] \
  [file join $root_dir rtl core lsu store_queue.sv]]
synth_design -top $top -part xc7k325tffg900-2 -mode out_of_context \
  -flatten_hierarchy rebuilt
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
write_checkpoint -force [file join $out_dir ${top}.dcp]
