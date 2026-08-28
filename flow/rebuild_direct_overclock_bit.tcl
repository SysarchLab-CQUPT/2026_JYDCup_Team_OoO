# Reuse the accepted 150 MHz physical route, replace firmware BRAM INIT, and
# change only the PLLE2_ADV divider for a direct board-overclock artifact.

if {$argc != 7} {
  error "expected <root> <accepted.dcp> <firmware.mem> <out-dir> <out.dcp> <out.bit> <200|250>"
}

set root [file normalize [lindex $argv 0]]
set accepted_dcp [file normalize [lindex $argv 1]]
set firmware_mem [file normalize [lindex $argv 2]]
set output_dir [file normalize [lindex $argv 3]]
set output_dcp [file normalize [lindex $argv 4]]
set output_bit [file normalize [lindex $argv 5]]
set freq_mhz [string trim [lindex $argv 6]]

switch -- $freq_mhz {
  200 { set pll_mult 5; set pll_div 1; set peripheral_div 20; set soc_div 5 }
  250 { set pll_mult 5; set pll_div 1; set peripheral_div 20; set soc_div 4 }
  default { error "unsupported direct frequency: $freq_mhz" }
}

file mkdir $output_dir
read_verilog -sv [file join $root rtl soc unified_bram.sv]
synth_design -top unified_bram -part xc7k325tffg900-2 -mode out_of_context \
  -generic "BYTES=65536 INIT_FILE=$firmware_mem"

set init_cells [lsort [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]
if {[llength $init_cells] != 16} {
  error "expected 16 firmware BRAMs, found [llength $init_cells]"
}
set firmware_init [dict create]
foreach cell $init_cells {
  set source_name [get_property NAME $cell]
  foreach property_name [list_property $cell] {
    if {[regexp {^INIT(P)?_[0-9A-F][0-9A-F]$} $property_name]} {
      dict set firmware_init $source_name $property_name \
        [get_property $property_name $cell]
    }
  }
}
close_design

open_checkpoint $accepted_dcp
set changed_init 0
foreach source_name [dict keys $firmware_init] {
  set target [get_cells -quiet [list "u_soc/u_memory/$source_name"]]
  if {[llength $target] != 1} {
    error "missing target BRAM u_soc/u_memory/$source_name"
  }
  foreach property_name [dict keys [dict get $firmware_init $source_name]] {
    set value [dict get $firmware_init $source_name $property_name]
    if {[get_property $property_name $target] ne $value} {
      incr changed_init
    }
    set_property $property_name $value $target
  }
}

set pll [get_cells -quiet -hier -filter {REF_NAME == PLLE2_ADV}]
if {[llength $pll] != 1} { error "expected one PLLE2_ADV" }
set_property CLKFBOUT_MULT $pll_mult $pll
set_property DIVCLK_DIVIDE $pll_div $pll
set_property CLKOUT0_DIVIDE $peripheral_div $pll
set_property CLKOUT1_DIVIDE $soc_div $pll

puts "DIRECT_FREQ_MHZ=$freq_mhz"
puts "CHANGED_INIT_PROPERTIES=$changed_init"
puts "PLL=$pll_mult/$pll_div CLKOUT0_DIVIDE=$peripheral_div CLKOUT1_DIVIDE=$soc_div"
write_checkpoint -force $output_dcp
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force $output_bit
puts "OUTPUT_BIT=$output_bit"
close_design
exit
