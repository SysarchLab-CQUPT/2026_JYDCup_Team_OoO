set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set report_dir [file join $project_root reports impl]
set checkpoint [file join $report_dir jyd_soc_top_final_route.dcp]
if {![file exists $checkpoint]} {
  set checkpoint [file join $report_dir jyd_soc_top_route.dcp]
}

open_checkpoint $checkpoint
set out [open [file join $report_dir temperature_island_route_audit.txt] w]

set clk50 [get_clocks clk_out1_pll]
set clk150 [get_clocks clk_out2_pll]
set path_50_to_150 [get_timing_paths -quiet -from $clk50 -to $clk150 -max_paths 1]
set path_150_to_50 [get_timing_paths -quiet -from $clk150 -to $clk50 -max_paths 1]
set setup50 [get_timing_paths -quiet -from $clk50 -to $clk50 \
  -delay_type max -max_paths 1]
set hold50 [get_timing_paths -quiet -from $clk50 -to $clk50 \
  -delay_type min -max_paths 1]
set setup50_bad [get_timing_paths -quiet -from $clk50 -to $clk50 \
  -delay_type max -slack_lesser_than 0.0 -max_paths 200000 -nworst 1]
set hold50_bad [get_timing_paths -quiet -from $clk50 -to $clk50 \
  -delay_type min -slack_lesser_than 0.0 -max_paths 200000 -nworst 1]

set dq_port [get_ports ds18b20_dq_io]
set seg_ports [get_ports {virtual_seg[*]}]
set island_cells [get_cells -hier -quiet -filter \
  {NAME =~ u_temperature_island/*}]
set iobuf_cells [get_cells -hier -quiet -filter \
  {NAME =~ *ds18b20* && (REF_NAME == IOBUF || REF_NAME == IBUF || REF_NAME == OBUFT)}]

puts $out "ROUTED_CHECKPOINT=$checkpoint"
puts $out "DQ_PACKAGE_PIN=[get_property PACKAGE_PIN $dq_port]"
puts $out "DQ_IOSTANDARD=[get_property IOSTANDARD $dq_port]"
puts $out "DQ_DRIVE=[get_property DRIVE $dq_port]"
puts $out "DQ_SLEW=[get_property SLEW $dq_port]"
puts $out "SEG_PORT_COUNT=[llength $seg_ports]"
puts $out "ISLAND_CELL_COUNT=[llength $island_cells]"
puts $out "DQ_IO_BUFFER_CELLS=[join $iobuf_cells ,]"
puts $out "PATH_50_TO_150_COUNT=[llength $path_50_to_150]"
puts $out "PATH_150_TO_50_COUNT=[llength $path_150_to_50]"
puts $out "CLK50_WNS_NS=[get_property SLACK [lindex $setup50 0]]"
puts $out "CLK50_WHS_NS=[get_property SLACK [lindex $hold50 0]]"
puts $out "CLK50_SETUP_NEGATIVE_PATHS=[llength $setup50_bad]"
puts $out "CLK50_HOLD_NEGATIVE_PATHS=[llength $hold50_bad]"
close $out

report_io -file [file join $report_dir temperature_island_io.rpt]
report_clock_interaction -delay_type min_max -file \
  [file join $report_dir clock_interaction.rpt]
puts "TEMPERATURE_ISLAND_ROUTE_AUDIT=[file join $report_dir temperature_island_route_audit.txt]"
