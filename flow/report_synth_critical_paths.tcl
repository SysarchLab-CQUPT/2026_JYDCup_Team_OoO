set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set report_dir [file join $project_root reports synth]
set checkpoint [file join $report_dir jyd_soc_top_synth.dcp]

if {![file exists $checkpoint]} {
  error "Synthesis checkpoint does not exist: $checkpoint"
}

open_checkpoint $checkpoint
report_timing -delay_type max -max_paths 200 -nworst 1 -input_pins \
  -file [file join $report_dir worst_setup_paths_detailed.rpt]
report_timing -delay_type min -max_paths 100 -nworst 1 -input_pins \
  -file [file join $report_dir worst_hold_paths_detailed.rpt]

proc report_family {from_re to_re report_file} {
  set from_cells [get_cells -hierarchical -regexp $from_re]
  set to_cells [get_cells -hierarchical -regexp $to_re]
  puts "REPORT_FAMILY=$report_file FROM_CELLS=[llength $from_cells] TO_CELLS=[llength $to_cells]"
  report_timing -delay_type max -max_paths 20 -nworst 1 -input_pins \
    -from $from_cells -to $to_cells -file $report_file
}

report_family {u_soc/u_core/u_rob/.*} {u_soc/u_dcache/.*} \
  [file join $report_dir family_rob_to_dcache.rpt]
report_family {u_soc/u_core/u_rob/.*} {u_soc/u_core/.*} \
  [file join $report_dir family_rob_to_core.rpt]
report_family {u_soc/u_core/u_iq0/.*} {u_soc/u_core/ex0_.*} \
  [file join $report_dir family_iq0_to_ex0.rpt]
report_family {u_soc/u_core/u_iq1/.*} {u_soc/u_core/ex1_.*} \
  [file join $report_dir family_iq1_to_ex1.rpt]
report_family {u_soc/u_core/u_iq1/.*} {u_soc/u_core/u_iq1/.*} \
  [file join $report_dir family_iq1_internal.rpt]
report_family {u_soc/u_core/u_iq1/.*} {u_soc/u_core/u_iq0/.*} \
  [file join $report_dir family_iq1_to_iq0.rpt]
report_family {u_soc/u_core/ex0_.*} {u_soc/u_dcache/.*} \
  [file join $report_dir family_ex0_to_dcache.rpt]
report_family {u_soc/u_core/ex0_.*} {u_soc/u_core/.*} \
  [file join $report_dir family_ex0_to_core.rpt]
report_family {u_soc/u_core/ex1_.*} {u_soc/u_core/ex1_.*} \
  [file join $report_dir family_ex1_internal.rpt]
report_family {u_soc/u_core/ex1_.*} {u_soc/u_core/ex0_.*} \
  [file join $report_dir family_ex1_to_ex0.rpt]
report_family {u_soc/u_core/ex1_.*} {u_soc/u_core/u_iq0/.*} \
  [file join $report_dir family_ex1_to_iq0.rpt]
report_family {u_soc/u_core/ex1_.*} {u_soc/u_core/u_iq1/.*} \
  [file join $report_dir family_ex1_to_iq1.rpt]
close_design

puts "Detailed synthesis timing paths written to $report_dir"
