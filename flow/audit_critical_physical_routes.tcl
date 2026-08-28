set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set checkpoint [file join $project_root reports impl jyd_soc_top_final_route.dcp]
set report_dir [file join $project_root reports audit physical_routes_20260814]
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} {
  set checkpoint [file normalize [lindex $argv 0]]
}
if {[llength $argv] >= 2 && [lindex $argv 1] ne ""} {
  set report_dir [file normalize [lindex $argv 1]]
}
set slack_limit "0.0"
if {[llength $argv] >= 3 && [lindex $argv 2] ne ""} {
  set slack_limit [lindex $argv 2]
}

if {![file exists $checkpoint]} {
  error "Missing routed checkpoint: $checkpoint"
}
file mkdir $report_dir
open_checkpoint $checkpoint

proc jyd_xy_bbox {names} {
  set min_x 1000000
  set min_y 1000000
  set max_x -1
  set max_y -1
  set matched 0
  foreach name $names {
    if {[regexp {_X([0-9]+)Y([0-9]+)} $name -> x y]} {
      if {$x < $min_x} { set min_x $x }
      if {$x > $max_x} { set max_x $x }
      if {$y < $min_y} { set min_y $y }
      if {$y > $max_y} { set max_y $y }
      incr matched
    }
  }
  if {$matched == 0} {
    return "NONE"
  }
  return "X${min_x}:X${max_x},Y${min_y}:Y${max_y},SPAN_X=[expr {$max_x-$min_x}],SPAN_Y=[expr {$max_y-$min_y}],MATCHED=$matched"
}

proc jyd_cell_loc {pin} {
  set cell [get_cells -quiet -of_objects $pin]
  if {[llength $cell] == 0} { return "NONE" }
  set loc [get_property -quiet LOC [lindex $cell 0]]
  if {$loc eq ""} { set loc "UNPLACED" }
  return $loc
}

if {$slack_limit eq "all"} {
  set paths [get_timing_paths -quiet -delay_type max -max_paths 100 -nworst 1]
} else {
  set paths [get_timing_paths -quiet -delay_type max \
    -slack_lesser_than $slack_limit -max_paths 100 -nworst 1]
}
set summary [open [file join $report_dir critical_path_physical_summary.tsv] w]
puts $summary "rank\tslack_ns\tdatapath_ns\tlogic_ns\troute_ns\tlogic_levels\tstartpoint\tstart_loc\tendpoint\tend_loc\tpath_cell_bbox\tnets\ttotal_pips\tmax_net_pips\tmax_net_fanout"

set rank 0
foreach path $paths {
  incr rank
  set slack [get_property SLACK $path]
  set datapath [get_property DATAPATH_DELAY $path]
  set logic [get_property DATAPATH_LOGIC_DELAY $path]
  set route [get_property DATAPATH_NET_DELAY $path]
  set levels [get_property LOGIC_LEVELS $path]
  set start_pin [get_property STARTPOINT_PIN $path]
  set end_pin [get_property ENDPOINT_PIN $path]
  set start_name [get_property NAME $start_pin]
  set end_name [get_property NAME $end_pin]
  set start_loc [jyd_cell_loc $start_pin]
  set end_loc [jyd_cell_loc $end_pin]

  set pins [get_pins -quiet -of_objects $path]
  set cells [get_cells -quiet -of_objects $pins]
  set cell_locs {}
  foreach cell $cells {
    set loc [get_property -quiet LOC $cell]
    if {$loc ne ""} { lappend cell_locs $loc }
  }
  set cell_bbox [jyd_xy_bbox $cell_locs]

  set nets [get_nets -quiet -of_objects $pins]
  set data_nets {}
  foreach net $nets {
    set is_clock [get_property -quiet IS_CLOCK $net]
    if {$is_clock ne "1"} {
      lappend data_nets $net
    }
  }
  set total_pips 0
  set max_net_pips 0
  set max_net_fanout 0
  foreach net $data_nets {
    set pips [get_pips -quiet -of_objects $net]
    set pip_count [llength $pips]
    incr total_pips $pip_count
    if {$pip_count > $max_net_pips} { set max_net_pips $pip_count }
    set loads [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]
    set fanout [llength $loads]
    if {$fanout > $max_net_fanout} { set max_net_fanout $fanout }
  }

  puts $summary "$rank\t$slack\t$datapath\t$logic\t$route\t$levels\t$start_name\t$start_loc\t$end_name\t$end_loc\t$cell_bbox\t[llength $data_nets]\t$total_pips\t$max_net_pips\t$max_net_fanout"

  if {$rank <= 20} {
    set detail [open [file join $report_dir [format "path_%03d_physical_nets.txt" $rank]] w]
    puts $detail "PATH_RANK=$rank"
    puts $detail "SLACK_NS=$slack DATAPATH_NS=$datapath LOGIC_NS=$logic ROUTE_NS=$route LOGIC_LEVELS=$levels"
    puts $detail "START=$start_name LOC=$start_loc"
    puts $detail "END=$end_name LOC=$end_loc"
    puts $detail "PATH_CELL_BBOX=$cell_bbox"
    foreach net $data_nets {
      set pips [get_pips -quiet -of_objects $net]
      set nodes [get_nodes -quiet -of_objects $net]
      set loads [get_pins -quiet -of_objects $net -filter {DIRECTION == IN}]
      puts $detail "NET=[get_property NAME $net] FANOUT=[llength $loads] PIPS=[llength $pips] NODES=[llength $nodes] PIP_BBOX=[jyd_xy_bbox $pips]"
      puts $detail "  ROUTE=[get_property -quiet ROUTE $net]"
    }
    close $detail
  }
}
close $summary

if {$slack_limit eq "all"} {
  report_timing -delay_type max -max_paths 100 -nworst 1 -input_pins \
    -file [file join $report_dir critical_100_physical_timing.rpt]
} else {
  report_timing -delay_type max -slack_lesser_than $slack_limit \
    -max_paths 100 -nworst 1 -input_pins -file \
    [file join $report_dir critical_100_physical_timing.rpt]
}
report_route_status -file [file join $report_dir route_status.rpt]
report_design_analysis -congestion -file \
  [file join $report_dir congestion.rpt]

close_design
puts "CRITICAL_PHYSICAL_ROUTE_AUDIT=$report_dir"
