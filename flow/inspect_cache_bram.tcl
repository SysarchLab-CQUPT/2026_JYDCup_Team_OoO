set root [file normalize [file join [file dirname [info script]] ..]]
open_checkpoint [file join $root reports impl jyd_soc_top_route.dcp]

set cache_rams [get_cells -hier -filter {REF_NAME =~ RAMB* && NAME =~ *u_dcache*}]
puts "DCACHE_BRAM_COUNT [llength $cache_rams]"
foreach cell $cache_rams {
  puts "DCACHE_BRAM [get_property NAME $cell] REF=[get_property REF_NAME $cell]"
  foreach prop {WRITE_MODE_A WRITE_MODE_B READ_WIDTH_A READ_WIDTH_B WRITE_WIDTH_A WRITE_WIDTH_B RAM_MODE} {
    puts "  $prop=[get_property $prop $cell]"
  }
}
close_design
