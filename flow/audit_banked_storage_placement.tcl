set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set checkpoint [file join $project_root reports impl jyd_soc_top_final_route.dcp]
set stage_tag "final_route"
if {[info exists ::env(JYD_AUDIT_DCP)] && $::env(JYD_AUDIT_DCP) ne ""} {
  set checkpoint [file normalize $::env(JYD_AUDIT_DCP)]
}
if {[info exists ::env(JYD_AUDIT_STAGE)] && $::env(JYD_AUDIT_STAGE) ne ""} {
  set stage_tag $::env(JYD_AUDIT_STAGE)
}
set report_dir [file join $project_root reports audit banked_storage_20260814 $stage_tag]
set report_file [file join $report_dir banked_storage_physical_audit.txt]

if {![file exists $checkpoint]} {
  error "Missing routed checkpoint: $checkpoint"
}
file mkdir $report_dir
open_checkpoint $checkpoint

set out [open $report_file w]
puts $out "CHECKPOINT=$checkpoint"
puts $out "STAGE=$stage_tag"
puts $out "NOTE=Read-only bank-level audit of the selected implementation-stage checkpoint."

set group_patterns [dict create \
  IQ0_BANK0       "u_soc/u_core/u_iq0/*bank0*" \
  IQ0_BANK1       "u_soc/u_core/u_iq0/*bank1*" \
  IQ1_BANK0       "u_soc/u_core/u_iq1/*bank0*" \
  IQ1_BANK1       "u_soc/u_core/u_iq1/*bank1*" \
  CHECKPOINT_BANK0 "u_soc/u_core/u_checkpoints/*bank0*" \
  CHECKPOINT_BANK1 "u_soc/u_core/u_checkpoints/*bank1*" \
  BP_SNAPSHOT_BANK0 "u_soc/u_core/u_branch_predictor/*snapshot_bank0*" \
  BP_SNAPSHOT_BANK1 "u_soc/u_core/u_branch_predictor/*snapshot_bank1*" \
  PRF_BANK0       "u_soc/u_core/u_prf/*bank0*" \
  PRF_BANK1       "u_soc/u_core/u_prf/*bank1*" \
  DCACHE_WAY0     "u_soc/u_dcache/*way0*" \
  DCACHE_WAY1     "u_soc/u_dcache/*way1*" \
  ICACHE_WAY0     "u_soc/u_icache/*way0*" \
  ICACHE_WAY1     "u_soc/u_icache/*way1*" \
]

proc jyd_group_cells {pattern} {
  return [get_cells -quiet -hierarchical -filter \
    "IS_PRIMITIVE == 1 && NAME =~ $pattern"]
}

proc jyd_ref_summary {cells} {
  set refs [dict create]
  foreach cell $cells {
    set ref [get_property REF_NAME $cell]
    dict incr refs $ref
  }
  set items {}
  foreach ref [lsort [dict keys $refs]] {
    lappend items "${ref}=[dict get $refs $ref]"
  }
  if {[llength $items] == 0} { return "NONE" }
  return [join $items ,]
}

proc jyd_site_summary {cells} {
  set by_type [dict create]
  foreach cell $cells {
    set loc [get_property -quiet LOC $cell]
    if {[regexp {^([A-Za-z0-9]+)_X([0-9]+)Y([0-9]+)$} $loc -> type x y]} {
      dict lappend by_type $type [list $x $y $loc]
    }
  }

  set summaries {}
  foreach type [lsort [dict keys $by_type]] {
    set points [dict get $by_type $type]
    set min_x 1000000
    set max_x -1
    set min_y 1000000
    set max_y -1
    set sum_x 0
    set sum_y 0
    set sites [dict create]
    foreach point $points {
      lassign $point x y loc
      if {$x < $min_x} { set min_x $x }
      if {$x > $max_x} { set max_x $x }
      if {$y < $min_y} { set min_y $y }
      if {$y > $max_y} { set max_y $y }
      incr sum_x $x
      incr sum_y $y
      dict set sites $loc 1
    }
    set count [llength $points]
    set cx [format %.1f [expr {double($sum_x) / $count}]]
    set cy [format %.1f [expr {double($sum_y) / $count}]]
    lappend summaries "${type}:COUNT=$count,UNIQUE_SITES=[dict size $sites],BBOX=X${min_x}:X${max_x}/Y${min_y}:Y${max_y},SPAN=[expr {$max_x-$min_x+1}]x[expr {$max_y-$min_y+1}],CENTROID=X${cx}/Y${cy}"
  }
  if {[llength $summaries] == 0} { return "NONE" }
  return [join $summaries " ; "]
}

