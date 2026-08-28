set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set checkpoint [file join $project_root reports impl jyd_soc_top_route.dcp]
set report_dir [file join $project_root reports impl route_current_paths]

if {![file exists $checkpoint]} {
  error "Routed checkpoint does not exist: $checkpoint"
}

file mkdir $report_dir
open_checkpoint $checkpoint

# The TSV contains every negative endpoint path (nworst=1).  These detailed
# reports retain the cell/net sequence needed to distinguish logic depth from
# real routed delay for the complete failing setup population and worst holds.
report_timing -delay_type max -slack_lesser_than 0.0 -max_paths 200000 \
  -nworst 1 -input_pins -file [file join $report_dir all_setup_violations.rpt]
report_timing -delay_type min -max_paths 500 -nworst 1 -input_pins \
  -file [file join $report_dir worst_hold_paths.rpt]

close_design
puts "ROUTE_CURRENT_PATH_REPORT_DIR=$report_dir"
