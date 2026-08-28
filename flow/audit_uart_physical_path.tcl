set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]

if {![info exists ::env(JYD_UART_AUDIT_DCP)]} {
  error "JYD_UART_AUDIT_DCP is required"
}
if {![info exists ::env(JYD_UART_AUDIT_STAGE)]} {
  error "JYD_UART_AUDIT_STAGE is required"
}
if {![info exists ::env(JYD_UART_AUDIT_OUT)]} {
  error "JYD_UART_AUDIT_OUT is required"
}

set dcp [file normalize $::env(JYD_UART_AUDIT_DCP)]
set stage $::env(JYD_UART_AUDIT_STAGE)
set output_file [file normalize $::env(JYD_UART_AUDIT_OUT)]
file mkdir [file dirname $output_file]

open_checkpoint $dcp
set out [open $output_file w]
puts $out "STAGE=$stage"
puts $out "CHECKPOINT=$dcp"

proc emit_property {out object label property} {
  if {[llength $object] == 0} {
    puts $out "$label=NONE"
    return
  }
  if {[catch {set value [get_property $property $object]}]} {
    set value "UNAVAILABLE"
  }
  if {$value eq ""} {
    set value "EMPTY"
  }
  puts $out "$label=$value"
}

foreach port_name {i_uart_rx o_uart_tx} {
  set port [get_ports -quiet $port_name]
  puts $out "PORT=$port_name COUNT=[llength $port]"
  emit_property $out $port "  PACKAGE_PIN" PACKAGE_PIN
  emit_property $out $port "  IOSTANDARD" IOSTANDARD
  emit_property $out $port "  LOC" LOC
  set package_pin_name [get_property -quiet PACKAGE_PIN $port]
  set package_pin [get_package_pins -quiet $package_pin_name]
  emit_property $out $package_pin "  PACKAGE_PIN_BANK" BANK
  emit_property $out $package_pin "  PACKAGE_PIN_IOBANK" IOBANK
  emit_property $out $package_pin "  PACKAGE_PIN_SITE" SITE
}

set sync_cells [lsort [get_cells -quiet -hier -filter \
  {ASYNC_REG == TRUE && NAME =~ *u_uart*rx_sync_q_reg*}]]
puts $out "RX_SYNC_CELL_COUNT=[llength $sync_cells]"
foreach cell $sync_cells {
  puts $out "RX_SYNC_CELL=$cell"
  emit_property $out $cell "  REF_NAME" REF_NAME
  emit_property $out $cell "  ASYNC_REG" ASYNC_REG
  emit_property $out $cell "  LOC" LOC
  emit_property $out $cell "  BEL" BEL
  emit_property $out $cell "  IS_LOC_FIXED" IS_LOC_FIXED
}

set uart_cells [get_cells -quiet -hier -filter {NAME =~ *u_soc/u_peripherals/u_uart/*}]
puts $out "UART_CELL_COUNT=[llength $uart_cells]"

set xs {}
set ys {}
set unique_sites {}
set placed_uart_cell_count 0
foreach cell $uart_cells {
  set cell_sites [get_sites -quiet -of_objects $cell]
  if {[llength $cell_sites] > 0} {
    incr placed_uart_cell_count
  }
  foreach site $cell_sites {
    set site_name [get_property NAME $site]
    lappend unique_sites $site_name
    if {[regexp {X([0-9]+)Y([0-9]+)} $site_name -> x y]} {
      lappend xs $x
      lappend ys $y
    }
  }
}
set unique_sites [lsort -unique $unique_sites]
puts $out "UART_PLACED_CELL_COUNT=$placed_uart_cell_count"
puts $out "UART_UNIQUE_SITE_COUNT=[llength $unique_sites]"
if {[llength $xs] > 0} {
  set xs [lsort -integer $xs]
  set ys [lsort -integer $ys]
  puts $out "UART_SITE_BBOX=X[lindex $xs 0]:X[lindex $xs end]/Y[lindex $ys 0]:Y[lindex $ys end]"
} else {
  puts $out "UART_SITE_BBOX=UNPLACED"
}

set ignored [get_timing_paths -quiet -user_ignored \
  -from [get_ports i_uart_rx] -max_paths 20 -nworst 1]
puts $out "RX_EXTERNAL_IGNORED_PATH_COUNT=[llength $ignored]"
foreach path $ignored {
  puts $out "  RX_EXTERNAL_IGNORED_ENDPOINT=[get_property ENDPOINT_PIN $path]"
}

if {[llength $sync_cells] == 2} {
  set sync0 [lindex $sync_cells 0]
  set sync1 [lindex $sync_cells 1]
  set stage_path [get_timing_paths -quiet -delay_type max \
    -from [get_pins -quiet $sync0/Q] -to [get_pins -quiet $sync1/D] \
    -max_paths 1 -nworst 1]
  puts $out "RX_SYNC_STAGE_PATH_COUNT=[llength $stage_path]"
  if {[llength $stage_path] == 1} {
    emit_property $out $stage_path "  RX_SYNC_STAGE_SLACK" SLACK
    emit_property $out $stage_path "  RX_SYNC_STAGE_DATAPATH_DELAY" DATAPATH_DELAY
  }

  set internal_paths [get_timing_paths -quiet -delay_type max \
    -from [get_pins -quiet $sync1/Q] -max_paths 20 -nworst 1]
  puts $out "RX_INTERNAL_PATH_COUNT=[llength $internal_paths]"
  foreach path $internal_paths {
    puts $out "  RX_INTERNAL_PATH SLACK=[get_property SLACK $path] START=[get_property STARTPOINT_PIN $path] END=[get_property ENDPOINT_PIN $path]"
  }
}

set uart_setup_violations [get_timing_paths -quiet -delay_type max -slack_lesser_than 0 \
  -through $uart_cells -max_paths 100000 -nworst 100000]
set uart_hold_violations [get_timing_paths -quiet -delay_type min -slack_lesser_than 0 \
  -through $uart_cells -max_paths 100000 -nworst 100000]
puts $out "UART_SETUP_VIOLATION_COUNT=[llength $uart_setup_violations]"
puts $out "UART_HOLD_VIOLATION_COUNT=[llength $uart_hold_violations]"
foreach path $uart_setup_violations {
  puts $out "  UART_SETUP SLACK=[get_property SLACK $path] START=[get_property STARTPOINT_PIN $path] END=[get_property ENDPOINT_PIN $path]"
}
foreach path $uart_hold_violations {
  puts $out "  UART_HOLD SLACK=[get_property SLACK $path] START=[get_property STARTPOINT_PIN $path] END=[get_property ENDPOINT_PIN $path]"
}

close $out
close_design
exit
