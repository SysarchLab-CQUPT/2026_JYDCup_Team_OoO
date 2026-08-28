set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set routed_dcp [file join $project_root reports impl jyd_soc_top_route.dcp]

if {![file exists $routed_dcp]} {
  error "Routed checkpoint does not exist: $routed_dcp"
}

open_checkpoint $routed_dcp
source [file join $script_dir signoff_checks.tcl]
require_routed_signoff [file join $project_root reports impl signoff_check]
