set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set build_dir [file join $project_root build vivado]

# Close the existing 50 MHz implementation first, then raise the same single
# SoC clock through the 150/200/250/270 MHz profiles.  The selected clock remains
# visible to all clock-derived peripheral logic.
set soc_clk_mhz 50
if {[info exists ::env(JYD_SOC_CLK_MHZ)]} {
  set soc_clk_mhz [string trim $::env(JYD_SOC_CLK_MHZ)]
}
if {[lsearch -exact {50 150 200 250 270} $soc_clk_mhz] < 0} {
  error "Unsupported JYD_SOC_CLK_MHZ=$soc_clk_mhz; choose 50, 150, 200, 250, or 270"
}
set soc_clk_hz [expr {int($soc_clk_mhz) * 1000000}]

create_project -force jyd2025_ooo_soc_v23 $build_dir -part xc7k325tffg900-2
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

set rtl_files [list \
  [file join $project_root rtl pkg soc_cfg_pkg.sv] \
  [file join $project_root rtl pkg core_types_pkg.sv] \
  [file join $project_root rtl pkg rv32_pkg.sv] \
  [file join $project_root rtl pkg backend_types_pkg.sv] \
  [file join $project_root rtl pkg mmio_pkg.sv] \
  [file join $project_root rtl common reset_sync.sv] \
  [file join $project_root rtl core rename free_bitmap.sv] \
  [file join $project_root rtl core rename rename_map.sv] \
  [file join $project_root rtl core rename physical_regfile_lane.sv] \
  [file join $project_root rtl core rename physical_regfile.sv] \
  [file join $project_root rtl core rename branch_checkpoints.sv] \
  [file join $project_root rtl core backend rob.sv] \
  [file join $project_root rtl core backend issue_queue.sv] \
  [file join $project_root rtl core lsu load_queue.sv] \
  [file join $project_root rtl core lsu store_queue.sv] \
  [file join $project_root rtl core frontend rv32_decode.sv] \
  [file join $project_root rtl core frontend branch_predictor.sv] \
  [file join $project_root rtl core frontend fetch_bundle_queue.sv] \
  [file join $project_root rtl core execute rv32_alu.sv] \
  [file join $project_root rtl core execute rv32_agu_add_imm.sv] \
  [file join $project_root rtl core execute crc16_accelerator.sv] \
  [file join $project_root rtl core execute crc32_word_accelerator.sv] \
  [file join $project_root rtl core execute state_transition_accelerator.sv] \
  [file join $project_root rtl core execute rv32_mul_partial_products.sv] \
  [file join $project_root rtl core execute muldiv_unit.sv] \
  [file join $project_root rtl core execute csr_execute.sv] \
  [file join $project_root rtl core commit csr_file.sv] \
  [file join $project_root rtl core ooo_core.sv] \
  [file join $project_root rtl cache cache_data_ram.sv] \
  [file join $project_root rtl cache instruction_cache.sv] \
  [file join $project_root rtl cache data_cache.sv] \
  [file join $project_root rtl soc mmio_decode.sv] \
  [file join $project_root rtl periph uart.sv] \
  [file join $project_root rtl periph tick_timer.sv] \
  [file join $project_root rtl soc irq_debug.sv] \
  [file join $project_root rtl periph ds18b20_master.sv] \
  [file join $project_root rtl periph temperature_seg_display.sv] \
  [file join $project_root rtl periph temperature_display_island.sv] \
  [file join $project_root rtl soc soc_peripherals.sv] \
  [file join $project_root rtl soc unified_bram.sv] \
  [file join $project_root rtl soc dmem_request_fifo.sv] \
  [file join $project_root rtl soc ooo_soc_system.sv] \
  [file join $project_root rtl soc jyd_soc_top.sv] \
]

add_files -norecurse $rtl_files
set firmware_mem [file normalize [file join $project_root software build rtthread_board rtthread_board.mem]]
if {![file exists $firmware_mem]} {
  error "Board firmware image is missing: $firmware_mem; run software/build_firmware.ps1 -Target rtthread_board"
}
add_files -norecurse $firmware_mem
set_property file_type {Memory Initialization Files} [get_files $firmware_mem]
add_files -fileset constrs_1 -norecurse [file join $project_root constraints board.xdc]

# Import the board-proven 2023.2 Clocking Wizard as the electrical/interface
# baseline.  Vivado 2025.2 upgrades its generated project copy, then selects
# the requested SoC clock profile.  clk_out1 remains the board-reference
# 50 MHz output; clk_out2 is the single SoC clock.
set official_pll_xci [file join $project_root ip pll pll.xci]
import_ip -files $official_pll_xci -name pll
set pll_ip [get_ips pll]
if {[get_property IS_LOCKED $pll_ip]} {
  puts "Upgrading imported PLL project copy for Vivado 2025.2"
  upgrade_ip $pll_ip
}
set_property -dict [list \
  CONFIG.CLKOUT1_USED true \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 50.000 \
  CONFIG.CLKOUT2_USED true \
  CONFIG.CLKOUT2_REQUESTED_OUT_FREQ [format "%.3f" $soc_clk_mhz] \
  CONFIG.NUM_OUT_CLKS 2 \
] $pll_ip

set_property top jyd_soc_top [get_filesets sources_1]
set_property generic "MEM_INIT_FILE=$firmware_mem CLK_HZ=$soc_clk_hz" \
  [get_filesets sources_1]
set_property STEPS.POWER_OPT_DESIGN.IS_ENABLED false [get_runs impl_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE RuntimeOptimized [get_runs impl_1]
# Vivado's Default phys_opt directive does not run hold fixing.  Make the
# pre-route hold repair explicit so route_design does not receive thousands of
# known short LUTRAM write paths and silently trade setup margin for hold.
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithHoldFix [get_runs impl_1]
update_compile_order -fileset sources_1

generate_target all $pll_ip
puts "SOC_CLOCK_PROFILE=${soc_clk_mhz}MHz"
puts "SOC_CLOCK_HZ=$soc_clk_hz"
puts "Created Vivado project at $build_dir"