proc jyd_slice_bbox {cells} {
  set min_x 1000000
  set max_x -1
  set min_y 1000000
  set max_y -1
  set count 0
  foreach cell $cells {
    set loc [get_property -quiet LOC $cell]
    if {[regexp {^SLICE_X([0-9]+)Y([0-9]+)$} $loc -> x y]} {
      if {$x < $min_x} { set min_x $x }
      if {$x > $max_x} { set max_x $x }
      if {$y < $min_y} { set min_y $y }
      if {$y > $max_y} { set max_y $y }
      incr count
    }
  }
  if {$count == 0} { return {} }
  return [list $min_x $max_x $min_y $max_y $count]
}

proc jyd_group_report {channel label pattern} {
  set cells [jyd_group_cells $pattern]
  puts $channel "GROUP=$label PATTERN=$pattern PRIMITIVES=[llength $cells]"
  puts $channel "  REF_TYPES=[jyd_ref_summary $cells]"
  puts $channel "  PLACEMENT=[jyd_site_summary $cells]"
}

proc jyd_pair_report {channel label0 pattern0 label1 pattern1} {
  set cells0 [jyd_group_cells $pattern0]
  set cells1 [jyd_group_cells $pattern1]
  set bbox0 [jyd_slice_bbox $cells0]
  set bbox1 [jyd_slice_bbox $cells1]
  puts $channel "PAIR=$label0/$label1"

  if {[llength $bbox0] == 0 || [llength $bbox1] == 0} {
    puts $channel "  SLICE_RELATION=UNAVAILABLE"
  } else {
    lassign $bbox0 minx0 maxx0 miny0 maxy0 count0
    lassign $bbox1 minx1 maxx1 miny1 maxy1 count1
    set overlap_x [expr {max(0, min($maxx0,$maxx1)-max($minx0,$minx1)+1)}]
    set overlap_y [expr {max(0, min($maxy0,$maxy1)-max($miny0,$miny1)+1)}]
    set gap_x [expr {max(0, max($minx0,$minx1)-min($maxx0,$maxx1)-1)}]
    set gap_y [expr {max(0, max($miny0,$miny1)-min($maxy0,$maxy1)-1)}]
    puts $channel "  SLICE_RELATION=OVERLAP_X=$overlap_x OVERLAP_Y=$overlap_y GAP_X=$gap_x GAP_Y=$gap_y"
  }

  set nets0 [get_nets -quiet -of_objects [get_pins -quiet -leaf -of_objects $cells0]]
  set nets1 [get_nets -quiet -of_objects [get_pins -quiet -leaf -of_objects $cells1]]
  set in0 [dict create]
  foreach net $nets0 { dict set in0 $net 1 }
  set shared {}
  foreach net $nets1 {
    if {[dict exists $in0 $net]} { lappend shared $net }
  }

  set ranked {}
  foreach net $shared {
    set pins [get_pins -quiet -leaf -of_objects $net]
    set pin_count [llength $pins]
    set route_status [get_property -quiet ROUTE_STATUS $net]
    lappend ranked [list $pin_count $net $route_status]
  }
  set ranked [lsort -integer -decreasing -index 0 $ranked]
  puts $channel "  SHARED_LOGICAL_NETS=[llength $shared]"
  set rank 0
  foreach item $ranked {
    if {$rank >= 20} { break }
    lassign $item pin_count net route_status
    puts $channel "  SHARED_NET_RANK=[expr {$rank+1}] PINS=$pin_count ROUTE_STATUS=$route_status NET=$net"
    incr rank
  }
}

