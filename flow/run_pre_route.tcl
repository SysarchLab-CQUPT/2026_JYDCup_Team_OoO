set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set project_file [file join $project_root build vivado jyd2025_ooo_soc_v23.xpr]

if {![file exists $project_file]} {
  error "Vivado project does not exist; run flow/run_synth.tcl first"
}

open_project $project_file
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "synth_design Complete*" $synth_status]} {
  error "Synthesis is not complete: $synth_status"
}

# Stop before route_design.  The purpose of this run is to expose the complete
# opt/place/phys_opt setup and hold populations after an explicit hold-fix pass,
# so routing is not used as an opaque first attempt at repairing hold.
reset_run impl_1
set impl_run [get_runs impl_1]
set_property STEPS.POWER_OPT_DESIGN.IS_ENABLED false $impl_run
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $impl_run
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithHoldFix $impl_run
if {[info exists ::env(JYD_USE_USER_CLUSTER)] &&
    [string equal [string trim $::env(JYD_USE_USER_CLUSTER)] "1"]} {
  set_property STEPS.OPT_DESIGN.TCL.POST \
    [file join $script_dir apply_backend_issue_cluster.tcl] $impl_run
  puts "USER_CLUSTER_MODE=legacy_opt_in"
} else {
  set_property STEPS.OPT_DESIGN.TCL.POST {} $impl_run
  puts "USER_CLUSTER_MODE=disabled"
}
puts "POWER_OPT_ENABLED=[get_property STEPS.POWER_OPT_DESIGN.IS_ENABLED $impl_run]"
puts "OPT_DESIGN_DIRECTIVE=[get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "PHYS_OPT_DIRECTIVE=[get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "OPT_DESIGN_POST_HOOK=[get_property STEPS.OPT_DESIGN.TCL.POST $impl_run]"

launch_runs impl_1 -to_step phys_opt_design -jobs 8
wait_on_run impl_1
set impl_status [get_property STATUS $impl_run]
puts "PRE_ROUTE_STATUS=$impl_status"
set impl_run_dir [get_property DIRECTORY $impl_run]
set top [get_property TOP [get_filesets sources_1]]
set physopt_checkpoint [file join $impl_run_dir ${top}_physopt.dcp]
# After a successful -to_step phys_opt_design run, Vivado reports STATUS as
# "Not started route_design" because STATUS names the next pending step.  The
# fresh physopt checkpoint is the unambiguous completion artifact.
if {![file exists $physopt_checkpoint]} {
  error "Pre-route implementation did not produce $physopt_checkpoint (status: $impl_status)"
}

set report_dir [file join $project_root reports impl pre_route]
file mkdir $report_dir

set ::JYD_TIMING_VIOLATION_LIBRARY_ONLY 1
source [file join $script_dir extract_timing_violations.tcl]
unset ::JYD_TIMING_VIOLATION_LIBRARY_ONLY

foreach {stage dcp_suffix} {
  opt     opt
  place   placed
  physopt physopt
} {
  set checkpoint [file join $impl_run_dir ${top}_${dcp_suffix}.dcp]
  jyd_extract_timing_violations \
    $checkpoint \
    [file join $report_dir ${stage}_violations.tsv] \
    $stage \
    [file join $report_dir ${stage}_timing_summary.rpt]
}

puts "PRE_ROUTE_REPORT_DIR=$report_dir"
puts "ROUTE_DESIGN_NOT_RUN=1"
