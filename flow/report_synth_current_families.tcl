set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set report_dir [file join $project_root reports synth current_families]
set checkpoint [file join $project_root reports synth jyd_soc_top_synth.dcp]

if {![file exists $checkpoint]} {
  error "Synthesis checkpoint does not exist: $checkpoint"
}

file mkdir $report_dir
open_checkpoint $checkpoint

proc report_family_both {name from_re to_re report_dir} {
  set from_cells [get_cells -hierarchical -regexp $from_re]
  set to_cells [get_cells -hierarchical -regexp $to_re]
  puts "REPORT_CURRENT_FAMILY=$name FROM_CELLS=[llength $from_cells] TO_CELLS=[llength $to_cells]"
  if {([llength $from_cells] == 0) || ([llength $to_cells] == 0)} {
    puts "REPORT_CURRENT_FAMILY_SKIPPED=$name"
    return
  }
  report_timing -delay_type max -max_paths 20 -nworst 1 -input_pins \
    -from $from_cells -to $to_cells \
    -file [file join $report_dir ${name}_setup.rpt]
  report_timing -delay_type min -max_paths 20 -nworst 1 -input_pins \
    -from $from_cells -to $to_cells \
    -file [file join $report_dir ${name}_hold.rpt]
}

set core_direct {^u_soc/u_core/[^/]+$}
set soc_direct {^u_soc/[^/]+$}
set lq {^u_soc/u_core/u_lq/.*}
set sq {^u_soc/u_core/u_sq/.*}
set iq0 {^u_soc/u_core/u_iq0/.*}
set iq1 {^u_soc/u_core/u_iq1/.*}
set rob {^u_soc/u_core/u_rob/.*}
set free_map {^u_soc/u_core/u_free_bitmap/.*}
set checkpoints {^u_soc/u_core/u_checkpoints/.*}
set csr {^u_soc/u_core/u_csr/.*}
set ex0 {^u_soc/u_core/ex0.*}
set ex1 {^u_soc/u_core/ex1.*}
set icache {^u_soc/u_icache/.*}
set dcache {^u_soc/u_dcache/.*}
set dmem_fifo {^u_soc/u_dmem_request_fifo/.*}
set peripherals {^u_soc/u_peripherals/.*}
set mul_parts {^u_soc/u_core/u_mul_partial_products/.*}

foreach family [list \
  [list dcache_to_iq0 $dcache $iq0] \
  [list dcache_to_iq1 $dcache $iq1] \
  [list lq_to_iq0 $lq $iq0] \
  [list lq_to_iq1 $lq $iq1] \
  [list rob_to_lq $rob $lq] \
  [list ex1_to_dcache $ex1 $dcache] \
  [list lq_to_dcache $lq $dcache] \
  [list free_map_to_iq0 $free_map $iq0] \
  [list icache_to_core_direct $icache $core_direct] \
  [list core_direct_to_ex1 $core_direct $ex1] \
  [list core_direct_to_iq1 $core_direct $iq1] \
  [list ex1_to_sq $ex1 $sq] \
  [list ex1_to_lq $ex1 $lq] \
  [list free_map_to_core_direct $free_map $core_direct] \
  [list core_direct_to_ex0 $core_direct $ex0] \
  [list icache_internal $icache $icache] \
  [list core_direct_to_iq0 $core_direct $iq0] \
  [list lq_to_peripherals $lq $peripherals] \
  [list lq_to_dmem_fifo $lq $dmem_fifo] \
  [list dcache_to_rob $dcache $rob] \
  [list rob_to_csr $rob $csr] \
  [list rob_to_core_direct $rob $core_direct] \
  [list lq_to_soc_direct $lq $soc_direct] \
  [list free_map_to_sq $free_map $sq] \
  [list rob_internal $rob $rob] \
  [list ex1_to_core_direct $ex1 $core_direct] \
  [list free_map_to_checkpoints $free_map $checkpoints] \
  [list rob_to_lq $rob $lq] \
  [list dcache_to_core_direct $dcache $core_direct] \
  [list lq_to_mul_parts $lq $mul_parts] \
  [list iq1_to_mul_parts $iq1 $mul_parts] \
  [list core_direct_to_mul_parts $core_direct $mul_parts] \
] {
  lassign $family name from_re to_re
  report_family_both $name $from_re $to_re $report_dir
}

close_design
puts "Current synthesis family reports written to $report_dir"
