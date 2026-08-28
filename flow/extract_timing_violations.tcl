# Usage:
#   vivado -mode batch -source flow/extract_timing_violations.tcl \
#     -tclargs <checkpoint.dcp> <output.tsv> <stage_name>

proc jyd_safe_property {object property {fallback ""}} {
  if {[catch {set value [get_property $property $object]}]} {
    return $fallback
  }
  if {$value eq ""} {
    return $fallback
  }
  return $value
}

proc jyd_object_name {object} {
  if {$object eq ""} {
    return ""
  }
  if {[catch {set value [get_property NAME $object]}]} {
    return $object
  }
  return $value
}

proc jyd_extract_timing_violations {checkpoint output_tsv stage_name {summary_report ""}} {
  set checkpoint [file normalize $checkpoint]
  set output_tsv [file normalize $output_tsv]
  if {$summary_report ne ""} {
    set summary_report [file normalize $summary_report]
  }

  if {![file exists $checkpoint]} {
    error "checkpoint does not exist: $checkpoint"
  }
  file mkdir [file dirname $output_tsv]
  open_checkpoint $checkpoint

  if {$summary_report ne ""} {
    file mkdir [file dirname $summary_report]
    report_timing_summary -delay_type min_max -report_unconstrained \
      -check_timing_verbose -file $summary_report
  }

  set out [open $output_tsv w]
  puts $out "stage\ttype\tslack_ns\trequirement_ns\tdatapath_ns\tlogic_ns\tnet_ns\tlogic_levels\tmax_fanout\tgroup\tstartpoint\tendpoint"

  foreach {path_type delay_type} {setup max hold min} {
    set paths [get_timing_paths -quiet -delay_type $delay_type \
      -slack_lesser_than 0.0 -nworst 1 -max_paths 200000]
    puts "TIMING_PATH_COUNT_${stage_name}_${path_type}=[llength $paths]"
    # Preserve the full cell/net sequence for every failing endpoint at every
    # stage.  The TSV remains the machine-readable population; this report is
    # the corresponding path-by-path structural evidence.
    report_timing -delay_type $delay_type -slack_lesser_than 0.0 \
      -nworst 1 -max_paths 200000 -input_pins \
      -file [file join [file dirname $output_tsv] \
        ${stage_name}_all_${path_type}_violations.rpt]
    foreach path $paths {
      set startpoint [jyd_object_name [jyd_safe_property $path STARTPOINT_PIN]]
      set endpoint [jyd_object_name [jyd_safe_property $path ENDPOINT_PIN]]
      set group [jyd_object_name [jyd_safe_property $path PATH_GROUP]]
      puts $out [join [list \
        $stage_name \
        $path_type \
        [jyd_safe_property $path SLACK] \
        [jyd_safe_property $path REQUIREMENT] \
        [jyd_safe_property $path DATAPATH_DELAY] \
        [jyd_safe_property $path LOGIC_DELAY] \
        [jyd_safe_property $path ROUTE_DELAY] \
        [jyd_safe_property $path LOGIC_LEVELS] \
        "" \
        $group \
        $startpoint \
        $endpoint] "\t"]
    }
  }

  close $out
  puts "TIMING_VIOLATIONS_TSV=$output_tsv"
  close_design
}

if {![info exists ::JYD_TIMING_VIOLATION_LIBRARY_ONLY]} {
  if {$argc != 3 && $argc != 4} {
    error "expected <checkpoint.dcp> <output.tsv> <stage_name> ?summary_report?"
  }
  set summary_report ""
  if {$argc == 4} {
    set summary_report [lindex $argv 3]
  }
  jyd_extract_timing_violations \
    [lindex $argv 0] [lindex $argv 1] [lindex $argv 2] $summary_report
}
