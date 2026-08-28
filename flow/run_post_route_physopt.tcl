set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set input_dcp [file join $project_root reports impl jyd_soc_top_route.dcp]
set output_dir [file join $project_root reports impl post_route]

if {![file exists $input_dcp]} {
  error "Missing routed checkpoint: $input_dcp"
}
file mkdir $output_dir

set ::JYD_TIMING_VIOLATION_LIBRARY_ONLY 1
source [file join $script_dir extract_timing_violations.tcl]
unset ::JYD_TIMING_VIOLATION_LIBRARY_ONLY

proc jyd_postroute_checkpoint_and_report {checkpoint report_dir stage_name} {
  write_checkpoint -force $checkpoint
  close_design
  jyd_extract_timing_violations \
    $checkpoint \
    [file join $report_dir ${stage_name}_violations.tsv] \
    $stage_name \
    [file join $report_dir ${stage_name}_timing_summary.rpt]
  open_checkpoint $checkpoint
}

open_checkpoint $input_dcp

# The routed design is dominated by interconnect delay.  Give Vivado one
# bounded post-route physical pass before changing RTL again.  Keep both the
# physical-optimization and re-route checkpoints/reports as separate stages.
set postroute_physopt_start [clock seconds]
phys_opt_design -directive AggressiveExplore
set postroute_physopt_elapsed \
  [expr {[clock seconds] - $postroute_physopt_start}]
puts "POST_ROUTE_PHYS_OPT_ELAPSED_SECONDS=$postroute_physopt_elapsed"
if {$postroute_physopt_elapsed > 3600} {
  error "post-route phys_opt_design exceeded the one-hour limit: $postroute_physopt_elapsed seconds"
}
set physopt_dcp [file join $output_dir jyd_soc_top_postroute_physopt.dcp]
jyd_postroute_checkpoint_and_report \
  $physopt_dcp $output_dir postroute_physopt

route_design -directive AggressiveExplore
set routed_dcp [file join $output_dir jyd_soc_top_postroute_route.dcp]
jyd_postroute_checkpoint_and_report \
  $routed_dcp $output_dir postroute_route

report_utilization -hierarchical \
  -file [file join $output_dir utilization_hier.rpt]

# Only a clean final routed design can become a bitstream.
source [file join $script_dir signoff_checks.tcl]
require_routed_signoff $output_dir

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force \
  [file join $output_dir jyd_soc_top_rtthread_coremark_150mhz.bit]
puts "POST_ROUTE_IMPL_COMPLETE=1"
