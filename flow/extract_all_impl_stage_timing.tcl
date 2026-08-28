set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set run_dir [file join $project_root build vivado jyd2025_ooo_soc_v23.runs impl_1]
set report_dir [file join $project_root reports impl stages]
file mkdir $report_dir

set ::JYD_TIMING_VIOLATION_LIBRARY_ONLY 1
source [file join $script_dir extract_timing_violations.tcl]
unset ::JYD_TIMING_VIOLATION_LIBRARY_ONLY

foreach {stage dcp_name} {
  opt      jyd_soc_top_opt.dcp
  place    jyd_soc_top_placed.dcp
  phys_opt jyd_soc_top_physopt.dcp
  route    jyd_soc_top_routed.dcp
} {
  set dcp [file join $run_dir $dcp_name]
  if {![file exists $dcp]} {
    error "Missing implementation-stage checkpoint: $dcp"
  }
  jyd_extract_timing_violations \
    $dcp \
    [file join $report_dir ${stage}_violations.tsv] \
    $stage \
    [file join $report_dir ${stage}_timing_summary.rpt]
}

puts "ALL_IMPL_STAGE_TIMING_REPORTS=$report_dir"
