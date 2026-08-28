set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
source [file join $script_dir create_project.tcl]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$synth_status"
if {![string match "synth_design Complete*" $synth_status]} {
  error "Synthesis did not complete successfully: $synth_status"
}

open_run synth_1
set report_dir [file join $project_root reports synth]
file mkdir $report_dir
report_utilization -hierarchical -file [file join $report_dir utilization_hier.rpt]
set synth_checkpoint [file join $report_dir jyd_soc_top_synth.dcp]
write_checkpoint -force $synth_checkpoint

# Preserve the complete setup/hold violation population at synthesis as well as
# at opt/place/phys_opt/route.  Intermediate stages are diagnostic; only the
# final routed checkpoint is a bitstream gate.
close_design
set ::JYD_TIMING_VIOLATION_LIBRARY_ONLY 1
source [file join $script_dir extract_timing_violations.tcl]
unset ::JYD_TIMING_VIOLATION_LIBRARY_ONLY
jyd_extract_timing_violations \
  $synth_checkpoint \
  [file join $report_dir synth_violations.tsv] \
  synth \
  [file join $report_dir timing_summary.rpt]
puts "Synthesis reports written to $report_dir"
