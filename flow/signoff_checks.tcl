# Routed-design sign-off checks shared by the implementation flow and by
# standalone checkpoint audits.  This procedure intentionally rejects a
# routed design before write_bitstream when STA or DRC is not clean.

proc require_routed_signoff {report_dir} {
  file mkdir $report_dir

  set timing_report [file join $report_dir timing_summary.rpt]
  set drc_report [file join $report_dir drc.rpt]
  set methodology_report [file join $report_dir methodology.rpt]

  report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file $timing_report
  report_drc -file $drc_report
  report_methodology -file $methodology_report

  set failures [list]

  set setup_bad [get_timing_paths -quiet -delay_type max \
    -slack_lesser_than 0.0 -max_paths 1 -nworst 1]
  if {[llength $setup_bad] != 0} {
    set path [lindex $setup_bad 0]
    lappend failures [format "setup WNS %.3f ns" [get_property SLACK $path]]
  }

  set hold_bad [get_timing_paths -quiet -delay_type min \
    -slack_lesser_than 0.0 -max_paths 1 -nworst 1]
  if {[llength $hold_bad] != 0} {
    set path [lindex $hold_bad 0]
    lappend failures [format "hold WHS %.3f ns" [get_property SLACK $path]]
  }

  set timing_fd [open $timing_report r]
  set timing_text [read $timing_fd]
  close $timing_fd

  set timing_check_failures [list]
  foreach check_name {
    no_clock constant_clock pulse_width_clock
    unconstrained_internal_endpoints multiple_clock generated_clocks loops
    partial_input_delay partial_output_delay latch_loops
  } {
    if {![regexp "checking ${check_name} \\(([0-9]+)\\)" \
          $timing_text -> count]} {
      lappend timing_check_failures "missing $check_name result"
    } elseif {$count != 0} {
      lappend timing_check_failures "$check_name=$count"
    }
  }
  if {[llength $timing_check_failures] != 0} {
    lappend failures "check_timing: [join $timing_check_failures ,]"
  }

  set pulse_bad 0
  set pulse_matches [regexp -all -inline -line \
    {PW[[:space:]]*:[[:space:]]+([0-9]+)[[:space:]]+Failing Endpoints} \
    $timing_text]
  for {set i 1} {$i < [llength $pulse_matches]} {incr i 2} {
    if {[lindex $pulse_matches $i] != 0} {
      incr pulse_bad
    }
  }
  if {$pulse_bad != 0} {
    lappend failures "$pulse_bad pulse-width summary group(s) failing"
  }

  set drc_errors [list]
  set drc_warnings [list]
  foreach violation [get_drc_violations -quiet] {
    set severity [get_property SEVERITY $violation]
    if {[string equal -nocase $severity "Error"]} {
      lappend drc_errors $violation
    } elseif {[string equal -nocase $severity "Warning"]} {
      lappend drc_warnings $violation
    }
  }
  if {[llength $drc_errors] != 0} {
    lappend failures [format "%d DRC error(s)" [llength $drc_errors]]
  }
  # DRC violations expose the check identifier through NAME/CHECK in 2025.2;
  # RULE_NAME is not a property and silently produces an empty collection.
  set reqp_1839 [get_drc_violations -quiet -filter {NAME =~ "REQP-1839*"}]
  if {[llength $reqp_1839] != 0} {
    lappend failures [format "%d REQP-1839 warning(s)" [llength $reqp_1839]]
  }

  puts "SIGNOFF_SETUP_NEGATIVE_PATHS=[llength $setup_bad]"
  puts "SIGNOFF_HOLD_NEGATIVE_PATHS=[llength $hold_bad]"
  puts "SIGNOFF_CHECK_TIMING_FAILURES=[llength $timing_check_failures]"
  puts "SIGNOFF_PULSE_WIDTH_FAILURE_GROUPS=$pulse_bad"
  puts "SIGNOFF_DRC_ERRORS=[llength $drc_errors]"
  puts "SIGNOFF_DRC_WARNINGS=[llength $drc_warnings]"
  puts "SIGNOFF_REQP_1839=[llength $reqp_1839]"
  if {[llength $drc_warnings] != 0} {
    puts "SIGNOFF_DRC_WARNING_IDS=[join $drc_warnings ,]"
  }

  if {[llength $failures] != 0} {
    error "ROUTED SIGN-OFF FAILED: [join $failures {; }]"
  }

  puts "ROUTED_SIGNOFF=PASS"
}
