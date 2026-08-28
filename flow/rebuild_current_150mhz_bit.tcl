# Rebuild the current 150 MHz bitstream without changing placement or routing.
# Usage:
#   vivado -mode batch -notrace -source flow/rebuild_current_150mhz_bit.tcl \
#     -tclargs <project-root> <accepted-route.dcp> <firmware.mem> \
#              <output-dir> <output.dcp> <output.bit>

if {$argc != 6} {
  error "expected <project-root> <accepted-route.dcp> <firmware.mem> <output-dir> <output.dcp> <output.bit>"
}

set project_root [file normalize [lindex $argv 0]]
set accepted_dcp [file normalize [lindex $argv 1]]
set firmware_mem [file normalize [lindex $argv 2]]
set output_dir [file normalize [lindex $argv 3]]
set output_dcp [file normalize [lindex $argv 4]]
set output_bit [file normalize [lindex $argv 5]]

foreach required [list $accepted_dcp $firmware_mem \
                       [file join $project_root rtl soc unified_bram.sv]] {
  if {![file exists $required]} {
    error "required input is missing: $required"
  }
}
file mkdir $output_dir

read_verilog -sv [file join $project_root rtl soc unified_bram.sv]
synth_design -top unified_bram -part xc7k325tffg900-2 -mode out_of_context \
  -generic "BYTES=65536 INIT_FILE=$firmware_mem"

set init_cells [lsort [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]
if {[llength $init_cells] != 16} {
  error "expected 16 unified-memory RAMB36 cells, found [llength $init_cells]"
}
set firmware_init [dict create]
set init_property_count 0
foreach cell $init_cells {
  set cell_name [get_property NAME $cell]
  dict set firmware_init $cell_name REF_NAME [get_property REF_NAME $cell]
  foreach property_name [list_property $cell] {
    if {[regexp {^INIT(P)?_[0-9A-F][0-9A-F]$} $property_name]} {
      dict set firmware_init $cell_name $property_name \
        [get_property $property_name $cell]
      incr init_property_count
    }
  }
}
close_design

open_checkpoint $accepted_dcp
if {[get_property PART [current_design]] ne "xc7k325tffg900-2"} {
  error "unexpected FPGA part: [get_property PART [current_design]]"
}

set changed_init 0
set applied_init 0
foreach source_name [lsort [dict keys $firmware_init]] {
  set target_name "u_soc/u_memory/$source_name"
  set target_cell [get_cells -quiet [list $target_name]]
  if {[llength $target_cell] != 1} {
    error "missing target BRAM cell: $target_name"
  }
  if {[get_property REF_NAME $target_cell] ne \
      [dict get $firmware_init $source_name REF_NAME]} {
    error "BRAM primitive type mismatch: $target_name"
  }
  foreach property_name [dict keys [dict get $firmware_init $source_name]] {
    if {$property_name eq "REF_NAME"} {
      continue
    }
    set new_value [dict get $firmware_init $source_name $property_name]
    if {[get_property $property_name $target_cell] ne $new_value} {
      incr changed_init
    }
    set_property $property_name $new_value $target_cell
    if {[get_property $property_name $target_cell] ne $new_value} {
      error "INIT verification failed: $target_name/$property_name"
    }
    incr applied_init
  }
}
if {$changed_init == 0} {
  error "firmware did not change any BRAM INIT property"
}

set pll_cells [get_cells -quiet -hier -filter {REF_NAME == PLLE2_ADV}]
if {[llength $pll_cells] != 1} {
  error "expected one PLLE2_ADV, found [llength $pll_cells]"
}
set pll_cell [lindex $pll_cells 0]

set route_errors [get_nets -quiet -hier -filter {ROUTE_STATUS == ROUTING_ERROR}]
if {[llength $route_errors] != 0} {
  error "accepted checkpoint contains routing errors"
}

source [file join $project_root flow signoff_checks.tcl]
require_routed_signoff $output_dir

puts "FIRMWARE_BRAM_CELLS=[llength $init_cells]"
puts "INIT_PROPERTIES_CAPTURED=$init_property_count"
puts "INIT_PROPERTIES_APPLIED=$applied_init"
puts "INIT_PROPERTIES_CHANGED=$changed_init"
puts "PLL_CONFIG=[get_property CLKFBOUT_MULT $pll_cell]/[get_property DIVCLK_DIVIDE $pll_cell] CLKOUT0_DIVIDE=[get_property CLKOUT0_DIVIDE $pll_cell] CLKOUT1_DIVIDE=[get_property CLKOUT1_DIVIDE $pll_cell]"

write_checkpoint -force $output_dcp
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force $output_bit
puts "OUTPUT_DCP=$output_dcp"
puts "OUTPUT_BIT=$output_bit"
close_design
exit
