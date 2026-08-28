set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set synth_dcp [file join $project_root reports synth jyd_soc_top_synth.dcp]
set pre_route_dir [file join $project_root reports impl pre_route]
set route_dir [file join $project_root reports impl]

if {![file exists $synth_dcp]} {
  error "Missing synthesized checkpoint: $synth_dcp"
}
file mkdir $pre_route_dir
file mkdir $route_dir

set ::JYD_TIMING_VIOLATION_LIBRARY_ONLY 1
source [file join $script_dir extract_timing_violations.tcl]
unset ::JYD_TIMING_VIOLATION_LIBRARY_ONLY

proc jyd_checkpoint_and_report {checkpoint report_dir stage_name} {
  write_checkpoint -force $checkpoint
  close_design
  jyd_extract_timing_violations \
    $checkpoint \
    [file join $report_dir ${stage_name}_violations.tsv] \
    $stage_name \
    [file join $report_dir ${stage_name}_timing_summary.rpt]
  open_checkpoint $checkpoint
}

proc jyd_setup_qor {} {
  set paths [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
  if {[llength $paths] == 0} {
    return [list 1.0e9 0.0]
  }
  set worst [get_property SLACK [lindex $paths 0]]
  set failing [get_timing_paths -quiet -delay_type max \
    -slack_lesser_than 0.0 -max_paths 100000 -nworst 100000]
  set tns 0.0
  foreach path $failing {
    set tns [expr {$tns + [get_property SLACK $path]}]
  }
  return [list $worst $tns]
}

proc jyd_qor_better {candidate reference} {
  set c_wns [lindex $candidate 0]
  set c_tns [lindex $candidate 1]
  set r_wns [lindex $reference 0]
  set r_tns [lindex $reference 1]
  return [expr {($c_wns > $r_wns + 0.001) ||
                ((abs($c_wns - $r_wns) <= 0.001) && ($c_tns > $r_tns))}]
}

open_checkpoint $synth_dcp

puts "OPT_DESIGN_DIRECTIVE=ExploreWithRemap"
opt_design -directive ExploreWithRemap
set use_user_cluster 0
if {[info exists ::env(JYD_USE_USER_CLUSTER)] &&
    [string equal [string trim $::env(JYD_USE_USER_CLUSTER)] "1"]} {
  set use_user_cluster 1
}
if {$use_user_cluster} {
  puts "USER_CLUSTER_MODE=legacy_opt_in"
  source [file join $script_dir apply_backend_issue_cluster.tcl]
} else {
  # The preserved routed baseline reached nearly 99% directional congestion
  # while these broad hierarchy clusters were active.  Leave placement driven
  # by timing/connectivity by default; retain the old hook only for controlled
  # A/B experiments via JYD_USE_USER_CLUSTER=1.
  puts "USER_CLUSTER_MODE=disabled"
}
set opt_dcp [file join $pre_route_dir jyd_soc_top_opt.dcp]
jyd_checkpoint_and_report $opt_dcp $pre_route_dir opt

puts "PLACE_DESIGN_DIRECTIVE=Explore (highest supported by 7-series placer)"
place_design -directive Explore
set placed_dcp [file join $pre_route_dir jyd_soc_top_placed.dcp]
jyd_checkpoint_and_report $placed_dcp $pre_route_dir place

puts "PHYS_OPT_DIRECTIVES=AggressiveExplore,ExploreWithAggressiveHoldFix"
set physopt_start [clock seconds]
phys_opt_design -directive AggressiveExplore
phys_opt_design -directive ExploreWithAggressiveHoldFix
set physopt_elapsed [expr {[clock seconds] - $physopt_start}]
puts "PHYS_OPT_ELAPSED_SECONDS=$physopt_elapsed"
if {$physopt_elapsed > 3600} {
  error "phys_opt_design exceeded the one-hour limit: $physopt_elapsed seconds"
}
set physopt_dcp [file join $pre_route_dir jyd_soc_top_physopt.dcp]
jyd_checkpoint_and_report $physopt_dcp $pre_route_dir physopt

puts "ROUTE_DESIGN_DIRECTIVE=AggressiveExplore"
route_design -directive AggressiveExplore
set routed_dcp [file join $route_dir jyd_soc_top_route.dcp]
jyd_checkpoint_and_report $routed_dcp $route_dir route
set route_qor [jyd_setup_qor]
puts "ROUTE_QOR_WNS=[lindex $route_qor 0] ROUTE_QOR_TNS=[lindex $route_qor 1]"

# Interconnect dominated setup paths can remain after the first aggressive
# route.  Run one bounded post-route physical pass and re-route, preserving
# both additional checkpoints and the complete setup/hold path population.
puts "POST_ROUTE_PHYS_OPT_DIRECTIVE=AggressiveExplore"
set postroute_physopt_start [clock seconds]
phys_opt_design -directive AggressiveExplore
set postroute_physopt_elapsed [expr {[clock seconds] - $postroute_physopt_start}]
puts "POST_ROUTE_PHYS_OPT_ELAPSED_SECONDS=$postroute_physopt_elapsed"
if {$postroute_physopt_elapsed > 3600} {
  error "post-route phys_opt_design exceeded the one-hour limit: $postroute_physopt_elapsed seconds"
}
set postroute_physopt_dcp \
  [file join $route_dir jyd_soc_top_postroute_physopt.dcp]
jyd_checkpoint_and_report \
  $postroute_physopt_dcp $route_dir postroute_physopt
set postroute_qor [jyd_setup_qor]
puts "POSTROUTE_QOR_WNS=[lindex $postroute_qor 0] POSTROUTE_QOR_TNS=[lindex $postroute_qor 1]"

set best_dcp $routed_dcp
set best_qor $route_qor
set best_stage route
if {[jyd_qor_better $postroute_qor $best_qor]} {
  set best_dcp $postroute_physopt_dcp
  set best_qor $postroute_qor
  set best_stage postroute_physopt
}

# A second route is only justified when the post-route physical pass improved
# the routed checkpoint.  Keep every candidate, then explicitly reopen the
# best measured DCP instead of treating the last command as the release result.
if {[string equal $best_stage postroute_physopt]} {
  puts "POST_ROUTE_ROUTE_DIRECTIVE=AggressiveExplore"
  route_design -directive AggressiveExplore
  set reroute_dcp [file join $route_dir jyd_soc_top_reroute.dcp]
  jyd_checkpoint_and_report $reroute_dcp $route_dir reroute
  set reroute_qor [jyd_setup_qor]
  puts "REROUTE_QOR_WNS=[lindex $reroute_qor 0] REROUTE_QOR_TNS=[lindex $reroute_qor 1]"
  if {[jyd_qor_better $reroute_qor $best_qor]} {
    set best_dcp $reroute_dcp
    set best_qor $reroute_qor
    set best_stage reroute
  }
}

close_design
open_checkpoint $best_dcp
set final_routed_dcp [file join $route_dir jyd_soc_top_final_route.dcp]
jyd_checkpoint_and_report $final_routed_dcp $route_dir final_route
puts "BEST_ROUTED_STAGE=$best_stage BEST_ROUTED_WNS=[lindex $best_qor 0] BEST_ROUTED_TNS=[lindex $best_qor 1]"

report_utilization -hierarchical -file [file join $route_dir utilization_hier.rpt]
report_drc -file [file join $route_dir drc.rpt]
report_methodology -file [file join $route_dir methodology.rpt]
report_design_analysis -setup -max_paths 100 \
  -file [file join $route_dir design_analysis_setup_100.rpt]
report_high_fanout_nets -max_nets 100 \
  -file [file join $route_dir high_fanout_nets_100.rpt]
report_qor_suggestions -file [file join $route_dir qor_suggestions.rpt]

# The hard sign-off gate runs only after all stage reports and the routed DCP
# have been preserved.  A negative route remains diagnostic evidence and can
# never silently become a release bitstream.
source [file join $script_dir signoff_checks.tcl]
require_routed_signoff $route_dir

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force \
  [file join $route_dir jyd_soc_top_rtthread_coremark_150mhz.bit]
puts "DETACHED_IMPL_COMPLETE=1"
