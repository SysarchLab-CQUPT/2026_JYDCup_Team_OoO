set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set soc_clk_mhz 50
if {[info exists ::env(JYD_SOC_CLK_MHZ)]} {
  set soc_clk_mhz [string trim $::env(JYD_SOC_CLK_MHZ)]
}
if {[lsearch -exact {50 150 200 250 270} $soc_clk_mhz] < 0} {
  error "Unsupported JYD_SOC_CLK_MHZ=$soc_clk_mhz; choose 50, 150, 200, 250, or 270"
}
set bitstream [file join $project_root reports impl \
  jyd_soc_top_rtthread_coremark_${soc_clk_mhz}mhz.bit]

if {![file exists $bitstream]} {
  error "RT-Thread/CoreMark bitstream does not exist: $bitstream"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set candidates [list]
foreach device [get_hw_devices] {
  set part [string tolower [get_property PART $device]]
  puts "HW_DEVICE=$device PART=$part"
  if {[string match "xc7k325t*" $part]} {
    lappend candidates $device
  }
}

if {[llength $candidates] != 1} {
  error "Expected exactly one xc7k325t device, found [llength $candidates]"
}

set device [lindex $candidates 0]
current_hw_device $device
refresh_hw_device -update_hw_probes false $device
set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
refresh_hw_device -update_hw_probes false $device
puts "PROGRAM_BOARD=PASS DEVICE=$device BITSTREAM=$bitstream"

close_hw_target
disconnect_hw_server
close_hw_manager
