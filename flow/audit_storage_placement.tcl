set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set checkpoint [file join $project_root reports impl jyd_soc_top_final_route.dcp]
set report_dir [file join $project_root reports audit]
set report_file [file join $report_dir storage_placement_current_route.txt]

if {![file exists $checkpoint]} {
  error "Missing routed checkpoint: $checkpoint"
}
file mkdir $report_dir
open_checkpoint $checkpoint

set out [open $report_file w]
puts $out "CHECKPOINT=$checkpoint"
puts $out "DESIGN_STATE=[get_property DESIGN_MODE [current_design]]"
puts $out "NOTE=Read-only audit of the current selected final routed checkpoint."

proc jyd_is_lutram_ref {ref_name} {
  return [expr {
    [regexp {^RAM(16|32|64|128|256|512|S|D)} $ref_name] &&
    ![regexp {^RAMB} $ref_name]
  }]
}

proc jyd_report_hierarchy {channel hierarchy} {
  set hier_cell [get_cells -quiet $hierarchy]
  if {[llength $hier_cell] != 1} {
    puts $channel "HIER=$hierarchy STATUS=MISSING"
    return
  }

  set leaves [get_cells -quiet -hierarchical -filter \
    "IS_PRIMITIVE == 1 && NAME =~ ${hierarchy}/*"]
  set lut_count 0
  set ff_count 0
  set lutram_count 0
  set ramb36_count 0
  set ramb18_count 0
  set dsp_count 0
  set slice_sites [dict create]
  set lutram_refs [dict create]

  foreach leaf $leaves {
    set ref_name [get_property REF_NAME $leaf]
    if {[regexp {^LUT[1-6]} $ref_name]} { incr lut_count }
    if {[regexp {^FD} $ref_name]} { incr ff_count }
    if {[jyd_is_lutram_ref $ref_name]} {
      incr lutram_count
      dict incr lutram_refs $ref_name
    }
    if {[string match "RAMB36*" $ref_name]} { incr ramb36_count }
    if {[string match "RAMB18*" $ref_name]} { incr ramb18_count }
    if {[string match "DSP*" $ref_name]} { incr dsp_count }

    set loc [get_property -quiet LOC $leaf]
    if {[regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $loc -> x y]} {
      dict set slice_sites $loc [list $x $y]
    }
  }

  set min_x 1000000
  set max_x -1
  set min_y 1000000
  set max_y -1
  foreach site [dict keys $slice_sites] {
    lassign [dict get $slice_sites $site] x y
    if {$x < $min_x} { set min_x $x }
    if {$x > $max_x} { set max_x $x }
    if {$y < $min_y} { set min_y $y }
    if {$y > $max_y} { set max_y $y }
  }
  if {[dict size $slice_sites] == 0} {
    set bbox "NONE"
  } else {
    set bbox "X${min_x}:X${max_x},Y${min_y}:Y${max_y},SPAN_X=[expr {$max_x-$min_x+1}],SPAN_Y=[expr {$max_y-$min_y+1}],SITES=[dict size $slice_sites]"
  }

  set cluster [get_property -quiet USER_CLUSTER $hier_cell]
  if {$cluster eq ""} { set cluster "NONE" }
  set lutram_summary {}
  foreach ref_name [lsort [dict keys $lutram_refs]] {
    lappend lutram_summary "${ref_name}=[dict get $lutram_refs $ref_name]"
  }
  if {[llength $lutram_summary] == 0} { set lutram_summary NONE }

  puts $channel "HIER=$hierarchy PRIMS=[llength $leaves] LUT=$lut_count FF=$ff_count LUTRAM_PRIMS=$lutram_count RAMB36=$ramb36_count RAMB18=$ramb18_count DSP=$dsp_count USER_CLUSTER=$cluster SLICE_BBOX=$bbox LUTRAM_TYPES=[join $lutram_summary ,]"
}

set hierarchies {
  u_soc/u_core
  u_soc/u_core/u_branch_predictor
  u_soc/u_core/u_fetch_bundle_queue
  u_soc/u_core/u_checkpoints
  u_soc/u_core/u_free_bitmap
  u_soc/u_core/u_iq0
  u_soc/u_core/u_iq1
  u_soc/u_core/u_lq
  u_soc/u_core/u_prf
  u_soc/u_core/u_rename_map
  u_soc/u_core/u_rob
  u_soc/u_core/u_sq
  u_soc/u_dcache
  u_soc/u_dmem_request_fifo
  u_soc/u_icache
  u_soc/u_memory
}

puts $out ""
puts $out "HIERARCHY_RESOURCE_AND_SPAN"
foreach hierarchy $hierarchies {
  jyd_report_hierarchy $out $hierarchy
}

puts $out ""
puts $out "NONEMPTY_USER_CLUSTERS"
set cluster_count 0
foreach cell [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE == 0}] {
  set cluster [get_property -quiet USER_CLUSTER $cell]
  if {$cluster ne ""} {
    puts $out "CELL=$cell USER_CLUSTER=$cluster"
    incr cluster_count
  }
}
puts $out "USER_CLUSTER_CELL_COUNT=$cluster_count"

close $out
close_design
puts "STORAGE_PLACEMENT_AUDIT=$report_file"
