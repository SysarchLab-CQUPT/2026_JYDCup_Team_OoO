set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
open_checkpoint [file join $project_root reports impl pre_route jyd_soc_top_opt.dcp]
source [file join $script_dir apply_backend_issue_cluster.tcl]

foreach cluster_name {jyd_issue_lane0 jyd_issue_lane1_mem jyd_frontend_redirect} {
  set clustered_cells [get_cells -quiet -hierarchical -filter \
    "USER_CLUSTER == $cluster_name"]
  puts "VALIDATED_CLUSTER_${cluster_name}_COUNT=[llength $clustered_cells]"
  if {[llength $clustered_cells] == 0} {
    error "Cluster $cluster_name did not bind to any cells"
  }
}
close_design
