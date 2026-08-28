set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set synth_dcp [file join $project_root reports synth jyd_soc_top_synth.dcp]

if {![file exists $synth_dcp]} {
  error "Synthesis checkpoint does not exist: $synth_dcp"
}

open_checkpoint $synth_dcp
read_xdc [file join $project_root constraints board.xdc]

set uart_sync_cells [get_cells -quiet -hier -filter \
  {ASYNC_REG == TRUE && NAME =~ *u_uart*rx_sync_q_reg*}]
puts "UART_RX_SYNC_CELL_COUNT=[llength $uart_sync_cells]"
puts "UART_RX_SYNC_CELLS=[join $uart_sync_cells ,]"
if {[llength $uart_sync_cells] != 2} {
  error "Expected two UART RX synchronizer cells"
}

set rx_ignored [get_timing_paths -quiet -user_ignored \
  -from [get_ports i_uart_rx] -max_paths 10 -nworst 1]
puts "UART_RX_IGNORED_PATH_COUNT=[llength $rx_ignored]"
foreach path $rx_ignored {
  puts "UART_RX_IGNORED_ENDPOINT=[get_property ENDPOINT_PIN $path]"
}
if {[llength $rx_ignored] != 1} {
  error "UART RX exception must cut exactly one external-to-first-stage path"
}

puts "BOARD_CONSTRAINT_CHECK=PASS"
