set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set report_dir [file join $project_root reports impl]
set routed_checkpoint [file join $report_dir jyd_soc_top_final_route.dcp]

if {![file exists $routed_checkpoint]} {
  error "Missing routed checkpoint: $routed_checkpoint"
}

set soc_clk_mhz 150
if {[info exists ::env(JYD_SOC_CLK_MHZ)]} {
  set soc_clk_mhz [string trim $::env(JYD_SOC_CLK_MHZ)]
}
if {$soc_clk_mhz ne "150"} {
  error "Diagnostic bitstream override is only authorized for the 150 MHz run"
}

open_checkpoint $routed_checkpoint
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
  error "Unable to evaluate routed setup/hold timing"
}
set wns [get_property SLACK [lindex $setup_path 0]]
set whs [get_property SLACK [lindex $hold_path 0]]
puts "DIAGNOSTIC_BITSTREAM_WNS_NS=$wns"
puts "DIAGNOSTIC_BITSTREAM_WHS_NS=$whs"

# This is a deliberate, explicitly named diagnostic image.  Keep the normal
# release path's positive-timing sign-off gate intact; only allow the user's
# one-off routed WNS threshold and still require closed hold timing.
if {$wns < -2.000} {
  error "Routed WNS $wns ns is outside the authorized -2.000 ns threshold"
}
if {$whs < 0.000} {
  error "Routed hold timing is not closed: WHS $whs ns"
}

set bit_tag ""
if {[info exists ::env(JYD_BITSTREAM_TAG)]} {
  set bit_tag [string trim $::env(JYD_BITSTREAM_TAG)]
  if {![regexp {^[A-Za-z0-9_-]*$} $bit_tag]} {
    error "JYD_BITSTREAM_TAG contains unsupported characters: $bit_tag"
  }
  if {$bit_tag ne ""} {
    set bit_tag _${bit_tag}
  }
}
set bit_path [file join $report_dir \
  jyd_soc_top_rtthread_coremark_${soc_clk_mhz}mhz${bit_tag}_timing_not_closed.bit]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force $bit_path
puts "DIAGNOSTIC_BITSTREAM=$bit_path"
