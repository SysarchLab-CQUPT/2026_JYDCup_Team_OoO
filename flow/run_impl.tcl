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

# Capture project metadata before open_run/open_checkpoint changes the active
# design context.  The fileset GENERIC property is not available from a
# standalone routed-checkpoint context.
set source_generics [get_property GENERIC [get_filesets sources_1]]
if {![regexp {CLK_HZ=([0-9]+)} $source_generics -> soc_clk_hz]} {
  error "Cannot determine CLK_HZ from sources_1 generics: $source_generics"
}
set soc_clk_mhz [expr {$soc_clk_hz / 1000000}]

set impl_run [get_runs impl_1]
set resume_from_physopt false
if {[info exists ::env(JYD_RESUME_FROM_PHYSOPT)] &&
    [string equal [string trim $::env(JYD_RESUME_FROM_PHYSOPT)] "1"]} {
  set resume_from_physopt true
}

if {$resume_from_physopt} {
  set impl_run_dir [get_property DIRECTORY $impl_run]
  set top [get_property TOP [get_filesets sources_1]]
  set physopt_checkpoint [file join $impl_run_dir ${top}_physopt.dcp]
  if {![file exists $physopt_checkpoint]} {
    error "Cannot resume implementation; missing $physopt_checkpoint"
  }
  puts "RESUME_FROM_PHYSOPT=$physopt_checkpoint"
} else {
  # Vivado 2025.2 crashes in power_opt_design on this high-fanout OoO netlist
  # (Pwropt 34-321 followed by EXCEPTION_ACCESS_VIOLATION).  Apply the run-step
  # override after reset_run so it is present in the generated implementation
  # run, and persist it for GUI/restart use as well.
  reset_run impl_1
  set_property STEPS.POWER_OPT_DESIGN.IS_ENABLED false $impl_run
  set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized $impl_run
  set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithHoldFix $impl_run
  if {[info exists ::env(JYD_USE_USER_CLUSTER)] &&
      [string equal [string trim $::env(JYD_USE_USER_CLUSTER)] "1"]} {
    set_property STEPS.OPT_DESIGN.TCL.POST \
      [file join $script_dir apply_backend_issue_cluster.tcl] $impl_run
    puts "USER_CLUSTER_MODE=legacy_opt_in"
  } else {
    # Clear a hook persisted by an earlier project run.  Broad hierarchy
    # clusters are now an explicit A/B option because the routed baseline
    # showed severe local congestion with them enabled.
    set_property STEPS.OPT_DESIGN.TCL.POST {} $impl_run
    puts "USER_CLUSTER_MODE=disabled"
  }
}
puts "POWER_OPT_ENABLED=[get_property STEPS.POWER_OPT_DESIGN.IS_ENABLED $impl_run]"
puts "OPT_DESIGN_DIRECTIVE=[get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "PHYS_OPT_DIRECTIVE=[get_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
puts "OPT_DESIGN_POST_HOOK=[get_property STEPS.OPT_DESIGN.TCL.POST $impl_run]"
set impl_status [get_property STATUS $impl_run]
if {![string match "route_design Complete*" $impl_status]} {
  launch_runs impl_1 -to_step route_design -jobs 8
  wait_on_run impl_1
  set impl_status [get_property STATUS $impl_run]
} else {
  puts "ROUTE_ALREADY_COMPLETE=1"
}
puts "IMPL_STATUS=$impl_status"
if {![string match "route_design Complete*" $impl_status]} {
  error "Implementation did not complete successfully: $impl_status"
}

open_run impl_1
set report_dir [file join $project_root reports impl]
file mkdir $report_dir
report_utilization -hierarchical -file [file join $report_dir utilization_hier.rpt]
set routed_checkpoint [file join $report_dir jyd_soc_top_route.dcp]
write_checkpoint -force $routed_checkpoint

# Always preserve the complete routed setup/hold population before the hard
# sign-off gate.  If sign-off fails, all path families are available for one
# complete remediation pass instead of a worst-path-at-a-time loop.
close_design
set ::JYD_TIMING_VIOLATION_LIBRARY_ONLY 1
source [file join $script_dir extract_timing_violations.tcl]
unset ::JYD_TIMING_VIOLATION_LIBRARY_ONLY
jyd_extract_timing_violations \
  $routed_checkpoint \
  [file join $report_dir route_violations.tsv] \
  route \
  [file join $report_dir timing_summary.rpt]
open_checkpoint $routed_checkpoint

# A routed netlist is diagnostic evidence, not a releasable FPGA image, until
# final STA and DRC pass.  The failing DCP and reports remain available for
# analysis, while write_bitstream is deliberately unreachable on failure.
source [file join $script_dir signoff_checks.tcl]
require_routed_signoff $report_dir

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force \
  [file join $report_dir jyd_soc_top_rtthread_coremark_${soc_clk_mhz}mhz.bit]
puts "Implementation reports written to $report_dir"
