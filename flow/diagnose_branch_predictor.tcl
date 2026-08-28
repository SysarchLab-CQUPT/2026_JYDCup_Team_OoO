set root_dir [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root_dir build diagnose_branch_predictor]
file mkdir $out_dir

read_verilog -sv [file join $root_dir rtl core frontend branch_predictor.sv]
synth_design -top branch_predictor -part xc7k325tffg900-2 -mode out_of_context \
  -flatten_hierarchy rebuilt
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_timing_summary -delay_type min_max -max_paths 10 \
  -file [file join $out_dir timing_summary.rpt]
write_checkpoint -force [file join $out_dir branch_predictor.dcp]
