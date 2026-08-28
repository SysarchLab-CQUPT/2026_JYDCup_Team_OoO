# Explore an alternate routing directive from an immutable routed checkpoint.
# Usage: vivado -mode batch -source flow/explore_routed_checkpoint.tcl \
#   -tclargs <input.dcp> <output_dir> <route_directive>

if {$argc != 3} {
  error "expected <input.dcp> <output_dir> <route_directive>"
}

set input_dcp [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set route_directive [lindex $argv 2]

if {![file exists $input_dcp]} {
  error "checkpoint does not exist: $input_dcp"
}
file mkdir $output_dir

open_checkpoint $input_dcp
report_timing_summary -delay_type min_max -report_unconstrained \
  -check_timing_verbose -file [file join $output_dir input_timing_summary.rpt]

set route_start [clock seconds]
route_design -directive $route_directive
set route_elapsed [expr {[clock seconds] - $route_start}]
puts "ROUTE_DIRECTIVE=$route_directive"
puts "ROUTE_ELAPSED_SECONDS=$route_elapsed"
if {$route_elapsed > 3600} {
  error "route_design exceeded the one-hour experiment limit: $route_elapsed seconds"
}

set output_dcp [file join $output_dir jyd_soc_top_${route_directive}.dcp]
write_checkpoint -force $output_dcp
report_timing_summary -delay_type min_max -report_unconstrained \
  -check_timing_verbose -file [file join $output_dir timing_summary.rpt]
report_timing -delay_type max -slack_lesser_than 0.0 -nworst 1 \
  -max_paths 200000 -input_pins \
  -file [file join $output_dir all_setup_violations.rpt]
report_timing -delay_type min -slack_lesser_than 0.0 -nworst 1 \
  -max_paths 200000 -input_pins \
  -file [file join $output_dir all_hold_violations.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_methodology -file [file join $output_dir methodology.rpt]

set setup_paths [get_timing_paths -quiet -delay_type max \
  -slack_lesser_than 0.0 -nworst 1 -max_paths 200000]
set hold_paths [get_timing_paths -quiet -delay_type min \
  -slack_lesser_than 0.0 -nworst 1 -max_paths 200000]
set setup_wns "POSITIVE"
set hold_whs "POSITIVE"
if {[llength $setup_paths] != 0} {
  set setup_wns [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] != 0} {
  set hold_whs [get_property SLACK [lindex $hold_paths 0]]
}
puts "SETUP_NEGATIVE_PATHS=[llength $setup_paths]"
puts "SETUP_WNS=$setup_wns"
puts "HOLD_NEGATIVE_PATHS=[llength $hold_paths]"
puts "HOLD_WHS=$hold_whs"

if {[llength $setup_paths] == 0 && [llength $hold_paths] == 0} {
  set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
  set bit_file [file join $output_dir \
    jyd_soc_top_rtthread_coremark_150mhz_${route_directive}.bit]
  write_bitstream -force $bit_file
  puts "BITSTREAM=$bit_file"
} else {
  puts "BITSTREAM_SKIPPED=TIMING_NOT_CLOSED"
}

close_design
puts "ROUTE_EXPERIMENT_COMPLETE=1"