puts $out ""
puts $out "BANK_GROUPS"
foreach label [dict keys $group_patterns] {
  jyd_group_report $out $label [dict get $group_patterns $label]
}

puts $out ""
puts $out "BANK_PAIR_RELATION_AND_SHARED_NETS"
foreach pair {
  {IQ0_BANK0 IQ0_BANK1}
  {IQ1_BANK0 IQ1_BANK1}
  {CHECKPOINT_BANK0 CHECKPOINT_BANK1}
  {BP_SNAPSHOT_BANK0 BP_SNAPSHOT_BANK1}
  {PRF_BANK0 PRF_BANK1}
  {DCACHE_WAY0 DCACHE_WAY1}
  {ICACHE_WAY0 ICACHE_WAY1}
} {
  lassign $pair label0 label1
  jyd_pair_report $out $label0 [dict get $group_patterns $label0] \
    $label1 [dict get $group_patterns $label1]
}

puts $out ""
puts $out "TOP_100_SETUP_ENDPOINT_BANK_CLASSIFICATION"
set skip_timing [expr {[info exists ::env(JYD_AUDIT_SKIP_TIMING)] &&
                       $::env(JYD_AUDIT_SKIP_TIMING) ne "" &&
                       $::env(JYD_AUDIT_SKIP_TIMING) ne "0"}]
if {$skip_timing} {
  puts $out "SKIPPED=1 REASON=Complete setup/hold reports are classified separately."
} else {
  set group_endpoint_counts [dict create]
  set direct_cross_count 0
  set paths [get_timing_paths -quiet -delay_type max -max_paths 100 -nworst 100 \
    -slack_lesser_than 0.0]
  set rank 0
  foreach path $paths {
    incr rank
    set start_pin [get_property STARTPOINT_PIN $path]
    set end_pin [get_property ENDPOINT_PIN $path]
    set start_cell [get_cells -quiet -of_objects [get_pins -quiet $start_pin]]
    set end_cell [get_cells -quiet -of_objects [get_pins -quiet $end_pin]]
    set start_name [get_property -quiet NAME $start_cell]
    set end_name [get_property -quiet NAME $end_cell]
    set start_groups {}
    set end_groups {}
    foreach label [dict keys $group_patterns] {
      set pattern [dict get $group_patterns $label]
      if {[string match $pattern $start_name]} { lappend start_groups $label }
      if {[string match $pattern $end_name]} { lappend end_groups $label }
    }
    if {[llength $start_groups] == 0} { set start_groups NONE }
    if {[llength $end_groups] == 0} { set end_groups NONE }
    foreach group $end_groups { dict incr group_endpoint_counts $group }

    set direct_cross 0
    foreach sg $start_groups {
      foreach eg $end_groups {
        if {([regsub {(BANK|WAY)0$} $sg {}] eq [regsub {(BANK|WAY)1$} $eg {}]) ||
            ([regsub {(BANK|WAY)1$} $sg {}] eq [regsub {(BANK|WAY)0$} $eg {}])} {
          if {$sg ne $eg && $sg ne "NONE" && $eg ne "NONE"} {
            set direct_cross 1
          }
        }
      }
    }
    if {$direct_cross} { incr direct_cross_count }
    puts $out "PATH_RANK=$rank SLACK=[get_property SLACK $path] START_GROUP=[join $start_groups ,] END_GROUP=[join $end_groups ,] DIRECT_CROSS=$direct_cross START=$start_pin END=$end_pin"
  }
  puts $out "TOP100_DIRECT_BANK_TO_SIBLING_BANK_PATHS=$direct_cross_count"
  foreach group [lsort [dict keys $group_endpoint_counts]] {
    puts $out "TOP100_ENDPOINT_GROUP=$group COUNT=[dict get $group_endpoint_counts $group]"
  }
}

close $out
close_design
puts "BANKED_STORAGE_AUDIT=$report_file"
