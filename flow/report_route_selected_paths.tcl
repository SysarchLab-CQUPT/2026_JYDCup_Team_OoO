set root_dir [file normalize [file join [file dirname [info script]] ..]]
set dcp_file [file join $root_dir reports impl jyd_soc_top_route.dcp]
set out_dir [file join $root_dir reports impl selected_paths]
file mkdir $out_dir

open_checkpoint $dcp_file

proc report_one_path {name from_pin to_pin} {
  global out_dir
  set from_obj [get_pins -quiet $from_pin]
  set to_obj [get_pins -quiet $to_pin]
  if {![llength $from_obj] || ![llength $to_obj]} {
    puts "SELECTED_PATH_MISSING_${name}: from=[llength $from_obj] to=[llength $to_obj]"
    return
  }
  report_timing -delay_type max -path_type full_clock_expanded \
    -from $from_obj -to $to_obj -max_paths 1 -nworst 1 \
    -file [file join $out_dir ${name}.rpt]
  puts "SELECTED_PATH_WRITTEN_${name}"
}

report_one_path lq_memdep_to_iq0_ready \
  {u_soc/u_core/u_lq/mem_dep_ready_q_reg[2]/C} \
  {u_soc/u_core/u_iq0/src1_ready_bank0_q_reg[6]/D}
report_one_path lq_memdep_to_iq1_age \
  {u_soc/u_core/u_lq/mem_dep_ready_q_reg[2]/C} \
  {u_soc/u_core/u_iq1/older_mask_q_reg[10][12]/D}
report_one_path lq_memdep_to_ex1 \
  {u_soc/u_core/u_lq/mem_dep_ready_q_reg[2]/C} \
  {u_soc/u_core/ex1_rs2_q_reg[0]/D}
report_one_path fetch_head_to_recovery_mask \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec0_q_reg[illegal]/C} \
  {u_soc/u_core/branch_recovery_kill_mask_q_reg[13]_rep__0/D}
report_one_path fetch_head_to_icache \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec0_q_reg[illegal]/C} \
  {u_soc/u_icache/req_addr_q_reg[12]_rep__3/D}
report_one_path fetch_head_to_checkpoint \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec0_q_reg[illegal]/C} \
  {u_soc/u_core/u_checkpoints/rob_ptr_bank1_q_reg[4][4]/CE}
report_one_path fetch_head_to_predictor \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec0_q_reg[illegal]/C} \
  {u_soc/u_core/u_branch_predictor/snapshot_bank0_pending_addr_q_reg[2]_rep__1/D}
report_one_path fetch_head_to_fetch_queue \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec0_q_reg[illegal]/C} \
  {u_soc/u_core/u_fetch_bundle_queue/dec0_q_reg[3][imm][6]/R}
report_one_path fetch_head_to_iq0 \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec0_q_reg[illegal]/C} \
  {u_soc/u_core/u_iq0/uses_ps2_bank0_q_reg[0]/CE}
report_one_path ex1_to_lq_forward \
  {u_soc/u_core/ex1_q_reg[imm][4]/C} \
  {u_soc/u_core/u_lq/forward_pipe_data_q_reg[14]/D}
report_one_path ex1_to_dcache \
  {u_soc/u_core/ex1_rs1_q_reg[0]/C} \
  {u_soc/u_dcache/u_data_way1/mem_q_reg_0/ENBWREN}
report_one_path ex1_to_store_stage \
  {u_soc/u_core/ex1_rs1_q_reg[0]/C} \
  {u_soc/store_stage_valid_q_reg/D}
report_one_path wb0_to_iq0_ready \
  {u_soc/u_core/wb0_pipe_id_q_reg[0]/C} \
  {u_soc/u_core/u_iq0/src2_ready_bank1_q_reg[4]/D}
report_one_path iq0_ready_to_ex0 \
  {u_soc/u_core/u_iq0/src1_ready_bank1_q_reg[6]/C} \
  {u_soc/u_core/ex0_rs1_q_reg[25]/D}
report_one_path iq0_wakeup_to_ex0 \
  {u_soc/u_core/u_iq0/wakeup_preg_q_reg[4][2]/C} \
  {u_soc/u_core/ex0_rs1_q_reg[10]/D}
report_one_path iq1_wakeup_to_ex1 \
  {u_soc/u_core/u_iq1/wakeup_preg_q_reg[2][0]/C} \
  {u_soc/u_core/ex1_rs2_q_reg[18]/D}
report_one_path fetch_head_to_iq0_ready \
  {u_soc/u_core/u_fetch_bundle_queue/head_dec1_q_reg[op][4]/C} \
  {u_soc/u_core/u_iq0/src1_ready_bank0_q_reg[0]/D}
report_one_path ex0_to_fetch_redirect \
  {u_soc/u_core/ex0_rs2_q_reg[2]/C} \
  {u_soc/u_core/fetch_pc_q_reg[11]_rep/D}
report_one_path dcache_to_rob \
  {u_soc/u_dcache/lookup_store_forward_q_reg/C} \
  {u_soc/u_core/u_rob/complete_source_q_reg[1]/D}
report_one_path rob_to_lq_memdep \
  {u_soc/u_core/u_rob/head_q_reg[2]_rep/C} \
  {u_soc/u_core/u_lq/mem_dep_ready_q_reg[1]/D}
report_one_path store_stage_to_dcache \
  {u_soc/store_stage_addr_q_reg[8]_rep__1/C} \
  {u_soc/u_dcache/dirty_q_reg[1][33]/D}

close_design
