set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
if {[info exists ::env(JYD_COMPONENT_AUDIT_DCP)]} {
  set checkpoint [file normalize $::env(JYD_COMPONENT_AUDIT_DCP)]
} else {
  set checkpoint [file join $project_root reports impl jyd_soc_top_final_route.dcp]
}
if {[info exists ::env(JYD_COMPONENT_AUDIT_OUT)]} {
  set report_file [file normalize $::env(JYD_COMPONENT_AUDIT_OUT)]
  set report_dir [file dirname $report_file]
} else {
  set report_dir [file join $project_root reports audit banked_storage_20260814 component_spread]
  set report_file [file join $report_dir bank_component_spread.txt]
}

if {![file exists $checkpoint]} { error "Missing routed checkpoint: $checkpoint" }
file mkdir $report_dir
open_checkpoint $checkpoint
set out [open $report_file w]
puts $out "CHECKPOINT=$checkpoint"
puts $out "NOTE=Fine-grain read-only audit separating bank payload storage from readiness and age logic."

proc jyd_collect_patterns {patterns} {
  set unique [dict create]
  foreach pattern $patterns {
    foreach cell [get_cells -quiet -hierarchical -filter \
      "IS_PRIMITIVE == 1 && NAME =~ $pattern"] {
      dict set unique $cell 1
    }
  }
  return [dict keys $unique]
}

proc jyd_report_component {channel label patterns} {
  set cells [jyd_collect_patterns $patterns]
  set refs [dict create]
  set sites [dict create]
  set min_x 1000000
  set max_x -1
  set min_y 1000000
  set max_y -1
  set sum_x 0
  set sum_y 0
  set slice_count 0
  foreach cell $cells {
    dict incr refs [get_property REF_NAME $cell]
    set loc [get_property -quiet LOC $cell]
    if {[regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $loc -> x y]} {
      dict set sites $loc 1
      if {$x < $min_x} { set min_x $x }
      if {$x > $max_x} { set max_x $x }
      if {$y < $min_y} { set min_y $y }
      if {$y > $max_y} { set max_y $y }
      incr sum_x $x
      incr sum_y $y
      incr slice_count
    }
  }
  set ref_items {}
  foreach ref [lsort [dict keys $refs]] {
    lappend ref_items "${ref}=[dict get $refs $ref]"
  }
  if {[llength $ref_items] == 0} { set ref_items NONE }
  if {$slice_count == 0} {
    set placement NONE
  } else {
    set cx [format %.1f [expr {double($sum_x)/$slice_count}]]
    set cy [format %.1f [expr {double($sum_y)/$slice_count}]]
    set placement "COUNT=$slice_count UNIQUE_SITES=[dict size $sites] BBOX=X${min_x}:X${max_x}/Y${min_y}:Y${max_y} SPAN=[expr {$max_x-$min_x+1}]x[expr {$max_y-$min_y+1}] CENTROID=X${cx}/Y${cy}"
  }
  puts $channel "COMPONENT=$label PRIMITIVES=[llength $cells]"
  puts $channel "  PATTERNS=[join $patterns ,]"
  puts $channel "  REF_TYPES=[join $ref_items ,]"
  puts $channel "  SLICE_PLACEMENT=$placement"
}

set components [dict create \
  IQ0_PAYLOAD_BANK0 {u_soc/u_core/u_iq0/*payload_bank0*} \
  IQ0_PAYLOAD_BANK1 {u_soc/u_core/u_iq0/*payload_bank1*} \
  IQ1_PAYLOAD_BANK0 {u_soc/u_core/u_iq1/*payload_bank0*} \
  IQ1_PAYLOAD_BANK1 {u_soc/u_core/u_iq1/*payload_bank1*} \
  IQ0_READY_BANK0 {u_soc/u_core/u_iq0/*entry_ready_bank0* u_soc/u_core/u_iq0/*src1_ready_bank0* u_soc/u_core/u_iq0/*src2_ready_bank0* u_soc/u_core/u_iq0/*load_mem_ready_bank0*} \
  IQ0_READY_BANK1 {u_soc/u_core/u_iq0/*entry_ready_bank1* u_soc/u_core/u_iq0/*src1_ready_bank1* u_soc/u_core/u_iq0/*src2_ready_bank1* u_soc/u_core/u_iq0/*load_mem_ready_bank1*} \
  IQ1_READY_BANK0 {u_soc/u_core/u_iq1/*entry_ready_bank0* u_soc/u_core/u_iq1/*src1_ready_bank0* u_soc/u_core/u_iq1/*src2_ready_bank0* u_soc/u_core/u_iq1/*load_mem_ready_bank0*} \
  IQ1_READY_BANK1 {u_soc/u_core/u_iq1/*entry_ready_bank1* u_soc/u_core/u_iq1/*src1_ready_bank1* u_soc/u_core/u_iq1/*src2_ready_bank1* u_soc/u_core/u_iq1/*load_mem_ready_bank1*} \
  IQ0_AGE_MATRIX {u_soc/u_core/u_iq0/*older_mask*} \
  IQ1_AGE_MATRIX {u_soc/u_core/u_iq1/*older_mask*} \
  CHECKPOINT_MAP_BANK0 {u_soc/u_core/u_checkpoints/*map_bank0*} \
  CHECKPOINT_MAP_BANK1 {u_soc/u_core/u_checkpoints/*map_bank1*} \
  PRF_STORAGE_BANK0 {u_soc/u_core/u_prf/*bank0_r*} \
  PRF_STORAGE_BANK1 {u_soc/u_core/u_prf/*bank1_r*} \
  DCACHE_DATA_WAY0 {u_soc/u_dcache/u_data_way0/*} \
  DCACHE_DATA_WAY1 {u_soc/u_dcache/u_data_way1/*} \
  ICACHE_DATA_WAY0 {u_soc/u_icache/u_data_way0/*} \
  ICACHE_DATA_WAY1 {u_soc/u_icache/u_data_way1/*} \
]

foreach label [dict keys $components] {
  jyd_report_component $out $label [dict get $components $label]
}

close $out
close_design
puts "BANK_COMPONENT_SPREAD_AUDIT=$report_file"
