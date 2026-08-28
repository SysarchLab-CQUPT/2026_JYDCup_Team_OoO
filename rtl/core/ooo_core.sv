`timescale 1ns/1ps
module ooo_core (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  output logic                         imem_req_valid_o,
  input  logic                         imem_req_ready_i,
  output logic [31:0]                  imem_req_addr_o,
  output logic [3:0]                   imem_req_epoch_o,
  input  logic                         imem_rsp_valid_i,
  output logic                         imem_rsp_ready_o,
  input  logic [31:0]                  imem_rsp_addr_i,
  input  logic [3:0]                   imem_rsp_epoch_i,
  input  logic [63:0]                  imem_rsp_data_i,
  input  logic                         imem_rsp_error_i,
  output logic                         icache_flush_o,
  input  logic                         dcache_idle_i,
  output logic                         dcache_clean_req_o,
  input  logic                         dcache_clean_done_i,

  output logic                         dmem_req_valid_o,
  input  logic                         dmem_req_ready_i,
  output logic                         dmem_req_write_o,
  output logic [31:0]                  dmem_req_addr_o,
  output logic [31:0]                  dmem_req_wdata_o,
  output logic [3:0]                   dmem_req_wstrb_o,
  output logic [3:0]                   dmem_req_seq_o,
  output core_types_pkg::uop_id_t      dmem_req_uop_id_o,
  output logic                         dmem_load_valid_o,
  output logic [31:0]                  dmem_load_addr_o,
  output logic                         dmem_fast_load_valid_o,
  output logic [31:0]                  dmem_fast_load_addr_o,
  output logic [3:0]                   dmem_fast_load_seq_o,
  output core_types_pkg::uop_id_t      dmem_fast_load_uop_id_o,
  output logic                         dmem_store_valid_o,
  output logic [31:0]                  dmem_store_addr_o,
  input  logic                         dmem_rsp_valid_i,
  input  logic [31:0]                  dmem_rsp_data_i,
  input  logic                         dmem_rsp_error_i,
  input  logic [3:0]                   dmem_rsp_seq_i,
  input  core_types_pkg::uop_id_t      dmem_rsp_uop_id_i,

  input  logic                         timer_irq_i,
  input  logic                         external_irq_i,
  output core_types_pkg::commit_trace_t commit_trace_o [2],
  output logic [31:0]                  debug_pc_o,
  output logic [5:0]                   debug_rob_count_o
);
  import soc_cfg_pkg::*;
  import rv32_pkg::*;
  import core_types_pkg::*;
  import backend_types_pkg::*;

  typedef struct packed {
    logic        valid;
    rob_ptr_t    rob_ptr;
    uop_id_t     uop_id;
    uop_op_e     op;
    logic [31:0] predicted_pc;
    logic [31:0] actual_next_pc;
    preg_t       pdst;
    logic        rd_wen;
    logic [3:0]  recovery_lq_tail;
    logic [3:0]  recovery_sq_tail;
    logic        fetch_fault;
    logic        is_serializing;
    logic        is_branch;
    logic        is_load;
    logic        is_store;
    logic [3:0]  lq_seq;
    logic [3:0]  sq_seq;
    logic [31:0] store_addr;
    logic [31:0] store_data;
    logic [3:0]  store_mask;
    logic        store_cacheable;
    logic        store_mmio;
    logic        csr_write;
    logic [11:0] csr_addr;
    logic [31:0] csr_wdata;
  } rob_meta_t;

  localparam int unsigned META_BANK_ENTRIES = ROB_ENTRIES / 2;
  localparam int unsigned META_BANK_ADDR_W = ROB_INDEX_W - 1;

  typedef struct packed {
    uop_op_e    op;
    logic       is_serializing;
    logic       is_branch;
    logic       is_load;
    logic       is_store;
    logic [3:0] lq_seq;
    logic [3:0] sq_seq;
  } retire_static_meta_t;

  typedef struct packed {
    logic [31:0] store_addr;
    logic [31:0] store_data;
    logic [3:0]  store_mask;
    logic        store_cacheable;
    logic        store_mmio;
    logic        csr_write;
    logic [11:0] csr_addr;
    logic [31:0] csr_wdata;
  } retire_ex1_meta_t;

  localparam int unsigned RETIRE_STATIC_W = $bits(retire_static_meta_t);
  (* ram_style = "distributed" *)
  logic [RETIRE_STATIC_W-1:0] retire_static_even_q [META_BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [RETIRE_STATIC_W-1:0] retire_static_odd_q [META_BANK_ENTRIES];
  // Dynamic retirement data is split by its unique producer.  No field needs
  // an allocation-time clear: commit consults branch data only for control
  // uops and EX1 data only for stores/CSRs.  This converts the former wide
  // resettable register arrays into one-write distributed RAMs.
  (* ram_style = "distributed" *)
  logic [31:0] retire_next_pc_even_q [META_BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [31:0] retire_next_pc_odd_q [META_BANK_ENTRIES];
  (* ram_style = "distributed" *)
  retire_ex1_meta_t retire_ex1_even_q [META_BANK_ENTRIES];
  (* ram_style = "distributed" *)
  retire_ex1_meta_t retire_ex1_odd_q [META_BANK_ENTRIES];
  logic retire_next_pc_we, retire_ex1_we;
  logic [META_BANK_ADDR_W-1:0] retire_next_pc_addr;
  logic [META_BANK_ADDR_W-1:0] retire_ex1_addr;
  logic retire_next_pc_bank, retire_ex1_bank;
  logic [31:0] retire_next_pc_data;
  retire_ex1_meta_t retire_ex1_data;

  logic meta_valid_q [ROB_ENTRIES];
  rob_ptr_t meta_rob_ptr_q [ROB_ENTRIES];
  uop_id_t meta_uop_id_q [ROB_ENTRIES];
  preg_t meta_pdst_q [ROB_ENTRIES];
  logic meta_rd_wen_q [ROB_ENTRIES];
  logic meta_checkpoint_valid_q [ROB_ENTRIES];
  logic [3:0] meta_checkpoint_id_q [ROB_ENTRIES];

  logic [ROB_INDEX_W-1:0] meta_alloc_index [2];
  retire_static_meta_t meta_alloc_static [2];
  logic meta_static_even_we, meta_static_odd_we;
  logic [META_BANK_ADDR_W-1:0] meta_static_even_addr, meta_static_odd_addr;
  retire_static_meta_t meta_static_even_data, meta_static_odd_data;

  // --------------------------------------------------------------------------
  // Fetch frontend: up to eight request/response credits and an eight-entry
  // fetch-packet queue.  I-cache responses carry their own PC and epoch, so a
  // redirect never relies on a mutable global pending-PC register.
  // --------------------------------------------------------------------------
  logic [31:0] fetch_pc_q;
  logic fetch_buffer_valid_q;
  logic [31:0] fetch_buffer_pc_q;
  logic [63:0] fetch_buffer_data_q;
  logic fetch_buffer_error_q;
  logic [3:0] fetch_queue_count;
  logic fetch_queue_enq_valid;
  logic fetch_queue_enq_ready;
  logic fetch_queue_pop;
  logic fetch_queue_advance;
  logic [3:0] fetch_epoch_q;
  logic [3:0] fetch_inflight_count_q;
  logic [2:0] fetch_meta_head_q, fetch_meta_tail_q;
  // The request-time prediction FIFO has one writer and one asynchronous
  // reader.  Keep the two targets in the same packed row: separate unpacked
  // target arrays were decomposed into roughly 512 flops even though the
  // valid/taken fields inferred LUTRAM.
  localparam int unsigned FETCH_PRED_META_W = 1 + 2 + 32 + 32;
  (* ram_style = "distributed" *)
  logic [FETCH_PRED_META_W-1:0] fetch_meta_pred_q [8];
  logic [FETCH_PRED_META_W-1:0] fetch_meta_pred_head;
  logic imem_req_fire, imem_rsp_fire, imem_rsp_stale;
  logic [31:0] fetch_inst [2];
  logic [31:0] response_inst [2];
  decoded_instr_t dec [2];
  decoded_instr_t response_dec [2];
  logic [1:0] fetch_lane_valid;
  logic [1:0] fetch_pred_taken;
  logic [31:0] fetch_pred_target [2];
  logic [1:0] predictor_query_valid;
  logic [31:0] predictor_query_pc [2];
  logic [1:0] predictor_taken;
  logic [31:0] predictor_target [2];
  logic [1:0] frontend_predictor_taken, frontend_predictor_btb_hit;
  logic [31:0] frontend_predictor_target [2];
  logic [10:0] predictor_spec_ghr;
  logic decode_predict_redirect;
  logic [31:0] decode_predict_target;
  logic decode_serializing_redirect;
  logic fetch_response_redirect;
  logic [31:0] fetch_response_redirect_target;
  logic fetch_response_redirect_pending_q;
  logic [31:0] fetch_response_redirect_target_q;
  logic request_predict_redirect;
  logic [31:0] request_predict_target;
  logic branch_redirect_req;
  logic [1:0] response_pred_taken;
  logic [31:0] response_pred_target [2];
  logic [1:0] response_request_pred_taken;
  logic [31:0] response_request_pred_target [2];
  logic redirect_valid;
  logic fetch_queue_flush;
  logic [31:0] redirect_target;

  fetch_bundle_queue #(.DEPTH(8)) u_fetch_bundle_queue (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(fetch_queue_flush),
    .enq_valid_i(fetch_queue_enq_valid),
    .enq_ready_o(fetch_queue_enq_ready),
    .enq_pc_i(imem_rsp_addr_i), .enq_data_i(imem_rsp_data_i),
    .enq_error_i(imem_rsp_error_i),
    .enq_dec_i(response_dec),
    .enq_pred_taken_i(response_pred_taken),
    .enq_pred_target_i(response_pred_target),
    .deq_valid_o(fetch_buffer_valid_q), .deq_pc_o(fetch_buffer_pc_q),
    .deq_data_o(fetch_buffer_data_q), .deq_error_o(fetch_buffer_error_q),
    .deq_dec_o(dec),
    .deq_pred_taken_o(fetch_pred_taken),
    .deq_pred_target_o(fetch_pred_target),
    .deq_pop_i(fetch_queue_pop), .deq_advance_i(fetch_queue_advance),
    .count_o(fetch_queue_count)
  );

  function automatic logic control_is_call(
    input uop_op_e op, input logic [4:0] rd
  );
    return (op inside {UOP_JAL, UOP_JALR}) &&
           ((rd == 5'd1) || (rd == 5'd5));
  endfunction

  function automatic logic control_is_return(
    input uop_op_e op, input logic [4:0] rd,
    input logic [4:0] rs1, input logic [31:0] imm
  );
    return (op == UOP_JALR) && (rd == 0) &&
           ((rs1 == 5'd1) || (rs1 == 5'd5)) && (imm == 0);
  endfunction

  assign fetch_inst[0] = fetch_buffer_pc_q[2]
                       ? fetch_buffer_data_q[63:32]
                       : fetch_buffer_data_q[31:0];
  assign fetch_inst[1] = fetch_buffer_data_q[63:32];
  assign response_inst[0] = imem_rsp_addr_i[2]
                          ? imem_rsp_data_i[63:32]
                          : imem_rsp_data_i[31:0];
  assign response_inst[1] = imem_rsp_data_i[63:32];
  assign predictor_taken = fetch_pred_taken;
  assign predictor_target[0] = fetch_pred_target[0];
  assign predictor_target[1] = fetch_pred_target[1];
  assign fetch_lane_valid[0] = fetch_buffer_valid_q;
  assign fetch_lane_valid[1] = fetch_buffer_valid_q && !fetch_buffer_pc_q[2] &&
                               (dec[0].op != UOP_JAL) &&
                               (dec[0].op != UOP_JALR) &&
                               !(dec[0].is_branch && predictor_taken[0]) &&
                               !dec[0].is_serializing;

  rv32_decode u_response_decode0 (
    .inst_i(response_inst[0]), .dec_o(response_dec[0])
  );
  rv32_decode u_response_decode1 (
    .inst_i(response_inst[1]), .dec_o(response_dec[1])
  );

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      // Normal requests always use fetch_pc_q.  Keep the BTB/PHT read address
      // on that registered source even while a same-cycle EX0 correction
      // overrides the I-cache address; redirect metadata is explicitly
      // marked not-taken at capture and never consumes this prediction.
      predictor_query_pc[lane] = fetch_pc_q + (lane * 4);
      predictor_query_valid[lane] = rst_ni &&
                                    ((lane == 0) || !fetch_pc_q[2]);
    end
  end

  // --------------------------------------------------------------------------
  // Rename state and ROB.
  // --------------------------------------------------------------------------
  logic [1:0] dispatch_take;
  logic [1:0] rename_alloc_req;
  logic [1:0] rename_alloc_gnt;
  preg_t rename_alloc_preg [2];
  logic rename_bank_conflict;
  logic [PHYS_REGS-1:0] free_bits;
  logic [PHYS_REGS-1:0] recovery_free_mask;
  logic [PHYS_REGS-1:0] rebuild_free_mask;
  logic [PHYS_REGS-1:0] rebuild_free_mask_q;
  logic free_rebuild;
  logic free_recovery;
  logic [1:0] commit_free_valid;
  preg_t commit_free_preg [2];
  logic [1:0] commit_free_valid_q;
  preg_t commit_free_preg_q [2];

  logic [4:0] rename_rs1 [2];
  logic [4:0] rename_rs2 [2];
  logic [4:0] rename_rd [2];
  logic [1:0] rename_rd_wen;
  preg_t rename_ps1 [2];
  preg_t rename_ps2 [2];
  preg_t rename_stale [2];
  preg_t speculative_map [32];
  preg_t committed_map [32];
  preg_t restore_map [32];
  logic rename_restore;
  logic rename_rebuild;
  logic [1:0] commit_map_valid;
  logic [4:0] commit_map_rd [2];
  preg_t commit_map_pdst [2];
  logic [1:0] commit_map_valid_q;
  logic [4:0] commit_map_rd_q [2];
  preg_t commit_map_pdst_q [2];

  logic [1:0] rob_alloc_accept;
  rob_ptr_t rob_alloc_ptr [2];
  uop_id_t rob_alloc_uop_id [2];
  logic [1:0] rob_complete_valid;
  uop_id_t rob_complete_uop_id [2];
  logic [31:0] rob_complete_result [2];
  logic [1:0] rob_complete_exception;
  logic [31:0] rob_complete_cause [2];
  logic [31:0] rob_complete_tval [2];
  logic [1:0] retire_count;
  (* dont_touch = "true" *) logic [1:0] csr_retire_count_q;
  logic [1:0] retire_lane_valid;
  logic rob_recovery_valid;
  rob_ptr_t rob_recovery_tail;
  logic branch_mispredict;
  rob_ptr_t branch_recovery_tail;
  logic branch_recovery_valid_q;
  rob_ptr_t branch_recovery_tail_q;
  rob_ptr_t branch_recovery_end_q;
  // Recovery bounds are duplicated at their structural consumers.  These are
  // the same-cycle state, not extra pipeline stages; physical replication
  // prevents one ROB pointer from driving both IQs and all execute kill cones.
  (* keep = "true", max_fanout = 32 *) logic branch_recovery_valid_iq0_q;
  (* keep = "true", max_fanout = 32 *) rob_ptr_t branch_recovery_tail_iq0_q;
  (* keep = "true", max_fanout = 32 *) rob_ptr_t branch_recovery_end_iq0_q;
  (* keep = "true", max_fanout = 32 *) logic branch_recovery_valid_iq1_q;
  (* keep = "true", max_fanout = 32 *) rob_ptr_t branch_recovery_tail_iq1_q;
  (* keep = "true", max_fanout = 32 *) rob_ptr_t branch_recovery_end_iq1_q;
  (* keep = "true", max_fanout = 32 *) logic branch_recovery_valid_exec_q;
  (* keep = "true", max_fanout = 32 *) rob_ptr_t branch_recovery_tail_exec_q;
  (* keep = "true", max_fanout = 32 *) rob_ptr_t branch_recovery_end_exec_q;
  (* max_fanout = 32 *) logic [31:0] branch_recovery_redirect_target_q;
  logic [31:0] branch_recovery_fetch_next_q;
  logic branch_recovery_fetch_valid_q;
  logic [3:0] branch_lq_recovery_tail_q, branch_sq_recovery_tail_q;
  logic branch_recovery_checkpoint_valid_q;
  logic [3:0] branch_recovery_checkpoint_id_q;
  logic commit_flush, commit_flush_request;
  logic commit_fencei_q;
  rob_entry_t rob_head_entry [2];
  rob_ptr_t rob_head;
  rob_ptr_t rob_tail;
  logic [5:0] rob_count;

  assign rename_rs1[0] = dec[0].rs1;
  assign rename_rs1[1] = dec[1].rs1;
  assign rename_rs2[0] = dec[0].rs2;
  assign rename_rs2[1] = dec[1].rs2;
  assign rename_rd[0] = dec[0].rd;
  assign rename_rd[1] = dec[1].rd;
  assign rename_rd_wen[0] = dec[0].rd_wen;
  assign rename_rd_wen[1] = dec[1].rd_wen;
  assign rename_alloc_req[0] = fetch_lane_valid[0] && dec[0].rd_wen;
  assign rename_alloc_req[1] = fetch_lane_valid[1] && dec[1].rd_wen;

  free_bitmap u_free_bitmap (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .alloc_req_i(rename_alloc_req),
    .alloc_take_i({dispatch_take[1] && dec[1].rd_wen,
                   dispatch_take[0] && dec[0].rd_wen}),
    .alloc_gnt_o(rename_alloc_gnt), .alloc_preg_o(rename_alloc_preg),
    .rename_bank_conflict_o(rename_bank_conflict),
    .commit_free_valid_i(commit_free_valid_q),
    .commit_free_preg_i(commit_free_preg_q),
    .recovery_valid_i(free_recovery), .recovery_free_mask_i(recovery_free_mask),
    .rebuild_valid_i(free_rebuild), .rebuild_free_mask_i(rebuild_free_mask_q),
    .free_bits_o(free_bits)
  );

  rename_map u_rename_map (
    .clk_i(clk_i), .rst_ni(rst_ni), .rename_valid_i(dispatch_take),
    .rename_probe_valid_i(fetch_lane_valid),
    .rename_rs1_i(rename_rs1), .rename_rs2_i(rename_rs2), .rename_rd_i(rename_rd),
    .rename_rd_wen_i(rename_rd_wen), .rename_pdst_i(rename_alloc_preg),
    .rename_ps1_o(rename_ps1), .rename_ps2_o(rename_ps2),
    .rename_stale_pdst_o(rename_stale), .commit_valid_i(commit_map_valid_q),
    .commit_rd_i(commit_map_rd_q), .commit_pdst_i(commit_map_pdst_q),
    .restore_valid_i(rename_restore), .restore_map_i(restore_map),
    .rebuild_from_commit_i(rename_rebuild), .speculative_map_o(speculative_map),
    .committed_map_o(committed_map)
  );

  rob u_rob (
    .clk_i(clk_i), .rst_ni(rst_ni), .alloc_valid_i(dispatch_take),
    .alloc_pc_i('{fetch_buffer_pc_q, fetch_buffer_pc_q + 32'd4}),
    .alloc_inst_i(fetch_inst), .alloc_rd_wen_i({dec[1].rd_wen, dec[0].rd_wen}),
    .alloc_rd_addr_i(rename_rd), .alloc_pdst_i(rename_alloc_preg),
    .alloc_stale_pdst_i(rename_stale), .alloc_accept_o(rob_alloc_accept),
    .alloc_rob_ptr_o(rob_alloc_ptr), .alloc_uop_id_o(rob_alloc_uop_id),
    .complete_valid_i(rob_complete_valid), .complete_uop_id_i(rob_complete_uop_id),
    .complete_result_i(rob_complete_result),
    .complete_exception_i(rob_complete_exception),
    .complete_cause_i(rob_complete_cause), .complete_tval_i(rob_complete_tval),
    .retire_count_i(retire_count), .recovery_valid_i(rob_recovery_valid),
    .recovery_tail_i(rob_recovery_tail), .head_entry_o(rob_head_entry),
    .head_ptr_o(rob_head), .tail_ptr_o(rob_tail), .count_o(rob_count)
  );

  // --------------------------------------------------------------------------
  // Branch checkpoints contain the speculative rename map after the branch.
  // Physical registers are recovered from the exact squashed ROB destinations.
  // --------------------------------------------------------------------------
  logic [1:0] checkpoint_alloc_valid;
  logic [1:0] checkpoint_alloc_accept;
  logic [3:0] checkpoint_alloc_id [2];
  preg_t checkpoint_alloc_map [2][32];
  logic checkpoint_alloc_two_ready;
  logic checkpoint_release_valid;
  logic [3:0] checkpoint_release_id;
  logic checkpoint_recovery_valid;
  logic [3:0] checkpoint_recovery_id;
  logic checkpoint_recovery_found;
  preg_t checkpoint_recovery_map [32];
  logic [3:0] checkpoint_count;

  branch_checkpoints u_checkpoints (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(commit_flush), .rob_tail_i(rob_tail),
    .alloc_valid_i(checkpoint_alloc_valid), .alloc_rob_ptr_i(rob_alloc_ptr),
    .alloc_map_i(checkpoint_alloc_map), .alloc_accept_o(checkpoint_alloc_accept),
    .alloc_id_o(checkpoint_alloc_id),
    .alloc_two_ready_o(checkpoint_alloc_two_ready),
    .release_valid_i(checkpoint_release_valid),
    .release_id_i(checkpoint_release_id), .recovery_valid_i(checkpoint_recovery_valid),
    .recovery_id_i(checkpoint_recovery_id), .recovery_found_o(checkpoint_recovery_found),
    .recovery_map_o(checkpoint_recovery_map), .count_o(checkpoint_count)
  );

  // --------------------------------------------------------------------------
  // Physical register file and two 8-entry issue queues.
  // --------------------------------------------------------------------------
  preg_t prf_read_addr [4];
  logic [31:0] prf_read_data [4];
  logic [31:0] issue_read_data [4];
  logic [4:0] issue_forward_hit [4];
  logic [1:0] issue_wb_forward_valid;
  preg_t issue_wb0_forward_pdst [4];
  preg_t issue_wb1_forward_pdst [4];
  logic [1:0] prf_wb_valid;
  preg_t prf_wb_preg [2];
  logic [31:0] prf_wb_data [2];
  logic [PHYS_REGS-1:0] prf_ready;
  logic [PHYS_REGS-1:0] prf_rebuild_ready_mask;
  logic [PHYS_REGS-1:0] prf_rebuild_ready_mask_q;

  physical_regfile u_prf (
    .clk_i(clk_i), .rst_ni(rst_ni), .read_addr_i(prf_read_addr),
    .read_data_o(prf_read_data), .alloc_valid_i({dispatch_take[1] && dec[1].rd_wen,
                                                dispatch_take[0] && dec[0].rd_wen}),
    .alloc_preg_i(rename_alloc_preg), .wb_valid_i(prf_wb_valid),
    .wb_preg_i(prf_wb_preg), .wb_data_i(prf_wb_data),
    .rebuild_ready_valid_i(free_rebuild),
    .rebuild_ready_mask_i(prf_rebuild_ready_mask_q), .ready_bits_o(prf_ready)
  );

  // --------------------------------------------------------------------------
  // Eight-entry load/store queues.  Memory dependence readiness is registered
  // in the LQ and consumed by IQ1 as a one-bit lookup; the issue selector never
  // scans the SQ or folds address comparison into oldest-ready selection.
  // --------------------------------------------------------------------------
  logic [1:0] lq_alloc_valid, lq_alloc_accept;
  logic [3:0] lq_alloc_seq [2];
  logic [3:0] lq_alloc_older_sq_tail [2];
  logic [7:0] lq_alloc_older_pending [2];
  logic [7:0] lq_mem_dep_ready;
  logic [7:0] lq_mem_dep_ready_set;
  logic lq_execute_valid;
  logic [3:0] lq_execute_seq;
  uop_id_t lq_execute_uop_id;
  logic [31:0] lq_execute_addr;
  mem_size_e lq_execute_size;
  logic lq_execute_unsigned;
  logic [3:0] lq_execute_forward_mask;
  logic [31:0] lq_execute_forward_data;
  logic lq_request_valid, lq_request_ready;
  logic [31:0] lq_request_addr;
  logic [3:0] lq_request_seq;
  logic [3:0] lq_request_older_sq_tail;
  uop_id_t lq_request_uop_id;
  logic lq_request_fast;
  logic lq_wb_valid, lq_wb_ready, lq_wb_error;
  uop_id_t lq_wb_uop_id;
  preg_t lq_wb_pdst;
  logic [31:0] lq_wb_data, lq_wb_fault_addr;
  logic [1:0] lq_release_valid;
  logic [3:0] lq_release_seq [2];
  logic [1:0] lq_release_valid_q;
  logic [3:0] lq_release_seq_q [2];
  logic lq_recovery_valid;
  logic [3:0] lq_recovery_tail;
  logic [3:0] lq_head, lq_alloc_tail, lq_count;
  logic lq_empty;

  logic [1:0] sq_alloc_valid, sq_alloc_accept;
  logic [3:0] sq_alloc_seq [2];
  logic sq_execute_valid;
  logic [3:0] sq_execute_seq;
  uop_id_t sq_execute_uop_id;
  logic [31:0] sq_execute_addr, sq_execute_data;
  logic [3:0] sq_execute_mask;
  logic [7:0] sq_addr_done_onehot, sq_addr_not_ready;
  logic sq_commit_valid, sq_commit_remove;
  logic [3:0] sq_commit_seq;
  logic sq_commit_valid_q, sq_commit_remove_q;
  logic [3:0] sq_commit_seq_q;
  logic sq_recovery_valid;
  logic [3:0] sq_recovery_tail;
  logic sq_drain_valid, sq_drain_ready;
  logic [31:0] sq_drain_addr, sq_drain_data;
  logic [3:0] sq_drain_mask, sq_drain_seq;
  logic sq_query_valid, sq_query_ready;
  logic [31:0] sq_query_addr;
  logic [3:0] sq_query_mask, sq_query_older_tail;
  logic [3:0] sq_query_forward_mask;
  logic [31:0] sq_query_forward_data;
  logic [3:0] sq_head, sq_commit_tail, sq_alloc_tail, sq_count;
  logic sq_committed_empty;

  load_queue u_lq (
    .clk_i(clk_i), .rst_ni(rst_ni), .alloc_valid_i(lq_alloc_valid),
    .alloc_uop_id_i(rob_alloc_uop_id),
    .alloc_pdst_i(rename_alloc_preg),
    .alloc_older_sq_tail_i(lq_alloc_older_sq_tail),
    .alloc_older_addr_pending_i(lq_alloc_older_pending),
    .alloc_accept_o(lq_alloc_accept), .alloc_seq_o(lq_alloc_seq),
    .store_addr_done_onehot_i(sq_addr_done_onehot),
    .mem_dep_ready_bitmap_o(lq_mem_dep_ready),
    .mem_dep_ready_set_o(lq_mem_dep_ready_set),
    .execute_valid_i(lq_execute_valid), .execute_seq_i(lq_execute_seq),
    .execute_uop_id_i(lq_execute_uop_id), .execute_addr_i(lq_execute_addr),
    .execute_size_i(lq_execute_size), .execute_unsigned_i(lq_execute_unsigned),
    .execute_older_sq_tail_i(ex1_lsu_q.older_sq_tail),
    .execute_forward_mask_i(lq_execute_forward_mask),
    .execute_forward_data_i(lq_execute_forward_data),
    .request_valid_o(lq_request_valid), .request_ready_i(lq_request_ready),
    .request_addr_o(lq_request_addr), .request_seq_o(lq_request_seq),
    .request_uop_id_o(lq_request_uop_id),
    .request_older_sq_tail_o(lq_request_older_sq_tail),
    .request_fast_o(lq_request_fast),
    .response_valid_i(dmem_rsp_valid_i),
    .response_seq_i(dmem_rsp_seq_i), .response_uop_id_i(dmem_rsp_uop_id_i),
    .response_data_i(dmem_rsp_data_i), .response_error_i(dmem_rsp_error_i),
    .wb_valid_o(lq_wb_valid), .wb_ready_i(lq_wb_ready),
    .wb_uop_id_o(lq_wb_uop_id), .wb_pdst_o(lq_wb_pdst),
    .wb_data_o(lq_wb_data), .wb_error_o(lq_wb_error),
    .wb_fault_addr_o(lq_wb_fault_addr),
    .wakeup_valid_o(), .wakeup_pdst_o(),
    .release_valid_i(lq_release_valid_q),
    .release_seq_i(lq_release_seq_q), .recovery_valid_i(lq_recovery_valid),
    .recovery_alloc_tail_i(lq_recovery_tail), .head_o(lq_head),
    .alloc_tail_o(lq_alloc_tail), .count_o(lq_count), .empty_o(lq_empty)
  );

  store_queue u_sq (
    .clk_i(clk_i), .rst_ni(rst_ni), .alloc_valid_i(sq_alloc_valid),
    .alloc_uop_id_i(rob_alloc_uop_id),
    .alloc_accept_o(sq_alloc_accept), .alloc_seq_o(sq_alloc_seq),
    .execute_valid_i(sq_execute_valid), .execute_seq_i(sq_execute_seq),
    .execute_uop_id_i(sq_execute_uop_id), .execute_addr_i(sq_execute_addr),
    .execute_data_i(sq_execute_data), .execute_mask_i(sq_execute_mask),
    .addr_done_onehot_o(sq_addr_done_onehot), .commit_valid_i(sq_commit_valid_q),
    .commit_seq_i(sq_commit_seq_q), .commit_remove_i(sq_commit_remove_q),
    .recovery_valid_i(sq_recovery_valid),
    .recovery_alloc_tail_i(sq_recovery_tail), .drain_valid_o(sq_drain_valid),
    .drain_ready_i(sq_drain_ready), .drain_addr_o(sq_drain_addr),
    .drain_data_o(sq_drain_data), .drain_mask_o(sq_drain_mask),
    .drain_seq_o(sq_drain_seq), .query_valid_i(sq_query_valid),
    .query_addr_i(sq_query_addr), .query_mask_i(sq_query_mask),
    .query_older_tail_i(sq_query_older_tail),
    .query_forward_mask_o(sq_query_forward_mask),
    .query_forward_data_o(sq_query_forward_data),
    .query_forward_ready_o(sq_query_ready),
    .addr_not_ready_mask_o(sq_addr_not_ready), .head_o(sq_head),
    .commit_tail_o(sq_commit_tail), .alloc_tail_o(sq_alloc_tail),
    .count_o(sq_count), .committed_empty_o(sq_committed_empty)
  );

  issue_entry_t lane_issue_entry [2];
  issue_entry_t iq0_dispatch_entry [2];
  issue_entry_t iq1_dispatch_entry [2];
  logic [1:0] iq0_dispatch_valid, iq1_dispatch_valid;
  logic [1:0] iq0_dispatch_accept, iq1_dispatch_accept;
  logic [1:0] iq0_src1_ready, iq0_src2_ready;
  logic [1:0] iq1_src1_ready, iq1_src2_ready;
  logic [1:0] iq0_mem_ready, iq1_mem_ready;
  logic iq0_issue_valid, iq1_issue_valid;
  logic iq0_issue_ready, iq1_issue_ready;
  logic iq0_issue_recovery_kill, iq1_issue_recovery_kill;
  logic [2:0] iq0_issue_src1_select_hit, iq0_issue_src2_select_hit;
  logic [2:0] iq1_issue_src1_select_hit, iq1_issue_src2_select_hit;
  issue_entry_t iq0_issue_entry, iq1_issue_entry;
  preg_t iq0_issue_ps1, iq0_issue_ps2, iq0_issue_pdst;
  preg_t iq1_issue_ps1, iq1_issue_ps2, iq1_issue_pdst;
  // Four rows per payload bank give each lane the architectural eight-entry
  // window.  The previous 16-entry-per-lane experiment doubled the age matrix
  // and global wakeup fanout without enough CoreMark gain to justify its
  // 150 MHz routing cost.
  localparam int unsigned IQ_BANK_ENTRIES = 4;
  logic [3:0] iq0_count, iq1_count;
  logic [2:0] iq0_bank0_free, iq0_bank1_free;
  logic [2:0] iq1_bank0_free, iq1_bank1_free;
  logic iq0_can_accept_one, iq0_can_accept_two;
  logic iq1_can_accept_one, iq1_can_accept_two;
  logic [4:0] wakeup_valid_iq0, wakeup_valid_iq1;
  preg_t wakeup_preg_iq0 [5];
  preg_t wakeup_preg_iq1 [5];
  // The registered EX boundaries and secondary PRF completion port
  // participate in same-cycle selection.  WB0 remains a persistent wakeup
  // source below; keeping it out of the age cone limits global writeback
  // fanout without delaying the load/multiply completion stream on WB1.
  logic [2:0] select_wakeup_valid_iq0;
  logic [2:0] select_wakeup_valid_iq1;
  preg_t select_wakeup_preg_iq0 [3];
  preg_t select_wakeup_preg_iq1 [3];

  issue_queue #(
    .ENTRIES(IQ_BANK_ENTRIES), .WAKEUP_PORTS(5),
    .SELECT_WAKEUP_PORTS(3)
  ) u_iq0 (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .dispatch_valid_i(iq0_dispatch_valid), .dispatch_entry_i(iq0_dispatch_entry),
    .dispatch_src1_ready_i(iq0_src1_ready), .dispatch_src2_ready_i(iq0_src2_ready),
    .dispatch_mem_ready_i(iq0_mem_ready),
    .dispatch_accept_o(iq0_dispatch_accept), .wakeup_valid_i(wakeup_valid_iq0),
    .wakeup_preg_i(wakeup_preg_iq0),
    .select_wakeup_valid_i(select_wakeup_valid_iq0),
    .select_wakeup_preg_i(select_wakeup_preg_iq0),
    .load_mem_ready_bitmap_i(8'h00),
    .can_accept_one_o(iq0_can_accept_one),
    .can_accept_two_o(iq0_can_accept_two),
    .issue_valid_o(iq0_issue_valid),
    .issue_ready_i(iq0_issue_ready), .issue_entry_o(iq0_issue_entry),
    .issue_ps1_o(iq0_issue_ps1), .issue_ps2_o(iq0_issue_ps2),
    .issue_pdst_o(iq0_issue_pdst), .issue_fast_wakeup_o(),
    .issue_src1_select_hit_o(iq0_issue_src1_select_hit),
    .issue_src2_select_hit_o(iq0_issue_src2_select_hit),
    .flush_i(commit_flush),
    .recovery_valid_i(branch_recovery_valid_iq0_q && !commit_flush),
    .recovery_start_i(branch_recovery_tail_iq0_q),
    .recovery_end_i(branch_recovery_end_iq0_q),
    .count_o(iq0_count),
    .bank0_free_o(iq0_bank0_free), .bank1_free_o(iq0_bank1_free)
  );
  issue_queue #(
    .ENTRIES(IQ_BANK_ENTRIES), .WAKEUP_PORTS(5),
    .SELECT_WAKEUP_PORTS(3)
  ) u_iq1 (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .dispatch_valid_i(iq1_dispatch_valid), .dispatch_entry_i(iq1_dispatch_entry),
    .dispatch_src1_ready_i(iq1_src1_ready), .dispatch_src2_ready_i(iq1_src2_ready),
    .dispatch_mem_ready_i(iq1_mem_ready),
    .dispatch_accept_o(iq1_dispatch_accept), .wakeup_valid_i(wakeup_valid_iq1),
    .wakeup_preg_i(wakeup_preg_iq1),
    .select_wakeup_valid_i(select_wakeup_valid_iq1),
    .select_wakeup_preg_i(select_wakeup_preg_iq1),
    .load_mem_ready_bitmap_i(lq_mem_dep_ready),
    .can_accept_one_o(iq1_can_accept_one),
    .can_accept_two_o(iq1_can_accept_two),
    .issue_valid_o(iq1_issue_valid),
    .issue_ready_i(iq1_issue_ready), .issue_entry_o(iq1_issue_entry),
    .issue_ps1_o(iq1_issue_ps1), .issue_ps2_o(iq1_issue_ps2),
    .issue_pdst_o(iq1_issue_pdst), .issue_fast_wakeup_o(),
    .issue_src1_select_hit_o(iq1_issue_src1_select_hit),
    .issue_src2_select_hit_o(iq1_issue_src2_select_hit),
    .flush_i(commit_flush),
    .recovery_valid_i(branch_recovery_valid_iq1_q && !commit_flush),
    .recovery_start_i(branch_recovery_tail_iq1_q),
    .recovery_end_i(branch_recovery_end_iq1_q),
    .count_o(iq1_count),
    .bank0_free_o(iq1_bank0_free), .bank1_free_o(iq1_bank1_free)
  );

  function automatic logic route_requires_iq1(input decoded_instr_t d);
    if (d.is_load || d.is_store || d.is_muldiv || d.is_csr ||
        d.is_serializing || d.illegal || d.is_accel) return 1'b1;
    return 1'b0;
  endfunction

  function automatic logic route_requires_iq0(input decoded_instr_t d);
    return d.is_branch || d.is_jump;
  endfunction

  function automatic logic route_is_flexible(input decoded_instr_t d);
    return !route_requires_iq1(d) && !route_requires_iq0(d);
  endfunction

  function automatic logic needs_checkpoint(input decoded_instr_t d);
    // Direct JALs are redirected by response-time predecode before dispatch,
    // so only conditional branches and indirect JALR need recovery snapshots.
    return d.is_branch || (d.is_jump && d.uses_rs1);
  endfunction

  logic route_lane [2];
  logic route_balance_q;
  logic [1:0] dispatch_count;
  logic [1:0] source1_ready_lane, source2_ready_lane;
  logic [4:0] lq_free_slots, sq_free_slots;
  logic [5:0] rob_free_slots;
  logic [3:0] checkpoint_free_slots;
  logic first_resources_ok, second_resources_ok;
  logic first_dest_ok, second_dest_ok;
  logic first_cp_ok, second_cp_ok;
  logic [1:0] first_iq0_need, first_iq1_need;
  logic [1:0] second_iq0_need, second_iq1_need;
  logic [1:0] first_lq_need, first_sq_need;
  logic [1:0] second_lq_need, second_sq_need;
  logic serializing_inflight_q;
  logic interrupt_drain_q;

  always_comb begin : build_dispatch
    // Ordinary ALU operations can execute on either pipe.  A registered
    // round-robin preference balances single flexible operations; it avoids
    // feeding either IQ's live occupancy back through top-level routing and
    // into the same IQ write controls.  Flexible pairs still split naturally.
    if (route_requires_iq1(dec[0]))
      route_lane[0] = 1'b1;
    else if (route_requires_iq0(dec[0]))
      route_lane[0] = 1'b0;
    else
      route_lane[0] = route_balance_q;

    if (route_requires_iq1(dec[1]))
      route_lane[1] = 1'b1;
    else if (route_requires_iq0(dec[1]))
      route_lane[1] = 1'b0;
    else if (route_is_flexible(dec[0]))
      route_lane[1] = ~route_lane[0];
    else
      route_lane[1] = ~route_lane[0];
    first_dest_ok = !dec[0].rd_wen || rename_alloc_gnt[0];
    second_dest_ok = !dec[1].rd_wen || rename_alloc_gnt[1];

    lq_free_slots = 5'd8 - lq_count;
    sq_free_slots = 5'd8 - sq_count;
    // Admission is based only on registered occupancy.  Same-cycle retirement
    // and checkpoint release become visible after the clock edge; they are not
    // allowed to create a commit-to-dispatch combinational feedback path.
    rob_free_slots = 6'd32 - rob_count;
    checkpoint_free_slots = 4'd8 - checkpoint_count;

    first_iq0_need = route_lane[0] ? 2'd0 : 2'd1;
    first_iq1_need = route_lane[0] ? 2'd1 : 2'd0;
    second_iq0_need = first_iq0_need + (route_lane[1] ? 2'd0 : 2'd1);
    second_iq1_need = first_iq1_need + (route_lane[1] ? 2'd1 : 2'd0);
    first_lq_need = dec[0].is_load ? 2'd1 : 2'd0;
    first_sq_need = dec[0].is_store ? 2'd1 : 2'd0;
    second_lq_need = first_lq_need + (dec[1].is_load ? 2'd1 : 2'd0);
    second_sq_need = first_sq_need + (dec[1].is_store ? 2'd1 : 2'd0);
    first_cp_ok = !needs_checkpoint(dec[0]) || (checkpoint_free_slots >= 1);
    second_cp_ok = needs_checkpoint(dec[0]) && needs_checkpoint(dec[1])
      ? checkpoint_alloc_two_ready
      : (({3'b0, needs_checkpoint(dec[0])} +
          {3'b0, needs_checkpoint(dec[1])}) <= checkpoint_free_slots);

    // System/CSR/fence operations enter only as lane 0 of an empty ROB.  They
    // are therefore the architectural head by construction and no longer
    // inject the live ROB-head pointer into the general IQ ready selector.
    first_resources_ok = fetch_lane_valid[0] && first_dest_ok && first_cp_ok &&
                         (!dec[0].is_serializing || (rob_count == 0)) &&
                         (rob_free_slots >= 1) &&
                         ((first_iq0_need == 0) || iq0_can_accept_one) &&
                         ((first_iq1_need == 0) || iq1_can_accept_one) &&
                         (lq_free_slots >= {3'b0, first_lq_need}) &&
                         (sq_free_slots >= {3'b0, first_sq_need});
    second_resources_ok = fetch_lane_valid[1] && !dec[1].is_serializing &&
                          second_dest_ok && second_cp_ok &&
                         (rob_free_slots >= 2) &&
                         ((second_iq0_need == 0) ||
                          ((second_iq0_need == 1) && iq0_can_accept_one) ||
                          ((second_iq0_need == 2) && iq0_can_accept_two)) &&
                         ((second_iq1_need == 0) ||
                          ((second_iq1_need == 1) && iq1_can_accept_one) ||
                          ((second_iq1_need == 2) && iq1_can_accept_two)) &&
                         (lq_free_slots >= {3'b0, second_lq_need}) &&
                         (sq_free_slots >= {3'b0, second_sq_need});

    dispatch_take = '0;
    if (!rob_recovery_valid && !serializing_inflight_q &&
        !interrupt_drain_q && first_resources_ok) begin
      dispatch_take[0] = 1'b1;
      if (second_resources_ok) dispatch_take[1] = 1'b1;
    end
    dispatch_count = {1'b0, dispatch_take[0]} +
                     {1'b0, dispatch_take[1]};

    lq_alloc_valid[0] = dispatch_take[0] && dec[0].is_load;
    lq_alloc_valid[1] = dispatch_take[1] && dec[1].is_load;
    sq_alloc_valid[0] = dispatch_take[0] && dec[0].is_store;
    sq_alloc_valid[1] = dispatch_take[1] && dec[1].is_store;
    lq_alloc_older_sq_tail[0] = sq_alloc_tail;
    lq_alloc_older_sq_tail[1] = sq_alloc_tail + {3'b0, sq_alloc_valid[0]};
    lq_alloc_older_pending[0] = sq_addr_not_ready;
    lq_alloc_older_pending[1] = sq_addr_not_ready;
    if (sq_alloc_valid[0])
      lq_alloc_older_pending[1][sq_alloc_tail[2:0]] = 1'b1;

    for (int unsigned lane = 0; lane < 2; lane++) begin
      lane_issue_entry[lane] = '0;
      lane_issue_entry[lane].valid = dispatch_take[lane];
      lane_issue_entry[lane].op = dec[lane].op;
      lane_issue_entry[lane].pc = fetch_buffer_pc_q + (lane * 4);
      lane_issue_entry[lane].inst = fetch_inst[lane];
      lane_issue_entry[lane].imm = dec[lane].imm;
      lane_issue_entry[lane].csr_addr = dec[lane].csr_addr;
      lane_issue_entry[lane].rob_ptr = rob_alloc_ptr[lane];
      lane_issue_entry[lane].uop_id = rob_alloc_uop_id[lane];
      lane_issue_entry[lane].ps1 = rename_ps1[lane];
      lane_issue_entry[lane].ps2 = rename_ps2[lane];
      lane_issue_entry[lane].pdst = rename_alloc_preg[lane];
      lane_issue_entry[lane].uses_ps1 = dec[lane].uses_rs1;
      lane_issue_entry[lane].uses_ps2 = dec[lane].uses_rs2;
      lane_issue_entry[lane].rd_wen = dec[lane].rd_wen;
      lane_issue_entry[lane].is_branch = dec[lane].is_branch;
      lane_issue_entry[lane].is_jump = dec[lane].is_jump;
      lane_issue_entry[lane].is_load = dec[lane].is_load;
      lane_issue_entry[lane].is_store = dec[lane].is_store;
      lane_issue_entry[lane].is_muldiv = dec[lane].is_muldiv;
      lane_issue_entry[lane].is_csr = dec[lane].is_csr;
      lane_issue_entry[lane].mem_size = dec[lane].mem_size;
      lane_issue_entry[lane].mem_unsigned = dec[lane].mem_unsigned;
      lane_issue_entry[lane].lq_seq = lq_alloc_tail +
        {3'b0, (lane == 1) && lq_alloc_valid[0]};
      lane_issue_entry[lane].sq_seq = sq_alloc_tail +
        {3'b0, (lane == 1) && sq_alloc_valid[0]};
      lane_issue_entry[lane].older_sq_tail = lq_alloc_older_sq_tail[lane];
      lane_issue_entry[lane].predicted_pc = predictor_taken[lane]
                                            ? predictor_target[lane]
                                            : (fetch_buffer_pc_q + (lane * 4) + 32'd4);
      lane_issue_entry[lane].recovery_lq_tail =
        lq_alloc_tail + {3'b0, dispatch_take[0] && dec[0].is_load} +
        {3'b0, (lane == 1) && dispatch_take[1] && dec[1].is_load};
      lane_issue_entry[lane].recovery_sq_tail =
        sq_alloc_tail + {3'b0, dispatch_take[0] && dec[0].is_store} +
        {3'b0, (lane == 1) && dispatch_take[1] && dec[1].is_store};
      lane_issue_entry[lane].fetch_fault = fetch_buffer_error_q;
    end

    // Current WB tags are also presented to both IQs on this edge.  Let the IQ
    // fold them into a newly allocated row instead of indexing the PRF's
    // combinational WB-bypassed ready vector here; that vector otherwise
    // rebuilds a wide tag decode on every dispatch-ready D input.
    source1_ready_lane[0] = !dec[0].uses_rs1 ||
                            prf_ready[rename_ps1[0]] ||
                            (issue_wb_forward_valid[0] &&
                             (rename_ps1[0] == prf_wb_preg[0])) ||
                            (issue_wb_forward_valid[1] &&
                             (rename_ps1[0] == prf_wb_preg[1]));
    source2_ready_lane[0] = !dec[0].uses_rs2 ||
                            prf_ready[rename_ps2[0]] ||
                            (issue_wb_forward_valid[0] &&
                             (rename_ps2[0] == prf_wb_preg[0])) ||
                            (issue_wb_forward_valid[1] &&
                             (rename_ps2[0] == prf_wb_preg[1]));
    source1_ready_lane[1] = !dec[1].uses_rs1 ||
                            prf_ready[rename_ps1[1]] ||
                            (issue_wb_forward_valid[0] &&
                             (rename_ps1[1] == prf_wb_preg[0])) ||
                            (issue_wb_forward_valid[1] &&
                             (rename_ps1[1] == prf_wb_preg[1]));
    source2_ready_lane[1] = !dec[1].uses_rs2 ||
                            prf_ready[rename_ps2[1]] ||
                            (issue_wb_forward_valid[0] &&
                             (rename_ps2[1] == prf_wb_preg[0])) ||
                            (issue_wb_forward_valid[1] &&
                             (rename_ps2[1] == prf_wb_preg[1]));
    if (dispatch_take[0] && dec[0].rd_wen) begin
      if (dec[1].uses_rs1 && (rename_ps1[1] == rename_alloc_preg[0]))
        source1_ready_lane[1] = 1'b0;
      if (dec[1].uses_rs2 && (rename_ps2[1] == rename_alloc_preg[0]))
        source2_ready_lane[1] = 1'b0;
    end

    iq0_dispatch_valid = '0;
    iq1_dispatch_valid = '0;
    iq0_dispatch_entry[0] = '0; iq0_dispatch_entry[1] = '0;
    iq1_dispatch_entry[0] = '0; iq1_dispatch_entry[1] = '0;
    iq0_src1_ready = '0; iq0_src2_ready = '0;
    iq1_src1_ready = '0; iq1_src2_ready = '0;
    iq0_mem_ready = '0; iq1_mem_ready = '0;
    if (dispatch_take[0]) begin
      if (route_lane[0]) begin
        iq1_dispatch_valid[0] = 1'b1; iq1_dispatch_entry[0] = lane_issue_entry[0];
        iq1_src1_ready[0] = source1_ready_lane[0]; iq1_src2_ready[0] = source2_ready_lane[0];
        iq1_mem_ready[0] = !dec[0].is_load ||
          !(|(lq_alloc_older_pending[0] & ~sq_addr_done_onehot));
      end else begin
        iq0_dispatch_valid[0] = 1'b1; iq0_dispatch_entry[0] = lane_issue_entry[0];
        iq0_src1_ready[0] = source1_ready_lane[0]; iq0_src2_ready[0] = source2_ready_lane[0];
        iq0_mem_ready[0] = 1'b1;
      end
    end
    if (dispatch_take[1]) begin
      if (route_lane[1]) begin
        if (iq1_dispatch_valid[0]) begin
          iq1_dispatch_valid[1] = 1'b1; iq1_dispatch_entry[1] = lane_issue_entry[1];
          iq1_src1_ready[1] = source1_ready_lane[1]; iq1_src2_ready[1] = source2_ready_lane[1];
          iq1_mem_ready[1] = !dec[1].is_load ||
            !(|(lq_alloc_older_pending[1] & ~sq_addr_done_onehot));
        end else begin
          iq1_dispatch_valid[0] = 1'b1; iq1_dispatch_entry[0] = lane_issue_entry[1];
          iq1_src1_ready[0] = source1_ready_lane[1]; iq1_src2_ready[0] = source2_ready_lane[1];
          iq1_mem_ready[0] = !dec[1].is_load ||
            !(|(lq_alloc_older_pending[1] & ~sq_addr_done_onehot));
        end
      end else begin
        if (iq0_dispatch_valid[0]) begin
          iq0_dispatch_valid[1] = 1'b1; iq0_dispatch_entry[1] = lane_issue_entry[1];
          iq0_src1_ready[1] = source1_ready_lane[1]; iq0_src2_ready[1] = source2_ready_lane[1];
          iq0_mem_ready[1] = 1'b1;
        end else begin
          iq0_dispatch_valid[0] = 1'b1; iq0_dispatch_entry[0] = lane_issue_entry[1];
          iq0_src1_ready[0] = source1_ready_lane[1]; iq0_src2_ready[0] = source2_ready_lane[1];
          iq0_mem_ready[0] = 1'b1;
        end
      end
    end

    for (int unsigned r = 0; r < 32; r++) begin
      checkpoint_alloc_map[0][r] = speculative_map[r];
      checkpoint_alloc_map[1][r] = speculative_map[r];
      if (dispatch_take[0] && dec[0].rd_wen && (dec[0].rd != 0)) begin
        checkpoint_alloc_map[0][r] = (r[4:0] == dec[0].rd) ? rename_alloc_preg[0] : speculative_map[r];
        checkpoint_alloc_map[1][r] = (r[4:0] == dec[0].rd) ? rename_alloc_preg[0] : speculative_map[r];
      end
      if (dispatch_take[1] && dec[1].rd_wen && (dec[1].rd != 0) && (r[4:0] == dec[1].rd))
        checkpoint_alloc_map[1][r] = rename_alloc_preg[1];
    end
    checkpoint_alloc_valid[0] = dispatch_take[0] && needs_checkpoint(dec[0]);
    checkpoint_alloc_valid[1] = dispatch_take[1] && needs_checkpoint(dec[1]);
  end

  // --------------------------------------------------------------------------
  // Two staged execution pipes. IQ0 handles branches and integer operations;
  // IQ1 handles integer, LSU, CSR, and the single iterative M unit.
  // --------------------------------------------------------------------------
  issue_entry_t ex0_q, ex1_q;
  // Integer/M uops terminate at the ordinary EX1 operand registers.  Memory
  // uops instead terminate at one compact LSU payload in the same issue cycle:
  // there is no copied EX operand bank and no extra load-use stage.  The LSU
  // payload owns only base/imm12/raw-store state; AGU, byte formatting,
  // alignment and address-class decoding all start from that registered
  // boundary.
  typedef struct packed {
    rob_ptr_t    rob_ptr;
    uop_id_t     uop_id;
    preg_t       pdst;
    logic        rd_wen;
    logic        is_load;
    mem_size_e   mem_size;
    logic        mem_unsigned;
    logic [3:0]  queue_seq;
    logic [3:0]  older_sq_tail;
    logic [31:0] base;
    logic [11:0] imm12;
    logic [31:0] store_data_raw;
    logic        fetch_fault;
    logic [31:0] pc;
  } ex1_lsu_payload_t;

  ex1_lsu_payload_t ex1_lsu_q;
  logic ex0_valid_q, ex1_valid_q;
  logic ex1_is_lsu_q;
  logic [31:0] ex0_rs1_q, ex0_rs2_q;
  // This is an existing architectural issue/execute boundary.  Preserve it
  // explicitly: otherwise synthesis can retime it into the DSP A/B registers
  // and turn IQ oldest-selection plus PRF bypass into the DSP setup path.
  (* keep = "true" *) logic [31:0] ex1_rs1_q, ex1_rs2_q;
  logic iq1_issue_is_lsu;
  logic [31:0] ex1_lsu_imm;
  // Narrow EX-local tag copies terminate the scheduler boundary.  Keeping
  // forward identity out of the wide execution payload lets synthesis place
  // these high-fanout bits beside the two IQ CAMs instead of stretching the
  // complete ex*_q register banks across the backend.
  (* keep = "true", max_fanout = 16 *) preg_t ex0_forward_pdst_iq0_q;
  (* keep = "true", max_fanout = 16 *) preg_t ex0_forward_pdst_iq1_q;
  (* keep = "true", max_fanout = 16 *) preg_t ex1_forward_pdst_iq0_q;
  (* keep = "true", max_fanout = 16 *) preg_t ex1_forward_pdst_iq1_q;
  // The same registered producer identity feeds persistent and same-cycle
  // readiness.  Duplicating a second full set of tag/valid registers made the
  // placer spread IQ/PRF/EX into a much larger connection region; keep one
  // ownership point and let physical optimization replicate only proven nets.
  (* keep = "true" *) logic ex0_forward_class_q;
  (* keep = "true" *) logic ex1_forward_class_q;
  logic [31:0] ex0_result, ex0_branch_target;
  logic ex0_branch_control, ex0_branch_taken;
  logic [31:0] ex1_result;
  logic [31:0] ex1_forward_result;
  // Alias the registered AGU output for the existing LSQ interfaces.
  logic [31:0] ex1_mem_addr;
  logic ex1_load_misaligned, ex1_store_misaligned;
  logic ex1_store_access_fault;
  logic [3:0] ex1_load_mask;
  logic [31:0] ex1_store_data;
  logic [3:0] ex1_store_mask;
  logic ex0_live, ex1_live, ex1_lsu_live;
  logic ex1_slot_available;

  // Read operands from the selected issue entries and capture them together
  // with ex*_q.  The existing issue/execute register is therefore the PRF
  // read boundary; the 64:1 asynchronous PRF mux no longer sits in front of
  // the ALU/LSQ/global-control cone.
  assign prf_read_addr[0] = iq0_issue_ps1;
  assign prf_read_addr[1] = iq0_issue_ps2;
  assign prf_read_addr[2] = iq1_issue_ps1;
  assign prf_read_addr[3] = iq1_issue_ps2;

  // IQ selection and the asynchronous PRF terminate at the existing EX
  // registers.  ALU/address/branch work starts from those registered operands
  // in the following execute cycle; this is the intended issue/execute
  // boundary, not an added pipeline stage.
  rv32_alu u_ex0_alu (
    .op_i(ex0_q.op), .pc_i(ex0_q.pc),
    .rs1_i(ex0_rs1_q), .rs2_i(ex0_rs2_q),
    .imm_i(ex0_q.imm), .result_o(ex0_result),
    .control_flow_o(ex0_branch_control), .taken_o(ex0_branch_taken),
    .target_o(ex0_branch_target)
  );
  /* verilator lint_off PINCONNECTEMPTY */
  rv32_alu u_ex1_alu (
    .op_i(ex1_q.op), .pc_i(ex1_q.pc),
    .rs1_i(ex1_rs1_q), .rs2_i(ex1_rs2_q),
    .imm_i(ex1_q.imm), .result_o(ex1_result),
    .control_flow_o(), .taken_o(), .target_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // IQ selection and the asynchronous PRF now terminate at the compact LSU
  // request registers.  The immediate-aware AGU starts from those registers
  // and runs in parallel with LSQ/cache control during the ordinary execute
  // cycle, so this structural cut adds no architectural stage or load latency.
  assign iq1_issue_is_lsu = iq1_issue_entry.is_load ||
                             iq1_issue_entry.is_store;
  assign ex1_lsu_imm = {{20{ex1_lsu_q.imm12[11]}}, ex1_lsu_q.imm12};
  rv32_agu_add_imm u_iq1_lsu_agu (
    .base_i(ex1_lsu_q.base),
    .imm_i(ex1_lsu_imm),
    .addr_o(ex1_mem_addr)
  );

  always_comb begin
    // EX registers are explicitly invalidated by commit/branch recovery.
    // Re-reading the 32-entry generation table here only rebuilt a 32:1 mux
    // in front of every completion and issue-ready endpoint.
    ex0_live = ex0_valid_q;
    ex1_live = ex1_valid_q;
    ex1_lsu_live = ex1_valid_q && ex1_is_lsu_q;
  end

  // The issue queues intentionally keep recovery out of their wide selected-
  // payload path.  Qualify only the narrow EX valid bits here.  Operand and
  // metadata registers may capture don't-care data for a killed row, but it
  // can never execute, forward or complete because its EX valid bit is clear.
  assign iq0_issue_recovery_kill = branch_recovery_valid_iq0_q &&
    rob_ptr_in_range(iq0_issue_entry.rob_ptr,
                     branch_recovery_tail_iq0_q,
                     branch_recovery_end_iq0_q);
  assign iq1_issue_recovery_kill = branch_recovery_valid_iq1_q &&
    rob_ptr_in_range(iq1_issue_entry.rob_ptr,
                     branch_recovery_tail_iq1_q,
                     branch_recovery_end_iq1_q);

  // M extension unit.
  logic mul_req_valid, mul_req_ready;
  logic mul_rsp_valid, mul_rsp_ready;
  logic [31:0] mul_rsp_result;
  uop_id_t mul_rsp_uop_id;
  logic div_inflight_q;
  uop_id_t div_inflight_uop_id_q;
  muldiv_unit #(.SUPPORT_MUL(1'b0)) u_muldiv (
    .clk_i(clk_i), .rst_ni(rst_ni), .req_valid_i(mul_req_valid),
    .req_ready_o(mul_req_ready), .req_op_i(ex1_q.op),
    .req_a_i(ex1_rs1_q), .req_b_i(ex1_rs2_q),
    .req_uop_id_i(ex1_q.uop_id), .rsp_valid_o(mul_rsp_valid),
    .rsp_ready_i(mul_rsp_ready), .rsp_result_o(mul_rsp_result),
    .rsp_uop_id_o(mul_rsp_uop_id)
  );
  // Only division/remainder need the iterative unit.  Multiplication already
  // maps to a combinational DSP product, so returning it through the iterative
  // request/response protocol only added bubbles and occupied EX1 needlessly.
  assign mul_req_valid = ex1_live && !ex1_is_lsu_q &&
                         is_div_op(ex1_q.op);

  // Only one iterative divide can be in flight.  Track that ownership locally
  // instead of validating its response through the 32-entry global metadata
  // table in front of issue operand bypass and branch ALU inputs.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      div_inflight_q <= 1'b0;
      div_inflight_uop_id_q <= '0;
    end else begin
      if (mul_rsp_valid && mul_rsp_ready)
        div_inflight_q <= 1'b0;
      if (mul_req_valid && mul_req_ready) begin
        div_inflight_q <= 1'b1;
        div_inflight_uop_id_q <= ex1_q.uop_id;
      end
      if (commit_flush)
        div_inflight_q <= 1'b0;
      else if (branch_recovery_valid_exec_q &&
               rob_ptr_in_range(uop_rob_ptr(div_inflight_uop_id_q),
                 branch_recovery_tail_exec_q, branch_recovery_end_exec_q))
        div_inflight_q <= 1'b0;
    end
  end

  logic ex1_completion_selected;
  logic ex1_recovery_kill;

  always_comb begin
    // Both execution registers are elastic one-entry stages.  EX0 always
    // completes in the cycle in which it is valid, so it can consume the old
    // entry and capture the next issue together at the clock edge.  EX1 may
    // refill only when its current entry is actually handed to the LSU/M unit
    // or wins the completion arbiter.  This removes the former mandatory
    // empty bubble without adding an execution stage or changing latency.
    // Recovery invalidates IQ entries at this clock edge.  Do not let a killed
    // entry cross the IQ/EX boundary in the same edge: if the old elastic EX
    // entry is an older survivor, its valid bit must remain set, and otherwise
    // the newly captured wrong-path payload could execute after its physical
    // destination has already been returned to FreeMap.
    // Global flush is deliberately absent from the wide IQ/PRF/operand data
    // cone.  On a flush edge the queues clear their rows and the narrow EX
    // valid bits below are forced low; captured payload data is therefore a
    // don't-care.  Keeping flush out of ready prevents a global control bit
    // from being absorbed into every EX operand register's D mux.
    iq0_issue_ready = 1'b1;
    // DIV can wait in the existing elastic EX1 slot until the iterative unit
    // accepts it. Serial/CSR uops were admitted only into an empty ROB and
    // block subsequent dispatch, so they are already guaranteed to be head.
    // Keeping ready independent of the selected payload prevents the
    // selector -> payload RAM -> EX control -> IQ removal feedback loop.
    iq1_issue_ready = ex1_slot_available;
  end

  always_comb begin
    // These functions are intentionally downstream of ex1_lsu_q.  Keeping
    // them out of the issue-side payload removes their decode/mux cones from
    // the IQ/PRF -> LSU-register setup path.
    unique case (ex1_lsu_q.mem_size)
      MEM_SIZE_B: begin
        ex1_load_mask = 4'b0001 << ex1_mem_addr[1:0];
        ex1_store_data = {4{ex1_lsu_q.store_data_raw[7:0]}};
        ex1_store_mask = 4'b0001 << ex1_mem_addr[1:0];
      end
      MEM_SIZE_H: begin
        ex1_load_mask = ex1_mem_addr[1] ? 4'b1100 : 4'b0011;
        ex1_store_data = {2{ex1_lsu_q.store_data_raw[15:0]}};
        ex1_store_mask = ex1_mem_addr[1] ? 4'b1100 : 4'b0011;
      end
      default: begin
        ex1_load_mask = 4'b1111;
        ex1_store_data = ex1_lsu_q.store_data_raw;
        ex1_store_mask = 4'b1111;
      end
    endcase
    ex1_load_misaligned = ex1_lsu_live && ex1_lsu_q.is_load &&
      (((ex1_lsu_q.mem_size == MEM_SIZE_H) && ex1_mem_addr[0]) ||
       ((ex1_lsu_q.mem_size == MEM_SIZE_W) && (|ex1_mem_addr[1:0])));
    ex1_store_misaligned = ex1_lsu_live && !ex1_lsu_q.is_load &&
      (((ex1_lsu_q.mem_size == MEM_SIZE_H) && ex1_mem_addr[0]) ||
       ((ex1_lsu_q.mem_size == MEM_SIZE_W) && (|ex1_mem_addr[1:0])));
    ex1_store_access_fault = ex1_lsu_live && !ex1_lsu_q.is_load &&
      !(addr_is_ram(ex1_mem_addr) || addr_is_mmio(ex1_mem_addr));

    sq_query_valid = ex1_lsu_live && ex1_lsu_q.is_load &&
                     !ex1_lsu_q.fetch_fault && !ex1_load_misaligned;
    sq_query_addr = ex1_mem_addr;
    sq_query_mask = ex1_load_mask;
    sq_query_older_tail = ex1_lsu_q.older_sq_tail;

    // The issue queue already holds a load until every older store address
    // recorded by its LQ entry has resolved.  Consequently SQ forwarding is
    // ready whenever that load reaches EX1.  Keep forwarding lookup/data in
    // parallel, but do not put the eight-entry SQ compare/select tree back in
    // the cache-request valid cone.
    lq_execute_valid = ex1_lsu_live && ex1_lsu_q.is_load &&
                       !ex1_lsu_q.fetch_fault &&
                       !ex1_load_misaligned;
    lq_execute_seq = ex1_lsu_q.queue_seq;
    lq_execute_uop_id = ex1_lsu_q.uop_id;
    lq_execute_addr = ex1_mem_addr;
    lq_execute_size = ex1_lsu_q.mem_size;
    lq_execute_unsigned = ex1_lsu_q.mem_unsigned;
    lq_execute_forward_mask = sq_query_forward_mask;
    lq_execute_forward_data = sq_query_forward_data;

    sq_execute_valid = ex1_lsu_live && !ex1_lsu_q.is_load &&
                       !ex1_lsu_q.fetch_fault &&
                       !ex1_store_misaligned &&
                       !ex1_store_access_fault;
    sq_execute_seq = ex1_lsu_q.queue_seq;
    sq_execute_uop_id = ex1_lsu_q.uop_id;
    sq_execute_addr = ex1_mem_addr;
    sq_execute_data = ex1_store_data;
    sq_execute_mask = ex1_store_mask;
  end

  // CSR read/modify value is evaluated only after the serial uop reaches head.
  logic [31:0] csr_read_data;
  logic csr_read_illegal, csr_write_illegal;
  logic csr_commit_write;
  logic [11:0] csr_commit_addr;
  logic [31:0] csr_commit_data;
  logic csr_interrupt_pending;
  logic [31:0] csr_interrupt_cause;
  logic csr_trap_valid, csr_mret;
  logic [31:0] csr_trap_pc, csr_trap_cause, csr_trap_tval;
  (* dont_touch = "true" *) logic csr_commit_write_q;
  (* dont_touch = "true" *) logic [11:0] csr_commit_addr_q;
  (* dont_touch = "true" *) logic [31:0] csr_commit_data_q;
  (* dont_touch = "true" *) logic csr_trap_valid_q, csr_mret_q;
  (* dont_touch = "true" *) logic [31:0] csr_trap_pc_q;
  (* dont_touch = "true" *) logic [31:0] csr_trap_cause_q;
  (* dont_touch = "true" *) logic [31:0] csr_trap_tval_q;
  logic [31:0] csr_trap_vector, csr_mret_pc;
  logic [31:0] csr_source, csr_new_value;
  logic csr_exec_write, csr_exec_illegal;
  logic [15:0] crc16_result;
  logic [15:0] crc32_result;
  logic [31:0] state_step_result;

  assign ex1_forward_result = ex1_q.is_csr ? csr_read_data :
                              (ex1_q.op == UOP_CRC16)
                                ? {16'b0, crc16_result} :
                              (ex1_q.op == UOP_CRC32)
                                ? {16'b0, crc32_result} :
                              (ex1_q.op == UOP_STATE_STEP)
                                ? state_step_result : ex1_result;

  crc16_accelerator u_crc16_accelerator (
    .data_i(ex1_rs1_q[15:0]),
    .crc_i(ex1_rs2_q[15:0]),
    .crc_o(crc16_result)
  );

  crc32_word_accelerator u_crc32_word_accelerator (
    .data_i(ex1_rs1_q),
    .crc_i(ex1_rs2_q[15:0]),
    .crc_o(crc32_result)
  );

  state_transition_accelerator u_state_transition_accelerator (
    .state_i(ex1_rs1_q[2:0]),
    .symbol_i(ex1_rs2_q[7:0]),
    .result_o(state_step_result)
  );

  csr_file u_csr (
    .clk_i(clk_i), .rst_ni(rst_ni), .read_addr_i(ex1_q.csr_addr),
    .read_data_o(csr_read_data), .read_illegal_o(csr_read_illegal),
    .write_valid_i(csr_commit_write_q), .write_addr_i(csr_commit_addr_q),
    .write_data_i(csr_commit_data_q), .write_illegal_o(csr_write_illegal),
    .retire_count_i(csr_retire_count_q), .timer_irq_i(timer_irq_i),
    .external_irq_i(external_irq_i), .software_irq_i(1'b0),
    .interrupt_pending_o(csr_interrupt_pending),
    .interrupt_cause_o(csr_interrupt_cause), .trap_valid_i(csr_trap_valid_q),
    .trap_pc_i(csr_trap_pc_q), .trap_cause_i(csr_trap_cause_q),
    .trap_tval_i(csr_trap_tval_q), .mret_i(csr_mret_q),
    .trap_vector_o(csr_trap_vector), .mret_pc_o(csr_mret_pc)
  );

  always_comb begin
    csr_source = (ex1_q.op inside {UOP_CSRRWI,UOP_CSRRSI,UOP_CSRRCI})
               ? ex1_q.imm : ex1_rs1_q;
  end

  csr_execute u_csr_execute (
    .csr_valid_i(ex1_q.is_csr), .op_i(ex1_q.op),
    .rs1_field_i(ex1_q.inst[19:15]),
    .csr_addr_i(ex1_q.csr_addr), .source_i(csr_source),
    .read_data_i(csr_read_data), .read_illegal_i(csr_read_illegal),
    .write_o(csr_exec_write), .write_data_o(csr_new_value),
    .illegal_o(csr_exec_illegal)
  );

  // --------------------------------------------------------------------------
  // Completion buses, precise branch recovery, and execution state updates.
  // --------------------------------------------------------------------------
  logic wb0_valid, wb1_valid;
  uop_id_t wb0_id, wb1_id;
  preg_t wb0_pdst, wb1_pdst;
  logic wb0_rd_wen, wb1_rd_wen;
  logic [31:0] wb0_result, wb1_result;
  logic wb0_exception, wb1_exception;
  logic [31:0] wb0_cause, wb1_cause, wb0_tval, wb1_tval;
  logic wb0_pipe_valid_q, wb0_pipe_rd_wen_q, wb0_pipe_exception_q;
  logic wb1_pipe_valid_q, wb1_pipe_rd_wen_q, wb1_pipe_exception_q;
  uop_id_t wb0_pipe_id_q;
  uop_id_t wb1_pipe_id_q;
  (* max_fanout = 32 *) preg_t wb0_pipe_pdst_q;
  (* max_fanout = 32 *) preg_t wb1_pipe_pdst_q;
  logic [31:0] wb0_pipe_result_q, wb1_pipe_result_q;
  logic wb0_pipe_live, wb1_pipe_live;
  logic wb0_pipe_recovery_kill, wb1_pipe_recovery_kill;
  logic wb0_iq_wakeup_capture, wb1_iq_wakeup_capture;
  // Late completion tags are repeated at the same WB boundary once per IQ.
  // These are not extra pipeline stages: they capture beside wb*_pipe_q and
  // replace the former DCache/WB fanout crossing both scheduler regions.
  (* keep = "true", max_fanout = 16 *) logic [1:0] iq0_late_wakeup_valid_q;
  (* keep = "true", max_fanout = 16 *) logic [1:0] iq1_late_wakeup_valid_q;
  (* keep = "true", max_fanout = 16 *) preg_t iq0_late_wakeup_preg_q [2];
  (* keep = "true", max_fanout = 16 *) preg_t iq1_late_wakeup_preg_q [2];
  logic branch_resolve_valid, branch_target_misaligned;
  logic [31:0] branch_actual_next;
  logic [31:0] branch_fallthrough, branch_direct_target;
  logic [31:0] branch_direct_fetch_next, branch_fallthrough_fetch_next;
  logic [31:0] branch_indirect_fetch_next, branch_redirect_fetch_next;
  logic branch_predicted_taken_mismatch;
  logic branch_predicted_fallthrough_mismatch;
  logic [3:0] branch_checkpoint_id;
  logic branch_has_checkpoint;
  logic branch_resolve_valid_q, branch_resolve_actual_taken_q;
  logic branch_resolve_is_branch_q, branch_resolve_is_jalr_q;
  logic branch_resolve_is_call_q, branch_resolve_is_return_q;
  logic branch_resolve_trap_q, branch_resolve_mispredict_q;
  logic branch_resolve_checkpoint_valid_q;
  logic [3:0] branch_resolve_checkpoint_id_q;
  logic [31:0] branch_resolve_pc_q, branch_resolve_target_q;
  logic ex1_immediate_completion;
  logic mul_rsp_live;
  logic lq_wb_live;
  logic ex0_forward_valid, ex1_forward_valid;
  logic mul_pipe_valid_q, mul_pipe_live, mul_pipe_ready;
  logic mul_pipe_accept, mul_pipe_advance, mul_pipe_completion_selected;
  logic mul_pipe_recovery_kill, mul_pipe_forward_valid;
  uop_id_t mul_pipe_uop_id_q;
  preg_t mul_pipe_pdst_q;
  (* keep = "true", max_fanout = 16 *) preg_t mul_pipe_pdst_iq0_q;
  (* keep = "true", max_fanout = 16 *) preg_t mul_pipe_pdst_iq1_q;
  uop_op_e mul_pipe_op_q;
  logic mul_pipe_rd_wen_q, mul_pipe_fetch_fault_q;
  logic [31:0] mul_pipe_pc_q, mul_pipe_rs1_q, mul_pipe_rs2_q;
  logic [31:0] mul_pipe_product_ll, mul_pipe_product_lh;
  logic [31:0] mul_pipe_product_hl, mul_pipe_product_hh;
  logic [17:0] mul_pipe_middle_sum, mul_pipe_high_cross_sum;
  logic [32:0] mul_pipe_unsigned_high_sum, mul_pipe_correction_sum;
  logic [31:0] mul_pipe_low_result, mul_pipe_unsigned_high;
  logic [31:0] mul_pipe_correction;
  logic mul_result_valid_q, mul_result_live, mul_result_recovery_kill;
  uop_id_t mul_result_uop_id_q;
  preg_t mul_result_pdst_q;
  uop_op_e mul_result_op_q;
  logic mul_result_rd_wen_q, mul_result_fetch_fault_q;
  logic [31:0] mul_result_pc_q;
  logic [31:0] mul_result_low_q, mul_result_high_q;
  logic [31:0] mul_result_correction_q, mul_pipe_result;
  logic ex0_recovery_kill;
  logic [1:0] predictor_dispatch_checkpoint_valid;
  logic [1:0] predictor_dispatch_call, predictor_dispatch_return;
  logic [1:0] predictor_commit_valid, predictor_commit_branch;
  logic [1:0] predictor_commit_taken, predictor_commit_call;
  logic [1:0] predictor_commit_return;
  logic [31:0] predictor_commit_pc [2];
  logic [1:0] predictor_commit_valid_q, predictor_commit_branch_q;
  logic [1:0] predictor_commit_taken_q, predictor_commit_call_q;
  logic [1:0] predictor_commit_return_q;
  logic [31:0] predictor_commit_pc_q [2];
  logic commit_fencei;

  assign ex1_immediate_completion = ex1_live &&
    (ex1_is_lsu_q
      ? (ex1_lsu_q.fetch_fault || !ex1_lsu_q.is_load ||
         ex1_load_misaligned)
      : (!is_div_op(ex1_q.op) && !is_mul_op(ex1_q.op)));
  // The iterative divider cannot abort an operation already in MD_DIV.  A
  // branch/global recovery can therefore leave a physical response pending
  // after its ROB slot has been removed.  Local ownership alone is not enough
  // once that slot is retired or reused: qualify the cold divide-response path
  // with the exact live ROB metadata before it may reach completion or PRF.
  // The stale response is still accepted below, allowing the divider to return
  // to IDLE without creating an architectural writeback.
  assign mul_rsp_live = mul_rsp_valid && div_inflight_q &&
    (mul_rsp_uop_id == div_inflight_uop_id_q) &&
    meta_valid_q[rob_index(uop_rob_ptr(mul_rsp_uop_id))] &&
    (meta_uop_id_q[rob_index(uop_rob_ptr(mul_rsp_uop_id))] == mul_rsp_uop_id);

  // The four registered DSP partial products are followed by one elastic
  // reconstruction boundary.  This keeps independent multiplies at one per
  // cycle, but prevents DSP -> two carry chains -> global bypass from landing
  // on an EX operand register in one 150 MHz period.  The high-half signed
  // correction is pre-added here and applied as one subtract after the local
  // result register.
  always_comb begin
    // Bits 16..31 and the two-bit carry into bit 32 are exactly the sum of
    // ll[31:16], lh[15:0], and hl[15:0].  This avoids constructing a needless
    // 64-bit product bus before selecting an RV32 result half.
    mul_pipe_middle_sum = {2'b0, mul_pipe_product_ll[31:16]} +
                          {2'b0, mul_pipe_product_lh[15:0]} +
                          {2'b0, mul_pipe_product_hl[15:0]};
    mul_pipe_high_cross_sum = {2'b0, mul_pipe_product_lh[31:16]} +
                              {2'b0, mul_pipe_product_hl[31:16]} +
                              {16'b0, mul_pipe_middle_sum[17:16]};
    mul_pipe_unsigned_high_sum = {1'b0, mul_pipe_product_hh} +
                                 {15'b0, mul_pipe_high_cross_sum};
    mul_pipe_low_result = {mul_pipe_middle_sum[15:0],
                           mul_pipe_product_ll[15:0]};
    mul_pipe_unsigned_high = mul_pipe_unsigned_high_sum[31:0];
    mul_pipe_correction_sum =
      {1'b0, (((mul_pipe_op_q inside {UOP_MULH, UOP_MULHSU}) &&
               mul_pipe_rs1_q[31]) ? mul_pipe_rs2_q : 32'b0)} +
      {1'b0, (((mul_pipe_op_q == UOP_MULH) && mul_pipe_rs2_q[31])
              ? mul_pipe_rs1_q : 32'b0)};
    mul_pipe_correction = mul_pipe_correction_sum[31:0];

    unique case (mul_result_op_q)
      UOP_MUL:    mul_pipe_result = mul_result_low_q;
      UOP_MULH,
      UOP_MULHSU: mul_pipe_result = mul_result_high_q -
                                    mul_result_correction_q;
      default:    mul_pipe_result = mul_result_high_q;
    endcase
  end

  rv32_mul_partial_products u_mul_partial_products (
    .clk_i(clk_i), .rst_ni(rst_ni), .enable_i(mul_pipe_accept),
    .operand_a_i(ex1_rs1_q), .operand_b_i(ex1_rs2_q),
    .product_ll_o(mul_pipe_product_ll),
    .product_lh_o(mul_pipe_product_lh),
    .product_hl_o(mul_pipe_product_hl),
    .product_hh_o(mul_pipe_product_hh)
  );

  assign mul_pipe_recovery_kill = branch_recovery_valid_exec_q &&
    rob_ptr_in_range(uop_rob_ptr(mul_pipe_uop_id_q),
                     branch_recovery_tail_exec_q,
                     branch_recovery_end_exec_q);
  assign mul_result_recovery_kill = branch_recovery_valid_exec_q &&
    rob_ptr_in_range(uop_rob_ptr(mul_result_uop_id_q),
                     branch_recovery_tail_exec_q,
                     branch_recovery_end_exec_q);
  assign mul_pipe_live = mul_pipe_valid_q && !mul_pipe_recovery_kill;
  assign mul_result_live = mul_result_valid_q && !mul_result_recovery_kill;
  assign mul_pipe_advance = mul_pipe_live &&
                            (!mul_result_live || mul_pipe_completion_selected) &&
                            !commit_flush;
  assign mul_pipe_ready = !mul_pipe_valid_q || mul_pipe_recovery_kill ||
                          mul_pipe_advance;
  assign mul_pipe_accept = ex1_live && !ex1_is_lsu_q &&
    is_mul_op(ex1_q.op) &&
    mul_pipe_ready && !commit_flush &&
                           !(branch_recovery_valid_exec_q &&
                             rob_ptr_in_range(ex1_q.rob_ptr,
                               branch_recovery_tail_exec_q,
                               branch_recovery_end_exec_q));
  // Forwarding is data-path state.  A commit flush clears the consumer queues
  // and producer valid bits at the edge, so qualifying this combinational tag
  // with the global flush only creates a false flush -> IQ -> EX data cone.
  assign mul_pipe_forward_valid = mul_result_live && mul_result_rd_wen_q &&
                                  !mul_result_fetch_fault_q;

  always_comb begin
    ex0_recovery_kill = branch_recovery_valid_exec_q &&
      rob_ptr_in_range(ex0_q.rob_ptr, branch_recovery_tail_exec_q,
                       branch_recovery_end_exec_q);
    branch_resolve_valid = ex0_live && ex0_branch_control &&
                           !ex0_q.fetch_fault && !commit_flush &&
                           !ex0_recovery_kill;
    branch_fallthrough = ex0_q.pc + 32'd4;
    branch_direct_target = ex0_q.pc + ex0_q.imm;
    branch_actual_next = ex0_q.is_branch
      ? (ex0_branch_taken ? branch_direct_target : branch_fallthrough)
      : ex0_branch_target;
    // For conditional branches compute both prediction comparisons in
    // parallel with the rs1/rs2 condition.  Selecting one mismatch bit avoids
    // the former condition -> 32-bit target mux -> 32-bit equality chain.
    // Precompute both conditional outcomes in parallel with rs1/rs2 compare.
    // The compare result then controls only a final 32-bit mux; it no longer
    // precedes another carry chain on the fetch-PC critical path.
    branch_direct_fetch_next = branch_direct_target +
      (branch_direct_target[2] ? 32'd4 : 32'd8);
    branch_fallthrough_fetch_next = branch_fallthrough +
      (branch_fallthrough[2] ? 32'd4 : 32'd8);
    branch_indirect_fetch_next = ex0_branch_target +
      (ex0_branch_target[2] ? 32'd4 : 32'd8);
    branch_redirect_fetch_next = ex0_q.is_branch
      ? (ex0_branch_taken ? branch_direct_fetch_next
                          : branch_fallthrough_fetch_next)
      : branch_indirect_fetch_next;
    branch_predicted_taken_mismatch =
      (branch_direct_target != ex0_q.predicted_pc);
    branch_predicted_fallthrough_mismatch =
      (branch_fallthrough != ex0_q.predicted_pc);
    branch_target_misaligned = branch_resolve_valid && ex0_branch_taken &&
                               (|branch_actual_next[1:0]);
    branch_has_checkpoint =
      meta_checkpoint_valid_q[rob_index(ex0_q.rob_ptr)];
    branch_checkpoint_id = meta_checkpoint_id_q[rob_index(ex0_q.rob_ptr)];
    branch_recovery_tail = rob_ptr_add(ex0_q.rob_ptr, 2'd1);
    branch_mispredict = branch_resolve_valid &&
      (branch_target_misaligned ||
       (ex0_q.is_branch
        ? (ex0_branch_taken ? branch_predicted_taken_mismatch
                            : branch_predicted_fallthrough_mismatch)
        : (branch_actual_next != ex0_q.predicted_pc)));

    wb0_valid = ex0_live;
    wb0_id = ex0_q.uop_id;
    wb0_pdst = ex0_q.pdst;
    wb0_rd_wen = ex0_q.rd_wen;
    wb0_result = ex0_result;
    wb0_exception = ex0_q.fetch_fault || branch_target_misaligned;
    wb0_cause = ex0_q.fetch_fault ? 32'd1 :
                branch_target_misaligned ? 32'd0 : 32'b0;
    wb0_tval = ex0_q.fetch_fault ? ex0_q.pc :
                branch_target_misaligned ? branch_actual_next : 32'b0;

    // The LQ validates seq/uop identity on response, suppresses killed entries
    // during recovery, and only advertises a still-valid completed entry.
    // Re-reading the global metadata table here duplicated that check and put
    // the cache response behind a 32-entry mux before ROB completion.
    lq_wb_live = lq_wb_valid;
    wb0_pipe_live = wb0_pipe_valid_q;
    wb1_pipe_live = wb1_pipe_valid_q;

    wb1_valid = 1'b0; wb1_id = '0; wb1_pdst = '0; wb1_rd_wen = 1'b0;
    wb1_result = '0; wb1_exception = 1'b0; wb1_cause = '0; wb1_tval = '0;
    lq_wb_ready = 1'b0;
    mul_rsp_ready = 1'b0;
    mul_pipe_completion_selected = 1'b0;
    ex1_completion_selected = 1'b0;
    if (lq_wb_valid) begin
      lq_wb_ready = 1'b1;
      if (lq_wb_live) begin
        wb1_valid = 1'b1; wb1_id = lq_wb_uop_id; wb1_pdst = lq_wb_pdst;
        // Every architectural load writes its allocated destination; x0 is
        // represented by physical zero.  Avoid a redundant 32-entry metadata
        // read on the cache-response/writeback path.
        wb1_rd_wen = (lq_wb_pdst != '0);
        wb1_result = lq_wb_data;
        wb1_exception = lq_wb_error;
        wb1_cause = lq_wb_error ? 32'd5 : 32'b0;
        wb1_tval = lq_wb_error ? lq_wb_fault_addr : 32'b0;
      end
    end else if (mul_rsp_valid) begin
      mul_rsp_ready = 1'b1;
      if (mul_rsp_live) begin
        wb1_valid = 1'b1; wb1_id = mul_rsp_uop_id;
        wb1_pdst = meta_pdst_q[rob_index(uop_rob_ptr(mul_rsp_uop_id))];
        wb1_result = mul_rsp_result;
        wb1_rd_wen = meta_rd_wen_q[rob_index(uop_rob_ptr(mul_rsp_uop_id))];
      end
    end else if (mul_result_live) begin
      mul_pipe_completion_selected = 1'b1;
      wb1_valid = 1'b1;
      wb1_id = mul_result_uop_id_q;
      wb1_pdst = mul_result_pdst_q;
      wb1_rd_wen = mul_result_rd_wen_q;
      wb1_result = mul_pipe_result;
      if (mul_result_fetch_fault_q) begin
        wb1_exception = 1'b1;
        wb1_cause = 32'd1;
        wb1_tval = mul_result_pc_q;
      end
    end else if (ex1_immediate_completion) begin
      ex1_completion_selected = 1'b1;
      wb1_valid = 1'b1;
      if (ex1_is_lsu_q) begin
        wb1_id = ex1_lsu_q.uop_id;
        wb1_pdst = ex1_lsu_q.pdst;
        wb1_rd_wen = ex1_lsu_q.rd_wen;
        wb1_result = 32'b0;
        if (ex1_lsu_q.fetch_fault) begin
          wb1_exception = 1'b1;
          wb1_cause = 32'd1;
          wb1_tval = ex1_lsu_q.pc;
        end else if (ex1_load_misaligned) begin
          wb1_exception = 1'b1;
          wb1_cause = 32'd4;
          wb1_tval = ex1_mem_addr;
        end else if (ex1_store_misaligned) begin
          wb1_exception = 1'b1;
          wb1_cause = 32'd6;
          wb1_tval = ex1_mem_addr;
        end else if (ex1_store_access_fault) begin
          wb1_exception = 1'b1;
          wb1_cause = 32'd7;
          wb1_tval = ex1_mem_addr;
        end
      end else begin
        wb1_id = ex1_q.uop_id;
        wb1_pdst = ex1_q.pdst;
        wb1_rd_wen = ex1_q.rd_wen;
        wb1_result = ex1_forward_result;
        if (ex1_q.fetch_fault) begin
          wb1_exception = 1'b1; wb1_cause = 32'd1; wb1_tval = ex1_q.pc;
        end else if (ex1_q.op == UOP_ILLEGAL) begin
          wb1_exception = 1'b1; wb1_cause = 32'd2; wb1_tval = ex1_q.inst;
        end else if (ex1_q.op == UOP_EBREAK) begin
          wb1_exception = 1'b1; wb1_cause = 32'd3; wb1_tval = 32'b0;
        end else if (ex1_q.op == UOP_ECALL) begin
          wb1_exception = 1'b1; wb1_cause = 32'd11; wb1_tval = 32'b0;
        end else if (csr_exec_illegal) begin
          wb1_exception = 1'b1; wb1_cause = 32'd2; wb1_tval = ex1_q.inst;
        end
      end
    end

    // Completion updates only the selected ROB row, so it does not need to
    // wait behind the high-fanout PRF/IQ writeback boundary.  The PRF value
    // still crosses wb*_pipe_q below; a consumer is supplied by its explicit
    // write-through bypass.  This lets the head retire one cycle earlier
    // without restoring the former execution-to-global-fanout timing path.
    rob_complete_valid = {wb1_valid, wb0_valid};
    rob_complete_uop_id[0] = wb0_id;
    rob_complete_uop_id[1] = wb1_id;
    rob_complete_result[0] = wb0_result;
    rob_complete_result[1] = wb1_result;
    rob_complete_exception = {wb1_exception, wb0_exception};
    rob_complete_cause[0] = wb0_cause;
    rob_complete_cause[1] = wb1_cause;
    rob_complete_tval[0] = wb0_tval;
    rob_complete_tval[1] = wb1_tval;

    prf_wb_valid[0] = !commit_flush && !wb0_pipe_recovery_kill &&
                      wb0_pipe_live && wb0_pipe_rd_wen_q &&
                      !wb0_pipe_exception_q;
    prf_wb_valid[1] = !commit_flush && !wb1_pipe_recovery_kill &&
                      wb1_pipe_live && wb1_pipe_rd_wen_q &&
                      !wb1_pipe_exception_q;
    // The PRF write itself must remain suppressed during a global flush.  The
    // issue/rename bypass, however, is observed only by work that cannot be
    // accepted on that flush edge.  Use a separate ungated data-path validity
    // so commit_flush does not traverse the operand selection network.
    issue_wb_forward_valid[0] = !wb0_pipe_recovery_kill &&
                                wb0_pipe_live && wb0_pipe_rd_wen_q &&
                                !wb0_pipe_exception_q;
    issue_wb_forward_valid[1] = !wb1_pipe_recovery_kill &&
                                wb1_pipe_live && wb1_pipe_rd_wen_q &&
                                !wb1_pipe_exception_q;
    prf_wb_preg[0] = wb0_pipe_pdst_q;
    prf_wb_preg[1] = wb1_pipe_pdst_q;
    prf_wb_data[0] = wb0_pipe_result_q;
    prf_wb_data[1] = wb1_pipe_result_q;

  end

  assign wb0_pipe_recovery_kill = branch_recovery_valid_exec_q &&
    rob_ptr_in_range(uop_rob_ptr(wb0_pipe_id_q),
                     branch_recovery_tail_exec_q,
                     branch_recovery_end_exec_q);
  assign wb1_pipe_recovery_kill = branch_recovery_valid_exec_q &&
    rob_ptr_in_range(uop_rob_ptr(wb1_pipe_id_q),
                     branch_recovery_tail_exec_q,
                     branch_recovery_end_exec_q);

  // Capture the same architecturally live writes as the canonical PRF pipe,
  // but include class/error here so each IQ receives only a compact tag event.
  // A later branch recovery does not need to gate these local events: every
  // consumer of a killed producer is in the same younger suffix and is removed
  // by that IQ's exact recovery state update.
  assign wb0_iq_wakeup_capture = wb0_valid && wb0_rd_wen &&
    !wb0_exception && !commit_flush &&
    !(branch_recovery_valid_exec_q &&
      rob_ptr_in_range(uop_rob_ptr(wb0_id), branch_recovery_tail_exec_q,
                       branch_recovery_end_exec_q));
  assign wb1_iq_wakeup_capture = wb1_valid && wb1_rd_wen &&
    !wb1_exception && !commit_flush &&
    !(branch_recovery_valid_exec_q &&
      rob_ptr_in_range(uop_rob_ptr(wb1_id), branch_recovery_tail_exec_q,
                       branch_recovery_end_exec_q));

  // Fast wakeup is a property captured at the existing IQ/EX boundary.  Do
  // not feed recovery range compares back into every IQ CAM: a consumer is
  // always younger than its producer, so if recovery kills this producer then
  // every matching consumer is in the same killed suffix.  The IQ recovery
  // logic suppresses/removes those rows at this edge, while WB/EX validity
  // still uses the exact recovery kill below.  This cuts the otherwise global
  // recovery-pointer -> wakeup -> age-select path without changing a live
  // dependency's zero-cycle forwarding latency.
  assign ex0_forward_valid = ex0_live && ex0_forward_class_q;
  assign ex1_forward_valid = ex1_live && ex1_forward_class_q;

  always_comb begin
    // Fixed-latency tags originate at the existing registered IQ/EX boundary,
    // never at the current IQ issue output.  The queues use these tags both to
    // make readiness persistent at the edge and as a local selection bypass;
    // this retains back-to-back dependencies without a zero-cycle feedback
    // loop between the two issue queues.
    wakeup_valid_iq0[0] = ex0_forward_valid;
    wakeup_valid_iq0[1] = ex1_forward_valid;
    wakeup_valid_iq0[2] = mul_pipe_advance;
    wakeup_valid_iq1[0] = ex0_forward_valid;
    wakeup_valid_iq1[1] = ex1_forward_valid;
    wakeup_valid_iq1[2] = mul_pipe_advance;
    // Late consumers use the registered PRF write boundary.  The old direct
    // WB0 fallback coupled EX0 branch/exception logic to every IQ tag compare;
    // issue-time wakeup still preserves the fast common case.
    wakeup_valid_iq0[3] = iq0_late_wakeup_valid_q[0];
    wakeup_valid_iq0[4] = iq0_late_wakeup_valid_q[1];
    wakeup_valid_iq1[3] = iq1_late_wakeup_valid_q[0];
    wakeup_valid_iq1[4] = iq1_late_wakeup_valid_q[1];
    wakeup_preg_iq0[0] = ex0_forward_pdst_iq0_q;
    wakeup_preg_iq0[1] = ex1_forward_pdst_iq0_q;
    wakeup_preg_iq0[2] = mul_pipe_pdst_iq0_q;
    wakeup_preg_iq0[3] = iq0_late_wakeup_preg_q[0];
    wakeup_preg_iq0[4] = iq0_late_wakeup_preg_q[1];
    wakeup_preg_iq1[0] = ex0_forward_pdst_iq1_q;
    wakeup_preg_iq1[1] = ex1_forward_pdst_iq1_q;
    wakeup_preg_iq1[2] = mul_pipe_pdst_iq1_q;
    wakeup_preg_iq1[3] = iq1_late_wakeup_preg_q[0];
    wakeup_preg_iq1[4] = iq1_late_wakeup_preg_q[1];
    select_wakeup_valid_iq0[0] = ex0_forward_valid;
    select_wakeup_valid_iq0[1] = ex1_forward_valid;
    select_wakeup_valid_iq0[2] = 1'b0;
    select_wakeup_valid_iq1[0] = ex0_forward_valid;
    select_wakeup_valid_iq1[1] = ex1_forward_valid;
    // Both queues still record PRF1 through persistent wakeup on this edge.
    // Restrict only the zero-cycle PRF1 selection bypass to IQ1, where loads,
    // stores and multiply/divide operations reside; this removes the duplicate
    // IQ0 CAM/age fanout without changing architectural readiness.
    select_wakeup_valid_iq1[2] = iq1_late_wakeup_valid_q[1];
    select_wakeup_preg_iq0[0] = ex0_forward_pdst_iq0_q;
    select_wakeup_preg_iq0[1] = ex1_forward_pdst_iq0_q;
    select_wakeup_preg_iq0[2] = iq0_late_wakeup_preg_q[1];
    select_wakeup_preg_iq1[0] = ex0_forward_pdst_iq1_q;
    select_wakeup_preg_iq1[1] = ex1_forward_pdst_iq1_q;
    select_wakeup_preg_iq1[2] = iq1_late_wakeup_preg_q[1];
  end

  // Terminate late-WB producer identity on the same side as each pair of PRF
  // read ports. EX0/EX1 matches now come directly from the IQ CAM result, so
  // their former duplicate post-PRF tag aliases are intentionally absent.
  always_comb begin
    issue_wb0_forward_pdst[0] = iq0_late_wakeup_preg_q[0];
    issue_wb0_forward_pdst[1] = iq0_late_wakeup_preg_q[0];
    issue_wb0_forward_pdst[2] = iq1_late_wakeup_preg_q[0];
    issue_wb0_forward_pdst[3] = iq1_late_wakeup_preg_q[0];
    issue_wb1_forward_pdst[0] = iq0_late_wakeup_preg_q[1];
    issue_wb1_forward_pdst[1] = iq0_late_wakeup_preg_q[1];
    issue_wb1_forward_pdst[2] = iq1_late_wakeup_preg_q[1];
    issue_wb1_forward_pdst[3] = iq1_late_wakeup_preg_q[1];
  end

  // IQ readiness changes only at a clock boundary.  Speculative issue tags let
  // a fixed-latency dependent be selected while its producer executes; these
  // two local result muxes then supply the value at the execution-register
  // boundary.  The former result -> global wakeup -> age selection chain is
  // absent, while back-to-back dependencies still sustain one result/cycle.
  always_comb begin
    for (int unsigned port = 0; port < 4; port++) begin
      // The raw PRF read contains only stored state.  All in-flight producer
      // values, including the two registered WB ports, are merged exactly once
      // at this execution-lane boundary.
      // The IQ has already performed these CAM comparisons to decide which
      // just-woken row may issue.  Carry the selected match across the module
      // boundary instead of repeating a six-bit tag comparator after the PRF
      // read mux.  This cuts the fast wakeup path at the IQ/EX boundary while
      // preserving the same-cycle dependent issue behaviour.
      issue_forward_hit[port][0] = (port < 2)
        ? (port[0] ? iq0_issue_src2_select_hit[0]
                   : iq0_issue_src1_select_hit[0])
        : (port[0] ? iq1_issue_src2_select_hit[0]
                   : iq1_issue_src1_select_hit[0]);
      issue_forward_hit[port][1] = (port < 2)
        ? (port[0] ? iq0_issue_src2_select_hit[1]
                   : iq0_issue_src1_select_hit[1])
        : (port[0] ? iq1_issue_src2_select_hit[1]
                   : iq1_issue_src1_select_hit[1]);
      issue_forward_hit[port][2] = mul_pipe_forward_valid &&
        (prf_read_addr[port] != '0) &&
        (prf_read_addr[port] == mul_result_pdst_q);
      issue_forward_hit[port][3] = issue_wb_forward_valid[0] &&
        (prf_read_addr[port] != '0) &&
        (prf_read_addr[port] == issue_wb0_forward_pdst[port]);
      issue_forward_hit[port][4] = (port >= 2)
        ? (port[0] ? iq1_issue_src2_select_hit[2]
                   : iq1_issue_src1_select_hit[2])
        : (issue_wb_forward_valid[1] &&
           (prf_read_addr[port] != '0) &&
           (prf_read_addr[port] == issue_wb1_forward_pdst[port]));

      // Rename guarantees that only one live producer owns a physical tag.
      // Express the forwarding choice as a parallel one-hot merge instead of
      // three serial priority muxes in front of every EX operand bit.
      issue_read_data[port] =
        ({32{!(|issue_forward_hit[port])}} & prf_read_data[port]) |
        ({32{issue_forward_hit[port][0]}} & wb0_result) |
        ({32{issue_forward_hit[port][1]}} & ex1_forward_result) |
        ({32{issue_forward_hit[port][2]}} & mul_pipe_result) |
        ({32{issue_forward_hit[port][3]}} & prf_wb_data[0]) |
        ({32{issue_forward_hit[port][4]}} & prf_wb_data[1]);
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned port = 0; port < 4; port++) begin
        assert ($onehot0(issue_forward_hit[port]))
          else $fatal(1, "multiple live producers matched PRF read port %0d",
                      port);
      end
    end
  end
`endif

  always_comb begin
    ex1_recovery_kill = branch_recovery_valid_exec_q && ex1_valid_q &&
      rob_ptr_in_range(ex1_is_lsu_q ? ex1_lsu_q.rob_ptr : ex1_q.rob_ptr,
                       branch_recovery_tail_exec_q,
                       branch_recovery_end_exec_q);
    ex1_slot_available = !ex1_valid_q || ex1_recovery_kill;
    if (ex1_valid_q && !ex1_recovery_kill) begin
      if (ex1_is_lsu_q) begin
        if (ex1_lsu_q.is_load)
          ex1_slot_available =
            ((ex1_lsu_q.fetch_fault || ex1_load_misaligned) &&
             ex1_completion_selected) ||
            (!ex1_lsu_q.fetch_fault && !ex1_load_misaligned &&
             lq_execute_valid);
        else
          ex1_slot_available = ex1_completion_selected;
      end else if (is_div_op(ex1_q.op))
        ex1_slot_available = mul_req_valid && mul_req_ready;
      else if (is_mul_op(ex1_q.op))
        ex1_slot_available = mul_pipe_accept;
      else
        ex1_slot_available = ex1_completion_selected;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      mul_pipe_valid_q <= 1'b0;
      mul_pipe_uop_id_q <= '0;
      mul_pipe_pdst_q <= '0;
      mul_pipe_pdst_iq0_q <= '0;
      mul_pipe_pdst_iq1_q <= '0;
      mul_pipe_op_q <= UOP_ADD;
      mul_pipe_rd_wen_q <= 1'b0;
      mul_pipe_fetch_fault_q <= 1'b0;
      mul_pipe_pc_q <= '0;
      mul_pipe_rs1_q <= '0;
      mul_pipe_rs2_q <= '0;
    end else begin
      if (mul_pipe_advance || commit_flush ||
          mul_pipe_recovery_kill)
        mul_pipe_valid_q <= 1'b0;
      if (mul_pipe_accept) begin
        mul_pipe_valid_q <= 1'b1;
        mul_pipe_uop_id_q <= ex1_q.uop_id;
        mul_pipe_pdst_q <= ex1_q.pdst;
        mul_pipe_pdst_iq0_q <= ex1_q.pdst;
        mul_pipe_pdst_iq1_q <= ex1_q.pdst;
        mul_pipe_op_q <= ex1_q.op;
        mul_pipe_rd_wen_q <= ex1_q.rd_wen;
        mul_pipe_fetch_fault_q <= ex1_q.fetch_fault;
        mul_pipe_pc_q <= ex1_q.pc;
        mul_pipe_rs1_q <= ex1_rs1_q;
        mul_pipe_rs2_q <= ex1_rs2_q;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      mul_result_valid_q <= 1'b0;
      mul_result_uop_id_q <= '0;
      mul_result_pdst_q <= '0;
      mul_result_op_q <= UOP_ADD;
      mul_result_rd_wen_q <= 1'b0;
      mul_result_fetch_fault_q <= 1'b0;
      mul_result_pc_q <= '0;
      mul_result_low_q <= '0;
      mul_result_high_q <= '0;
      mul_result_correction_q <= '0;
    end else begin
      if (mul_pipe_completion_selected || commit_flush ||
          mul_result_recovery_kill)
        mul_result_valid_q <= 1'b0;
      if (mul_pipe_advance) begin
        mul_result_valid_q <= 1'b1;
        mul_result_uop_id_q <= mul_pipe_uop_id_q;
        mul_result_pdst_q <= mul_pipe_pdst_q;
        mul_result_op_q <= mul_pipe_op_q;
        mul_result_rd_wen_q <= mul_pipe_rd_wen_q;
        mul_result_fetch_fault_q <= mul_pipe_fetch_fault_q;
        mul_result_pc_q <= mul_pipe_pc_q;
        mul_result_low_q <= mul_pipe_low_result;
        mul_result_high_q <= mul_pipe_unsigned_high;
        mul_result_correction_q <= mul_pipe_correction;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      wb0_pipe_valid_q <= 1'b0;
      wb0_pipe_id_q <= '0;
      wb0_pipe_pdst_q <= '0;
      wb0_pipe_rd_wen_q <= 1'b0;
      wb0_pipe_result_q <= '0;
      wb0_pipe_exception_q <= 1'b0;
      wb1_pipe_valid_q <= 1'b0;
      wb1_pipe_id_q <= '0;
      wb1_pipe_pdst_q <= '0;
      wb1_pipe_rd_wen_q <= 1'b0;
      wb1_pipe_result_q <= '0;
      wb1_pipe_exception_q <= 1'b0;
      iq0_late_wakeup_valid_q <= '0;
      iq1_late_wakeup_valid_q <= '0;
      iq0_late_wakeup_preg_q[0] <= '0;
      iq0_late_wakeup_preg_q[1] <= '0;
      iq1_late_wakeup_preg_q[0] <= '0;
      iq1_late_wakeup_preg_q[1] <= '0;
    end else begin
      iq0_late_wakeup_valid_q <= {wb1_iq_wakeup_capture,
                                   wb0_iq_wakeup_capture};
      iq1_late_wakeup_valid_q <= {wb1_iq_wakeup_capture,
                                   wb0_iq_wakeup_capture};
      wb0_pipe_valid_q <= wb0_valid && !commit_flush &&
        !(branch_recovery_valid_exec_q && rob_ptr_in_range(uop_rob_ptr(wb0_id),
          branch_recovery_tail_exec_q, branch_recovery_end_exec_q));
      if (wb0_valid) begin
        wb0_pipe_id_q <= wb0_id;
        wb0_pipe_pdst_q <= wb0_pdst;
        wb0_pipe_rd_wen_q <= wb0_rd_wen;
        wb0_pipe_result_q <= wb0_result;
        wb0_pipe_exception_q <= wb0_exception;
        iq0_late_wakeup_preg_q[0] <= wb0_pdst;
        iq1_late_wakeup_preg_q[0] <= wb0_pdst;
      end
      wb1_pipe_valid_q <= wb1_valid && !commit_flush &&
        !(branch_recovery_valid_exec_q && rob_ptr_in_range(uop_rob_ptr(wb1_id),
          branch_recovery_tail_exec_q, branch_recovery_end_exec_q));
      if (wb1_valid) begin
        wb1_pipe_id_q <= wb1_id;
        wb1_pipe_pdst_q <= wb1_pdst;
        wb1_pipe_rd_wen_q <= wb1_rd_wen;
        wb1_pipe_result_q <= wb1_result;
        wb1_pipe_exception_q <= wb1_exception;
        iq0_late_wakeup_preg_q[1] <= wb1_pdst;
        iq1_late_wakeup_preg_q[1] <= wb1_pdst;
      end
    end
  end

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      predictor_dispatch_checkpoint_valid[lane] =
        checkpoint_alloc_valid[lane] && checkpoint_alloc_accept[lane];
      predictor_dispatch_call[lane] = control_is_call(dec[lane].op, dec[lane].rd);
      predictor_dispatch_return[lane] = control_is_return(
        dec[lane].op, dec[lane].rd, dec[lane].rs1, dec[lane].imm
      );
    end
  end

  branch_predictor u_branch_predictor (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .query_valid_i(predictor_query_valid), .query_pc_i(predictor_query_pc),
    .query_taken_o(frontend_predictor_taken),
    .query_target_o(frontend_predictor_target),
    .query_btb_hit_o(frontend_predictor_btb_hit),
    .speculative_ghr_o(predictor_spec_ghr),
    .dispatch_valid_i(dispatch_take),
    .dispatch_checkpoint_valid_i(predictor_dispatch_checkpoint_valid),
    .dispatch_checkpoint_id_i(checkpoint_alloc_id),
    .dispatch_pc_i('{fetch_buffer_pc_q, fetch_buffer_pc_q + 32'd4}),
    .dispatch_is_branch_i({dec[1].is_branch, dec[0].is_branch}),
    .dispatch_is_call_i(predictor_dispatch_call),
    .dispatch_is_return_i(predictor_dispatch_return),
    .dispatch_pred_taken_i(predictor_taken),
    .resolve_valid_i(branch_resolve_valid_q && !commit_flush),
    .resolve_pc_i(branch_resolve_pc_q),
    .resolve_target_i(branch_resolve_target_q),
    .resolve_actual_taken_i(branch_resolve_actual_taken_q),
    .resolve_is_branch_i(branch_resolve_is_branch_q),
    .resolve_is_jalr_i(branch_resolve_is_jalr_q),
    .resolve_is_call_i(branch_resolve_is_call_q),
    .resolve_is_return_i(branch_resolve_is_return_q),
    .resolve_trap_i(branch_resolve_trap_q),
    .resolve_mispredict_i(branch_resolve_mispredict_q),
    .resolve_checkpoint_valid_i(branch_resolve_checkpoint_valid_q),
    .resolve_checkpoint_id_i(branch_resolve_checkpoint_id_q),
    .release_valid_i(checkpoint_release_valid),
    .release_checkpoint_id_i(checkpoint_release_id),
    .commit_valid_i(predictor_commit_valid_q),
    .commit_pc_i(predictor_commit_pc_q),
    .commit_is_branch_i(predictor_commit_branch_q),
    .commit_actual_taken_i(predictor_commit_taken_q),
    .commit_is_call_i(predictor_commit_call_q),
    .commit_is_return_i(predictor_commit_return_q),
    .global_flush_i(commit_flush),
    .invalidate_i(commit_flush && commit_fencei_q)
  );

  // --------------------------------------------------------------------------
  // Commit, CSR side effects, store serialization, and global redirects.
  // --------------------------------------------------------------------------
  logic commit_mmio_store_request, commit_mmio_store_fire;
  logic commit_mmio_q_valid, commit_mmio_q_fire;
  logic [31:0] commit_mmio_q_addr, commit_mmio_q_data;
  logic [3:0] commit_mmio_q_mask;
  logic head_store_cacheable, head_store_mmio;
  logic memory_queues_empty;
  logic commit_exception, commit_mret, take_interrupt;
  logic [31:0] commit_redirect_target;
  logic [31:0] commit_redirect_target_q;
  rob_ptr_t commit_rob_recovery_tail_q;
  logic [3:0] commit_lq_recovery_tail_q, commit_sq_recovery_tail_q;
  logic [31:0] next_committed_pc_q;
  rob_meta_t head_meta [2];
  logic [ROB_INDEX_W-1:0] meta_head_slot;
  logic [META_BANK_ADDR_W-1:0] meta_head_even_addr, meta_head_odd_addr;
  retire_static_meta_t meta_head_static_even, meta_head_static_odd;
  logic [31:0] meta_head_next_pc_even, meta_head_next_pc_odd;
  retire_ex1_meta_t meta_head_ex1_even, meta_head_ex1_odd;
  retire_static_meta_t meta_head_static [2];
  logic [31:0] meta_head_next_pc [2];
  retire_ex1_meta_t meta_head_ex1 [2];

  always_comb begin
    meta_head_slot = rob_index(rob_head);
    meta_head_odd_addr = meta_head_slot[ROB_INDEX_W-1:1];
    meta_head_even_addr = meta_head_slot[ROB_INDEX_W-1:1] +
                          META_BANK_ADDR_W'(meta_head_slot[0]);
    meta_head_static_even = retire_static_even_q[meta_head_even_addr];
    meta_head_static_odd = retire_static_odd_q[meta_head_odd_addr];
    meta_head_next_pc_even = retire_next_pc_even_q[meta_head_even_addr];
    meta_head_next_pc_odd = retire_next_pc_odd_q[meta_head_odd_addr];
    meta_head_ex1_even = retire_ex1_even_q[meta_head_even_addr];
    meta_head_ex1_odd = retire_ex1_odd_q[meta_head_odd_addr];
    if (meta_head_slot[0]) begin
      meta_head_static[0] = meta_head_static_odd;
      meta_head_static[1] = meta_head_static_even;
      meta_head_next_pc[0] = meta_head_next_pc_odd;
      meta_head_next_pc[1] = meta_head_next_pc_even;
      meta_head_ex1[0] = meta_head_ex1_odd;
      meta_head_ex1[1] = meta_head_ex1_even;
    end else begin
      meta_head_static[0] = meta_head_static_even;
      meta_head_static[1] = meta_head_static_odd;
      meta_head_next_pc[0] = meta_head_next_pc_even;
      meta_head_next_pc[1] = meta_head_next_pc_odd;
      meta_head_ex1[0] = meta_head_ex1_even;
      meta_head_ex1[1] = meta_head_ex1_odd;
    end
    for (int unsigned lane = 0; lane < 2; lane++) begin
      head_meta[lane] = '0;
      head_meta[lane].valid = rob_head_entry[lane].valid;
      head_meta[lane].rob_ptr = rob_head_entry[lane].rob_ptr;
      head_meta[lane].uop_id = rob_head_entry[lane].uop_id;
      head_meta[lane].pdst = rob_head_entry[lane].pdst;
      head_meta[lane].rd_wen = rob_head_entry[lane].rd_wen;
      head_meta[lane].op = meta_head_static[lane].op;
      head_meta[lane].is_serializing = meta_head_static[lane].is_serializing;
      head_meta[lane].is_branch = meta_head_static[lane].is_branch;
      head_meta[lane].is_load = meta_head_static[lane].is_load;
      head_meta[lane].is_store = meta_head_static[lane].is_store;
      head_meta[lane].lq_seq = meta_head_static[lane].lq_seq;
      head_meta[lane].sq_seq = meta_head_static[lane].sq_seq;
      head_meta[lane].actual_next_pc =
        (meta_head_static[lane].is_branch ||
         (meta_head_static[lane].op inside {UOP_JAL,UOP_JALR}))
        ? meta_head_next_pc[lane] : (rob_head_entry[lane].pc + 32'd4);
      head_meta[lane].store_addr = meta_head_ex1[lane].store_addr;
      head_meta[lane].store_data = meta_head_ex1[lane].store_data;
      head_meta[lane].store_mask = meta_head_ex1[lane].store_mask;
      head_meta[lane].store_cacheable =
        meta_head_ex1[lane].store_cacheable;
      head_meta[lane].store_mmio = meta_head_ex1[lane].store_mmio;
      head_meta[lane].csr_write = meta_head_ex1[lane].csr_write;
      head_meta[lane].csr_addr = meta_head_ex1[lane].csr_addr;
      head_meta[lane].csr_wdata = meta_head_ex1[lane].csr_wdata;
    end
  end

  assign head_store_cacheable = head_meta[0].store_cacheable;
  assign head_store_mmio = head_meta[0].store_mmio;
  assign commit_mmio_store_request = !commit_flush &&
                                     rob_head_entry[0].valid &&
                                     rob_head_entry[0].done &&
                                     !rob_head_entry[0].exception &&
                                     head_meta[0].is_store && head_store_mmio &&
                                     sq_committed_empty &&
                                     (sq_head == head_meta[0].sq_seq);
  assign commit_mmio_q_fire = commit_mmio_q_valid && dmem_req_ready_i;
  assign commit_mmio_store_fire = commit_mmio_store_request &&
                                  (!commit_mmio_q_valid || commit_mmio_q_fire);
  assign memory_queues_empty = lq_empty && (sq_count == 0);

  always_comb begin
    retire_count = 2'd0;
    commit_exception = !commit_flush &&
                       rob_head_entry[0].valid &&
                       rob_head_entry[0].done &&
                       rob_head_entry[0].exception;
    commit_mret = !commit_flush &&
                  rob_head_entry[0].valid &&
                  rob_head_entry[0].done &&
                  (head_meta[0].op == UOP_MRET) && !rob_head_entry[0].exception &&
                  memory_queues_empty;
    commit_fencei = !commit_flush &&
                    rob_head_entry[0].valid &&
                    rob_head_entry[0].done &&
                    (head_meta[0].op == UOP_FENCEI) && !rob_head_entry[0].exception &&
                    memory_queues_empty && dcache_clean_done_i;
    dcache_clean_req_o = !commit_flush &&
                         rob_head_entry[0].valid &&
                         rob_head_entry[0].done &&
                         (head_meta[0].op == UOP_FENCEI) &&
                         !rob_head_entry[0].exception && memory_queues_empty &&
                         dcache_idle_i && !dcache_clean_done_i;
    take_interrupt = !commit_flush &&
                     csr_interrupt_pending && (rob_count == 0);

    if (!commit_flush && !commit_exception && !take_interrupt &&
        rob_head_entry[0].valid &&
        rob_head_entry[0].done) begin
      if (head_meta[0].is_store) begin
        if (head_store_cacheable || commit_mmio_store_fire) begin
          retire_count = 2'd1;
          // The store's architectural commitment is recorded by the SQ in
          // this cycle.  A completed, side-effect-free successor can retire
          // with it; preserving a blanket single-retire rule only created a
          // false commit-port dependency.
          if (rob_head_entry[1].valid && rob_head_entry[1].done &&
              !rob_head_entry[1].exception && !head_meta[1].is_load &&
              !head_meta[1].is_store &&
              !(head_meta[1].op inside {UOP_MRET,UOP_FENCE,UOP_FENCEI,
                                        UOP_CSRRW,UOP_CSRRS,UOP_CSRRC,
                                        UOP_CSRRWI,UOP_CSRRSI,UOP_CSRRCI}))
            retire_count = 2'd2;
        end
      end else if (head_meta[0].op inside {UOP_MRET,UOP_FENCE,UOP_FENCEI,
                                           UOP_CSRRW,UOP_CSRRS,UOP_CSRRC,
                                           UOP_CSRRWI,UOP_CSRRSI,UOP_CSRRCI}) begin
        if ((head_meta[0].op == UOP_FENCEI && commit_fencei) ||
            (head_meta[0].op == UOP_FENCE && memory_queues_empty &&
             dcache_idle_i) ||
            (head_meta[0].op == UOP_MRET && commit_mret) ||
            !(head_meta[0].op inside {UOP_MRET,UOP_FENCE,UOP_FENCEI}))
          retire_count = 2'd1;
      end else begin
        retire_count = 2'd1;
        if (rob_head_entry[1].valid && rob_head_entry[1].done &&
            !rob_head_entry[1].exception && !head_meta[1].is_store &&
            !(head_meta[1].op inside {UOP_MRET,UOP_FENCE,UOP_FENCEI,
                                      UOP_CSRRW,UOP_CSRRS,UOP_CSRRC,
                                      UOP_CSRRWI,UOP_CSRRSI,UOP_CSRRCI}))
          retire_count = 2'd2;
      end
    end

    // Registered recovery removes only younger work.  Older completed heads
    // remain architecturally ordered and may retire while the queues install
    // their survivor state; ROB/LQ/SQ all consume the matching post-retire
    // heads on this edge.
    if (branch_recovery_valid_q && !commit_flush) begin
      if (branch_recovery_tail_q == rob_head)
        retire_count = 2'd0;
      else if ((branch_recovery_tail_q == rob_ptr_add(rob_head, 2'd1)) &&
               (retire_count == 2))
        retire_count = 2'd1;
    end
    retire_lane_valid[0] = (retire_count != 0);
    retire_lane_valid[1] = (retire_count == 2);

    sq_commit_valid = retire_lane_valid[0] && head_meta[0].is_store;
    sq_commit_seq = head_meta[0].sq_seq;
    sq_commit_remove = sq_commit_valid && head_store_mmio;

    lq_release_valid = '0;
    lq_release_seq[0] = '0;
    lq_release_seq[1] = '0;
    if (retire_lane_valid[0] && head_meta[0].is_load) begin
      lq_release_valid[0] = 1'b1;
      lq_release_seq[0] = head_meta[0].lq_seq;
      if (retire_lane_valid[1] && head_meta[1].is_load) begin
        lq_release_valid[1] = 1'b1;
        lq_release_seq[1] = head_meta[1].lq_seq;
      end
    end else if (retire_lane_valid[1] && head_meta[1].is_load) begin
      lq_release_valid[0] = 1'b1;
      lq_release_seq[0] = head_meta[1].lq_seq;
    end

    commit_flush_request = commit_exception || commit_mret ||
                           commit_fencei || take_interrupt;
    if (commit_exception || take_interrupt) commit_redirect_target = csr_trap_vector;
    else if (commit_mret) commit_redirect_target = csr_mret_pc;
    else commit_redirect_target = rob_head_entry[0].pc + 32'd4;

    csr_trap_valid = commit_exception || take_interrupt;
    csr_trap_pc = commit_exception ? rob_head_entry[0].pc : next_committed_pc_q;
    csr_trap_cause = commit_exception ? rob_head_entry[0].cause : csr_interrupt_cause;
    csr_trap_tval = commit_exception ? rob_head_entry[0].tval : 32'b0;
    csr_mret = commit_mret;
    csr_commit_write = (retire_count != 0) && head_meta[0].csr_write &&
                       !rob_head_entry[0].exception;
    csr_commit_addr = head_meta[0].csr_addr;
    csr_commit_data = head_meta[0].csr_wdata;

    for (int unsigned lane = 0; lane < 2; lane++) begin
      commit_map_valid[lane] = retire_lane_valid[lane] && rob_head_entry[lane].rd_wen;
      commit_map_rd[lane] = rob_head_entry[lane].rd_addr;
      commit_map_pdst[lane] = rob_head_entry[lane].pdst;
      commit_free_valid[lane] = commit_map_valid[lane];
      commit_free_preg[lane] = rob_head_entry[lane].stale_pdst;
      commit_trace_o[lane] = '0;
      commit_trace_o[lane].valid = retire_lane_valid[lane];
      commit_trace_o[lane].pc = rob_head_entry[lane].pc;
      commit_trace_o[lane].inst = rob_head_entry[lane].inst;
      commit_trace_o[lane].rd_wen = rob_head_entry[lane].rd_wen;
      commit_trace_o[lane].rd_addr = rob_head_entry[lane].rd_addr;
      commit_trace_o[lane].rd_data = rob_head_entry[lane].result;
      commit_trace_o[lane].mem_wen = head_meta[lane].is_store;
      commit_trace_o[lane].mem_addr = head_meta[lane].store_addr;
      commit_trace_o[lane].mem_data = head_meta[lane].store_data;
      commit_trace_o[lane].mem_mask = head_meta[lane].store_mask;
      commit_trace_o[lane].exception = rob_head_entry[lane].exception;
      commit_trace_o[lane].cause = rob_head_entry[lane].cause;
      commit_trace_o[lane].tval = rob_head_entry[lane].tval;

      predictor_commit_valid[lane] = retire_lane_valid[lane];
      predictor_commit_pc[lane] = rob_head_entry[lane].pc;
      predictor_commit_branch[lane] = retire_lane_valid[lane] &&
                                      head_meta[lane].is_branch;
      predictor_commit_taken[lane] =
        head_meta[lane].actual_next_pc != (rob_head_entry[lane].pc + 32'd4);
      predictor_commit_call[lane] = retire_lane_valid[lane] && control_is_call(
        head_meta[lane].op, rob_head_entry[lane].inst[11:7]
      );
      predictor_commit_return[lane] = retire_lane_valid[lane] && control_is_return(
        head_meta[lane].op, rob_head_entry[lane].inst[11:7],
        rob_head_entry[lane].inst[19:15],
        {{20{rob_head_entry[lane].inst[31]}}, rob_head_entry[lane].inst[31:20]}
      );
    end

    checkpoint_recovery_valid = branch_recovery_valid_q &&
                                branch_recovery_checkpoint_valid_q &&
                                !commit_flush;
    checkpoint_recovery_id = branch_recovery_checkpoint_id_q;
    checkpoint_release_valid = branch_resolve_valid_q &&
                               branch_resolve_checkpoint_valid_q &&
                               !branch_resolve_mispredict_q && !commit_flush;
    checkpoint_release_id = branch_resolve_checkpoint_id_q;

    rob_recovery_valid = commit_flush || branch_recovery_valid_q;
    rob_recovery_tail = commit_flush ? commit_rob_recovery_tail_q
                                     : branch_recovery_tail_q;
    lq_recovery_valid = rob_recovery_valid;
    sq_recovery_valid = rob_recovery_valid;
    lq_recovery_tail = commit_flush
                     ? commit_lq_recovery_tail_q
                     : branch_lq_recovery_tail_q;
    sq_recovery_tail = commit_flush
                     ? commit_sq_recovery_tail_q
                     : branch_sq_recovery_tail_q;
    rename_restore = checkpoint_recovery_valid && checkpoint_recovery_found;
    for (int unsigned r = 0; r < 32; r++) restore_map[r] = checkpoint_recovery_map[r];
    rename_rebuild = commit_flush;
    free_recovery = branch_recovery_valid_q && !commit_flush;
    free_rebuild = commit_flush;

    recovery_free_mask = '0;
    if (branch_recovery_valid_q && !commit_flush) begin
      for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
        if (meta_valid_q[i] &&
            rob_ptr_in_range(meta_rob_ptr_q[i], branch_recovery_tail_q,
                             branch_recovery_end_q)) begin
          if (meta_rd_wen_q[i] && (meta_pdst_q[i] != 0))
            recovery_free_mask[meta_pdst_q[i]] = 1'b1;
        end
      end
    end

    rebuild_free_mask = {PHYS_REGS{1'b1}};
    prf_rebuild_ready_mask = '0;
    for (int unsigned r = 0; r < 32; r++) begin
      preg_t mapped;
      // No global-flush event retires an instruction with an architectural
      // destination in the same cycle.  Folding the live ROB heads into this
      // mask was therefore redundant and created a 32-way commit-to-mask cone.
      mapped = committed_map[r];
      rebuild_free_mask[mapped] = 1'b0;
      prf_rebuild_ready_mask[mapped] = 1'b1;
    end
    rebuild_free_mask[0] = 1'b0;
    prf_rebuild_ready_mask[0] = 1'b1;
  end

  // Data request arbitration.  MMIO stores execute precisely at ROB head;
  // committed cacheable stores drain independently from SQ ownership; loads
  // may pass them only through the SQ byte-forwarding/order contract.
  logic lq_request_order_ok;
  assign sq_drain_ready = !commit_mmio_q_valid && dmem_req_ready_i;
  assign lq_request_ready = !commit_mmio_q_valid && !sq_drain_valid &&
                             lq_request_order_ok && dmem_req_ready_i;

  always_comb begin
    dmem_req_valid_o = 1'b0; dmem_req_write_o = 1'b0; dmem_req_addr_o = '0;
    dmem_req_wdata_o = '0; dmem_req_wstrb_o = '0;
    dmem_req_seq_o = '0; dmem_req_uop_id_o = '0;
    dmem_load_valid_o = 1'b0; dmem_load_addr_o = '0;
    dmem_fast_load_valid_o = 1'b0;
    dmem_fast_load_addr_o = ex1_mem_addr;
    dmem_fast_load_seq_o = ex1_lsu_q.queue_seq;
    dmem_fast_load_uop_id_o = ex1_lsu_q.uop_id;
    dmem_store_valid_o = 1'b0; dmem_store_addr_o = '0;
    lq_request_order_ok = addr_is_ram(lq_request_addr) ||
                           ((uop_rob_ptr(lq_request_uop_id) == rob_head) &&
                            (sq_head == lq_request_older_sq_tail));
    if (commit_mmio_q_valid) begin
      dmem_req_valid_o = 1'b1; dmem_req_write_o = 1'b1;
      dmem_req_addr_o = commit_mmio_q_addr;
      dmem_req_wdata_o = commit_mmio_q_data;
      dmem_req_wstrb_o = commit_mmio_q_mask;
      dmem_store_valid_o = 1'b1;
      dmem_store_addr_o = commit_mmio_q_addr;
    end else if (sq_drain_valid) begin
      dmem_req_valid_o = 1'b1; dmem_req_write_o = 1'b1;
      dmem_req_addr_o = sq_drain_addr;
      dmem_req_wdata_o = sq_drain_data;
      dmem_req_wstrb_o = sq_drain_mask;
      dmem_store_valid_o = 1'b1;
      dmem_store_addr_o = sq_drain_addr;
    end else if (lq_request_valid && lq_request_order_ok) begin
      dmem_req_valid_o = 1'b1; dmem_req_write_o = 1'b0;
      dmem_req_addr_o = lq_request_addr;
      dmem_req_seq_o = lq_request_seq;
      dmem_req_uop_id_o = lq_request_uop_id;
      dmem_load_valid_o = 1'b1;
      dmem_load_addr_o = lq_request_addr;
      dmem_fast_load_valid_o = lq_request_fast;
    end
  end

  // A trained BTB prediction is made at request time and travels through the
  // in-flight metadata FIFO.  Predecode remains the cold-start fallback for
  // direct JALs, whose immediate target is unavailable before I-cache data.
  always_comb begin
    fetch_meta_pred_head = fetch_meta_pred_q[fetch_meta_head_q];
    response_request_pred_taken = fetch_meta_pred_head[66]
      ? fetch_meta_pred_head[65:64] : 2'b00;
    response_request_pred_target[0] = fetch_meta_pred_head[63:32];
    response_request_pred_target[1] = fetch_meta_pred_head[31:0];
    response_pred_taken = response_request_pred_taken;
    response_pred_target[0] = response_request_pred_target[0];
    response_pred_target[1] = response_request_pred_target[1];

    // An earlier direct jump discovered by predecode overrides any lane-1 BTB
    // prediction made before the instruction bytes were known.
    if (response_dec[0].op == UOP_JAL) begin
      response_pred_taken = 2'b01;
      response_pred_target[0] = imem_rsp_addr_i + response_dec[0].imm;
    end else begin
      if ((response_dec[0].op == UOP_JALR) ||
          response_dec[0].is_serializing ||
          (response_dec[0].is_branch && response_pred_taken[0]))
        response_pred_taken[1] = 1'b0;
      if (!imem_rsp_addr_i[2] && !response_pred_taken[0] &&
          (response_dec[0].op != UOP_JALR) &&
          !response_dec[0].is_serializing &&
          (response_dec[1].op == UOP_JAL)) begin
        response_pred_taken[1] = 1'b1;
        response_pred_target[1] = imem_rsp_addr_i + 32'd4 +
                                  response_dec[1].imm;
      end
    end
  end

  assign request_predict_redirect = frontend_predictor_taken[0] ||
    (!frontend_predictor_taken[0] && !imem_req_addr_o[2] &&
     frontend_predictor_taken[1]);
  assign request_predict_target = frontend_predictor_taken[0]
    ? frontend_predictor_target[0] : frontend_predictor_target[1];

  assign decode_predict_redirect = 1'b0;
  assign decode_predict_target = '0;
  assign fetch_response_redirect = imem_rsp_fire && !imem_rsp_stale &&
    !fetch_response_redirect_pending_q &&
    !fetch_queue_flush &&
    ((response_pred_taken != response_request_pred_taken) ||
     (response_pred_taken[0] &&
      (response_pred_target[0] !=
       response_request_pred_target[0])) ||
     (response_pred_taken[1] &&
      (response_pred_target[1] !=
       response_request_pred_target[1])) ||
     ((response_dec[0].op == UOP_JALR) &&
      !response_pred_taken[0] && !imem_rsp_addr_i[2]));
  assign fetch_response_redirect_target = response_pred_taken[0]
    ? response_pred_target[0] : response_pred_taken[1]
    ? response_pred_target[1] : (imem_rsp_addr_i + 32'd4);
  // Serializing operations are held until dispatch/retirement state is known;
  // unlike predicted control they still require a backend-visible flush.
  assign decode_serializing_redirect =
    dispatch_take[0] && dec[0].is_serializing;
  assign redirect_valid = commit_flush ||
                           (branch_recovery_valid_q && !commit_flush) ||
                           decode_predict_redirect ||
                           decode_serializing_redirect;
  // Branch resolution crosses the existing recovery boundary before touching
  // the frontend.  This intentionally adds one recovery cycle, but prevents
  // the EX0 comparator/ALU result from driving the fetch queue, epoch, PC and
  // I-cache address in the same 150 MHz cycle.
  assign fetch_queue_flush = commit_flush || branch_recovery_valid_q ||
                              decode_predict_redirect ||
                              decode_serializing_redirect;
  assign redirect_target = commit_flush ? commit_redirect_target_q :
    branch_recovery_valid_q ? branch_recovery_redirect_target_q :
    decode_predict_redirect ? decode_predict_target :
    (fetch_buffer_pc_q + 32'd4);

  // Credits cover returned packets, requests resident in the I-cache pipeline,
  // and its existing elastic response slot.  The ninth credit preserves the
  // former full-queue pop/replace throughput without using the live dispatch
  // decision as a combinational credit.  The separate inflight limit protects
  // the eight-entry prediction-metadata ring.
  // An aligned recovery may use the request port on the registered recovery
  // cycle.  It is tagged with the next epoch; old responses remain discardable
  // without a combinational EX0-to-I-cache path.
  assign branch_redirect_req = rst_ni && !commit_flush &&
    branch_recovery_valid_q && branch_recovery_fetch_valid_q &&
    !serializing_inflight_q && !interrupt_drain_q &&
    !fetch_response_redirect_pending_q &&
    (fetch_inflight_count_q < 8);
  assign imem_req_valid_o = branch_redirect_req ||
                            (rst_ni && !serializing_inflight_q &&
                             !interrupt_drain_q &&
                             !fetch_queue_flush &&
                             !fetch_response_redirect_pending_q &&
                             (fetch_inflight_count_q < 8) &&
                             ((fetch_queue_count + fetch_inflight_count_q) < 9));
  assign imem_req_addr_o = branch_redirect_req ? redirect_target : fetch_pc_q;
  assign imem_req_epoch_o = branch_redirect_req
                           ? (fetch_epoch_q + 1'b1) : fetch_epoch_q;
  assign imem_req_fire = imem_req_valid_o && imem_req_ready_i;
  assign imem_rsp_stale = (imem_rsp_epoch_i != fetch_epoch_q);
  assign imem_rsp_ready_o = fetch_queue_flush ||
                             fetch_response_redirect_pending_q ||
                             imem_rsp_stale ||
                             fetch_queue_enq_ready;
  assign imem_rsp_fire = imem_rsp_valid_i && imem_rsp_ready_o;
  assign fetch_queue_enq_valid = imem_rsp_valid_i && !imem_rsp_stale &&
                                  !fetch_queue_flush &&
                                  !fetch_response_redirect_pending_q;
  assign fetch_queue_pop = dispatch_take[0] && !fetch_queue_flush &&
                            (dispatch_take[1] || !fetch_lane_valid[1]);
  assign fetch_queue_advance = dispatch_take[0] && !fetch_queue_flush &&
                                !dispatch_take[1] && fetch_lane_valid[1];

  // Retirement metadata follows the same parity-banked shape as the ROB.
  // Allocation-only fields have one write per bank and infer LUTRAM; fields
  // updated by execution remain separately banked registers.
  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      meta_alloc_index[lane] = rob_index(rob_alloc_ptr[lane]);
      meta_alloc_static[lane] = '{
        op: dec[lane].op,
        is_serializing: dec[lane].is_serializing,
        is_branch: dec[lane].is_branch,
        is_load: dec[lane].is_load,
        is_store: dec[lane].is_store,
        lq_seq: lane_issue_entry[lane].lq_seq,
        sq_seq: lane_issue_entry[lane].sq_seq
      };
    end
    meta_static_even_we = 1'b0;
    meta_static_odd_we = 1'b0;
    meta_static_even_addr = '0;
    meta_static_odd_addr = '0;
    meta_static_even_data = '0;
    meta_static_odd_data = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (dispatch_take[lane]) begin
        if (meta_alloc_index[lane][0]) begin
          meta_static_odd_we = 1'b1;
          meta_static_odd_addr = meta_alloc_index[lane][ROB_INDEX_W-1:1];
          meta_static_odd_data = meta_alloc_static[lane];
        end else begin
          meta_static_even_we = 1'b1;
          meta_static_even_addr = meta_alloc_index[lane][ROB_INDEX_W-1:1];
          meta_static_even_data = meta_alloc_static[lane];
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && meta_static_even_we)
      retire_static_even_q[meta_static_even_addr] <= meta_static_even_data;
    if (rst_ni && meta_static_odd_we)
      retire_static_odd_q[meta_static_odd_addr] <= meta_static_odd_data;
  end

  always_comb begin
    retire_next_pc_we = branch_resolve_valid && ex0_live;
    retire_next_pc_bank = ex0_q.rob_ptr[0];
    retire_next_pc_addr = ex0_q.rob_ptr[ROB_INDEX_W-1:1];
    retire_next_pc_data = branch_actual_next;

    retire_ex1_we = 1'b0;
    retire_ex1_bank = ex1_q.rob_ptr[0];
    retire_ex1_addr = ex1_q.rob_ptr[ROB_INDEX_W-1:1];
    retire_ex1_data = '0;
    if (sq_execute_valid) begin
      retire_ex1_we = 1'b1;
      retire_ex1_bank = ex1_lsu_q.rob_ptr[0];
      retire_ex1_addr = ex1_lsu_q.rob_ptr[ROB_INDEX_W-1:1];
      retire_ex1_data.store_addr = sq_execute_addr;
      retire_ex1_data.store_data = sq_execute_data;
      retire_ex1_data.store_mask = sq_execute_mask;
      retire_ex1_data.store_cacheable = addr_is_ram(sq_execute_addr);
      retire_ex1_data.store_mmio = addr_is_mmio(sq_execute_addr);
    end else if (ex1_completion_selected && !ex1_is_lsu_q && ex1_q.is_csr &&
                  !csr_exec_illegal) begin
      retire_ex1_we = 1'b1;
      retire_ex1_data.csr_write = csr_exec_write;
      retire_ex1_data.csr_addr = ex1_q.csr_addr;
      retire_ex1_data.csr_wdata = csr_new_value;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && retire_next_pc_we) begin
      if (retire_next_pc_bank)
        retire_next_pc_odd_q[retire_next_pc_addr] <= retire_next_pc_data;
      else
        retire_next_pc_even_q[retire_next_pc_addr] <= retire_next_pc_data;
    end
    if (rst_ni && retire_ex1_we) begin
      if (retire_ex1_bank)
        retire_ex1_odd_q[retire_ex1_addr] <= retire_ex1_data;
      else
        retire_ex1_even_q[retire_ex1_addr] <= retire_ex1_data;
    end
  end

  // --------------------------------------------------------------------------
  // Sequential state.
  // --------------------------------------------------------------------------
  // Commit and branch recovery cross local control boundaries.  Branch target
  // redirection remains immediate, while all backend cleanup and predictor
  // training payloads are captured atomically here.  Wrong-path work accepted
  // on the detection edge is covered by the registered recovery interval and removed by
  // the following pulse, instead of making EX0 a reset/enable source for the
  // entire backend.
  // MMIO stores use a separate non-speculative one-entry buffer, so accepting
  // the head store remains its precise commit point even if the bus stalls.
  always_ff @(posedge clk_i) begin : commit_boundaries
    if (!rst_ni) begin
      commit_flush <= 1'b0;
      commit_redirect_target_q <= RESET_VECTOR;
      commit_rob_recovery_tail_q <= '0;
      commit_lq_recovery_tail_q <= '0;
      commit_sq_recovery_tail_q <= '0;
      commit_fencei_q <= 1'b0;
      rebuild_free_mask_q <= '0;
      prf_rebuild_ready_mask_q <= '0;
      csr_retire_count_q <= '0;
      csr_commit_write_q <= 1'b0;
      csr_commit_addr_q <= '0;
      csr_commit_data_q <= '0;
      csr_trap_valid_q <= 1'b0;
      csr_trap_pc_q <= '0;
      csr_trap_cause_q <= '0;
      csr_trap_tval_q <= '0;
      csr_mret_q <= 1'b0;
      branch_recovery_valid_q <= 1'b0;
      branch_recovery_tail_q <= '0;
      branch_recovery_end_q <= '0;
      branch_recovery_valid_iq0_q <= 1'b0;
      branch_recovery_tail_iq0_q <= '0;
      branch_recovery_end_iq0_q <= '0;
      branch_recovery_valid_iq1_q <= 1'b0;
      branch_recovery_tail_iq1_q <= '0;
      branch_recovery_end_iq1_q <= '0;
      branch_recovery_valid_exec_q <= 1'b0;
      branch_recovery_tail_exec_q <= '0;
      branch_recovery_end_exec_q <= '0;
      branch_recovery_redirect_target_q <= RESET_VECTOR;
      branch_recovery_fetch_next_q <= RESET_VECTOR;
      branch_recovery_fetch_valid_q <= 1'b0;
      branch_lq_recovery_tail_q <= '0;
      branch_sq_recovery_tail_q <= '0;
      branch_recovery_checkpoint_valid_q <= 1'b0;
      branch_recovery_checkpoint_id_q <= '0;
      branch_resolve_valid_q <= 1'b0;
      branch_resolve_pc_q <= '0;
      branch_resolve_target_q <= '0;
      branch_resolve_actual_taken_q <= 1'b0;
      branch_resolve_is_branch_q <= 1'b0;
      branch_resolve_is_jalr_q <= 1'b0;
      branch_resolve_is_call_q <= 1'b0;
      branch_resolve_is_return_q <= 1'b0;
      branch_resolve_trap_q <= 1'b0;
      branch_resolve_mispredict_q <= 1'b0;
      branch_resolve_checkpoint_valid_q <= 1'b0;
      branch_resolve_checkpoint_id_q <= '0;
      commit_mmio_q_valid <= 1'b0;
      commit_mmio_q_addr <= '0;
      commit_mmio_q_data <= '0;
      commit_mmio_q_mask <= '0;
      commit_free_valid_q <= '0;
      commit_map_valid_q <= '0;
      lq_release_valid_q <= '0;
      sq_commit_valid_q <= 1'b0;
      sq_commit_seq_q <= '0;
      sq_commit_remove_q <= 1'b0;
      predictor_commit_valid_q <= '0;
      predictor_commit_branch_q <= '0;
      predictor_commit_taken_q <= '0;
      predictor_commit_call_q <= '0;
      predictor_commit_return_q <= '0;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        commit_free_preg_q[lane] <= '0;
        commit_map_rd_q[lane] <= '0;
        commit_map_pdst_q[lane] <= '0;
        lq_release_seq_q[lane] <= '0;
        predictor_commit_pc_q[lane] <= '0;
      end
    end else begin
      commit_flush <= commit_flush_request;
      csr_retire_count_q <= retire_count;
      csr_commit_write_q <= csr_commit_write;
      csr_commit_addr_q <= csr_commit_addr;
      csr_commit_data_q <= csr_commit_data;
      csr_trap_valid_q <= csr_trap_valid;
      csr_trap_pc_q <= csr_trap_pc;
      csr_trap_cause_q <= csr_trap_cause;
      csr_trap_tval_q <= csr_trap_tval;
      csr_mret_q <= csr_mret;
      branch_recovery_valid_q <= branch_mispredict && !commit_flush;
      branch_recovery_valid_iq0_q <= branch_mispredict && !commit_flush;
      branch_recovery_valid_iq1_q <= branch_mispredict && !commit_flush;
      branch_recovery_valid_exec_q <= branch_mispredict && !commit_flush;
      branch_resolve_valid_q <= branch_resolve_valid &&
                                (ex0_q.is_branch ||
                                 (ex0_q.op == UOP_JALR));
      commit_free_valid_q <= commit_free_valid;
      commit_map_valid_q <= commit_map_valid;
      lq_release_valid_q <= lq_release_valid;
      sq_commit_valid_q <= sq_commit_valid;
      sq_commit_seq_q <= sq_commit_seq;
      sq_commit_remove_q <= sq_commit_remove;
      predictor_commit_valid_q <= predictor_commit_valid;
      predictor_commit_branch_q <= predictor_commit_branch;
      predictor_commit_taken_q <= predictor_commit_taken;
      predictor_commit_call_q <= predictor_commit_call;
      predictor_commit_return_q <= predictor_commit_return;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        commit_free_preg_q[lane] <= commit_free_preg[lane];
        commit_map_rd_q[lane] <= commit_map_rd[lane];
        commit_map_pdst_q[lane] <= commit_map_pdst[lane];
        lq_release_seq_q[lane] <= lq_release_seq[lane];
        predictor_commit_pc_q[lane] <= predictor_commit_pc[lane];
      end
      if (branch_resolve_valid &&
          (ex0_q.is_branch || (ex0_q.op == UOP_JALR))) begin
        branch_resolve_pc_q <= ex0_q.pc;
        branch_resolve_target_q <= branch_actual_next;
        branch_resolve_actual_taken_q <= ex0_branch_taken;
        branch_resolve_is_branch_q <= ex0_q.is_branch;
        branch_resolve_is_jalr_q <= (ex0_q.op == UOP_JALR);
        branch_resolve_is_call_q <=
          control_is_call(ex0_q.op, ex0_q.inst[11:7]);
        branch_resolve_is_return_q <= control_is_return(
          ex0_q.op, ex0_q.inst[11:7], ex0_q.inst[19:15], ex0_q.imm
        );
        branch_resolve_trap_q <= branch_target_misaligned;
        branch_resolve_mispredict_q <= branch_mispredict;
        branch_resolve_checkpoint_valid_q <= branch_has_checkpoint;
        branch_resolve_checkpoint_id_q <= branch_checkpoint_id;
      end
      if (branch_mispredict && !commit_flush) begin
        branch_recovery_tail_q <= branch_recovery_tail;
        branch_recovery_end_q <= rob_tail + rob_ptr_t'(dispatch_count);
        branch_recovery_tail_iq0_q <= branch_recovery_tail;
        branch_recovery_end_iq0_q <= rob_tail + rob_ptr_t'(dispatch_count);
        branch_recovery_tail_iq1_q <= branch_recovery_tail;
        branch_recovery_end_iq1_q <= rob_tail + rob_ptr_t'(dispatch_count);
        branch_recovery_tail_exec_q <= branch_recovery_tail;
        branch_recovery_end_exec_q <= rob_tail + rob_ptr_t'(dispatch_count);
        branch_recovery_redirect_target_q <= branch_target_misaligned
          ? branch_fallthrough : branch_actual_next;
        branch_recovery_fetch_next_q <= branch_redirect_fetch_next;
        branch_recovery_fetch_valid_q <= !branch_target_misaligned;
        branch_lq_recovery_tail_q <= ex0_q.recovery_lq_tail;
        branch_sq_recovery_tail_q <= ex0_q.recovery_sq_tail;
        branch_recovery_checkpoint_valid_q <= branch_has_checkpoint;
        branch_recovery_checkpoint_id_q <= branch_checkpoint_id;
      end
      if (commit_flush_request) begin
        commit_redirect_target_q <= commit_redirect_target;
        commit_rob_recovery_tail_q <= rob_ptr_add(
          rob_head, {1'b0, (commit_mret || commit_fencei)}
        );
        // A global-flush event never retires a load or store: exceptions and
        // interrupts retire zero, while MRET/FENCE.I are serial uops.  The
        // queue recovery tails are therefore their already-registered heads.
        commit_lq_recovery_tail_q <= lq_head;
        commit_sq_recovery_tail_q <= sq_commit_tail;
        commit_fencei_q <= commit_fencei;
        rebuild_free_mask_q <= rebuild_free_mask;
        prf_rebuild_ready_mask_q <= prf_rebuild_ready_mask;
      end

      if (commit_mmio_q_fire)
        commit_mmio_q_valid <= 1'b0;
      if (commit_mmio_store_fire) begin
        commit_mmio_q_valid <= 1'b1;
        commit_mmio_q_addr <= head_meta[0].store_addr;
        commit_mmio_q_data <= head_meta[0].store_data;
        commit_mmio_q_mask <= head_meta[0].store_mask;
      end
    end
  end

  always_ff @(posedge clk_i) begin : core_state
    if (!rst_ni) begin
      fetch_pc_q <= RESET_VECTOR;
      fetch_epoch_q <= '0;
      fetch_inflight_count_q <= '0;
      fetch_meta_head_q <= '0;
      fetch_meta_tail_q <= '0;
      fetch_response_redirect_pending_q <= 1'b0;
      fetch_response_redirect_target_q <= RESET_VECTOR;
      ex0_q <= '0; ex1_q <= '0; ex0_valid_q <= 1'b0; ex1_valid_q <= 1'b0;
      ex0_rs1_q <= '0; ex0_rs2_q <= '0;
      ex1_rs1_q <= '0; ex1_rs2_q <= '0;
      ex1_lsu_q <= '0;
      ex1_is_lsu_q <= 1'b0;
      ex0_forward_pdst_iq0_q <= '0;
      ex0_forward_pdst_iq1_q <= '0;
      ex1_forward_pdst_iq0_q <= '0;
      ex1_forward_pdst_iq1_q <= '0;
      ex0_forward_class_q <= 1'b0;
      ex1_forward_class_q <= 1'b0;
      route_balance_q <= 1'b0;
      serializing_inflight_q <= 1'b0;
      interrupt_drain_q <= 1'b0;
      next_committed_pc_q <= RESET_VECTOR;
      for (int unsigned i = 0; i < ROB_ENTRIES; i++)
        meta_valid_q[i] <= 1'b0;
    end else begin
      // Once an enabled interrupt is observed, stop admitting younger work and
      // let the existing ROB/queues drain in program order.  The interrupt is
      // then taken at the precise empty-ROB boundary; it cannot be starved by
      // continuous dual issue.  Long-latency owners remain allowed to finish.
      if (take_interrupt || commit_flush)
        interrupt_drain_q <= 1'b0;
      else if (csr_interrupt_pending)
        interrupt_drain_q <= 1'b1;

      if (commit_flush || branch_recovery_valid_q ||
          (retire_lane_valid[0] && head_meta[0].is_serializing) ||
          (retire_lane_valid[1] && head_meta[1].is_serializing))
        serializing_inflight_q <= 1'b0;
      else if ((dispatch_take[0] && dec[0].is_serializing) ||
               (dispatch_take[1] && dec[1].is_serializing))
        serializing_inflight_q <= 1'b1;

      if (dispatch_take[0] && route_is_flexible(dec[0]) &&
          !(dispatch_take[1] && route_is_flexible(dec[1])))
        route_balance_q <= ~route_balance_q;

      if (imem_req_fire) begin
        fetch_pc_q <= (!branch_redirect_req && request_predict_redirect)
                    ? request_predict_target
                    : imem_req_addr_o +
                      (imem_req_addr_o[2] ? 32'd4 : 32'd8);
        fetch_meta_pred_q[fetch_meta_tail_q] <= {
          !branch_redirect_req,
          frontend_predictor_taken,
          frontend_predictor_target[0],
          frontend_predictor_target[1]
        };
        fetch_meta_tail_q <= fetch_meta_tail_q + 1'b1;
      end
      if (imem_rsp_fire)
        fetch_meta_head_q <= fetch_meta_head_q + 1'b1;
      // Capture the predecode target for every usable response.  Whether that
      // target differs from the request-time prediction controls only the
      // pending bit below; it no longer drives the 32 target flops' enables.
      if (imem_rsp_fire && !imem_rsp_stale && !fetch_queue_flush &&
          !fetch_response_redirect_pending_q)
        fetch_response_redirect_target_q <= fetch_response_redirect_target;
      unique case ({imem_req_fire, imem_rsp_fire})
        2'b10: fetch_inflight_count_q <= fetch_inflight_count_q + 1'b1;
        2'b01: fetch_inflight_count_q <= fetch_inflight_count_q - 1'b1;
        default: fetch_inflight_count_q <= fetch_inflight_count_q;
      endcase
      if (redirect_valid) begin
        fetch_epoch_q <= fetch_epoch_q + 1'b1;
        if (branch_redirect_req && imem_req_fire)
          fetch_pc_q <= branch_recovery_fetch_next_q;
        else
          fetch_pc_q <= redirect_target;
        fetch_response_redirect_pending_q <= 1'b0;
        // FENCE.I resets the cache pipeline at this edge; those request credits
        // are cancelled because their responses can no longer arrive.
        if (commit_fencei)
          fetch_inflight_count_q <= '0;
        if (commit_fencei) begin
          fetch_meta_head_q <= '0;
          fetch_meta_tail_q <= '0;
        end
      end else if (fetch_response_redirect_pending_q) begin
        fetch_epoch_q <= fetch_epoch_q + 1'b1;
        fetch_pc_q <= fetch_response_redirect_target_q;
        fetch_response_redirect_pending_q <= 1'b0;
      end else if (fetch_response_redirect) begin
        // Predecode of a returned packet used to drive the request PC and
        // I-cache enable in the same cycle. Capture the correction first;
        // the next edge installs the new epoch/PC while old-epoch responses
        // are consumed and discarded through the pending barrier.
        fetch_response_redirect_pending_q <= 1'b1;
      end

      if (ex0_valid_q) ex0_valid_q <= 1'b0;
      if (ex1_valid_q) begin
        if (ex1_is_lsu_q) begin
          if (ex1_lsu_q.is_load) begin
            if (((ex1_lsu_q.fetch_fault || ex1_load_misaligned) &&
                 ex1_completion_selected) ||
                (!ex1_lsu_q.fetch_fault && !ex1_load_misaligned &&
                 lq_execute_valid))
              ex1_valid_q <= 1'b0;
          end else if (ex1_completion_selected) begin
            ex1_valid_q <= 1'b0;
          end
        end else if (is_div_op(ex1_q.op)) begin
          if (mul_req_valid && mul_req_ready) ex1_valid_q <= 1'b0;
        end else if (is_mul_op(ex1_q.op)) begin
          if (mul_pipe_accept) ex1_valid_q <= 1'b0;
        end else if (ex1_completion_selected) begin
          ex1_valid_q <= 1'b0;
        end
      end
      if (iq0_issue_valid && iq0_issue_ready) begin
        ex0_q <= iq0_issue_entry;
        ex0_rs1_q <= issue_read_data[0];
        ex0_rs2_q <= issue_read_data[1];
        ex0_forward_pdst_iq0_q <= iq0_issue_entry.pdst;
        ex0_forward_pdst_iq1_q <= iq0_issue_entry.pdst;
        ex0_forward_class_q <= iq0_issue_entry.rd_wen;
        ex0_valid_q <= !iq0_issue_recovery_kill;
      end
      if (iq1_issue_valid && iq1_issue_ready) begin
        ex1_is_lsu_q <= iq1_issue_is_lsu;
        if (iq1_issue_is_lsu) begin
          ex1_lsu_q.rob_ptr <= iq1_issue_entry.rob_ptr;
          ex1_lsu_q.uop_id <= iq1_issue_entry.uop_id;
          ex1_lsu_q.pdst <= iq1_issue_entry.pdst;
          ex1_lsu_q.rd_wen <= iq1_issue_entry.rd_wen;
          ex1_lsu_q.is_load <= iq1_issue_entry.is_load;
          ex1_lsu_q.mem_size <= iq1_issue_entry.mem_size;
          ex1_lsu_q.mem_unsigned <= iq1_issue_entry.mem_unsigned;
          ex1_lsu_q.queue_seq <= iq1_issue_entry.is_load
                              ? iq1_issue_entry.lq_seq
                              : iq1_issue_entry.sq_seq;
          ex1_lsu_q.older_sq_tail <= iq1_issue_entry.older_sq_tail;
          ex1_lsu_q.base <= issue_read_data[2];
          ex1_lsu_q.imm12 <= iq1_issue_entry.imm[11:0];
          ex1_lsu_q.store_data_raw <= issue_read_data[3];
          ex1_lsu_q.fetch_fault <= iq1_issue_entry.fetch_fault;
          ex1_lsu_q.pc <= iq1_issue_entry.pc;
        end else begin
          ex1_q <= iq1_issue_entry;
          ex1_rs1_q <= issue_read_data[2];
          ex1_rs2_q <= issue_read_data[3];
          ex1_forward_pdst_iq0_q <= iq1_issue_entry.pdst;
          ex1_forward_pdst_iq1_q <= iq1_issue_entry.pdst;
        end
        ex1_forward_class_q <= !iq1_issue_is_lsu &&
                               iq1_issue_entry.rd_wen &&
                               !is_div_op(iq1_issue_entry.op) &&
                               !is_mul_op(iq1_issue_entry.op);
        ex1_valid_q <= !iq1_issue_recovery_kill;
      end
      if (commit_flush) begin
        ex0_valid_q <= 1'b0;
        ex1_valid_q <= 1'b0;
      end else if (branch_recovery_valid_q) begin
        // A branch recovery only kills work at or after the recovery tail.
        // Clearing an older EX1 entry loses its completion after the IQ has
        // already removed it, leaving a permanent not-done ROB entry.
        if (!(iq0_issue_valid && iq0_issue_ready) &&
            (!ex0_live || ex0_recovery_kill))
          ex0_valid_q <= 1'b0;
        if (!(iq1_issue_valid && iq1_issue_ready) &&
            (!ex1_live || ex1_recovery_kill))
          ex1_valid_q <= 1'b0;
      end

      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (retire_lane_valid[lane])
          meta_valid_q[rob_index(rob_ptr_add(rob_head, lane[1:0]))] <= 1'b0;
      end
      if (commit_flush) begin
        for (int unsigned i = 0; i < ROB_ENTRIES; i++) meta_valid_q[i] <= 1'b0;
      end else if (branch_recovery_valid_q) begin
        for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
          if (meta_valid_q[i] &&
              rob_ptr_in_range(meta_rob_ptr_q[i], branch_recovery_tail_q,
                               branch_recovery_end_q))
            meta_valid_q[i] <= 1'b0;
        end
      end else begin
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (dispatch_take[lane]) begin
            meta_valid_q[meta_alloc_index[lane]] <= 1'b1;
            meta_rob_ptr_q[meta_alloc_index[lane]] <= rob_alloc_ptr[lane];
            meta_uop_id_q[meta_alloc_index[lane]] <= rob_alloc_uop_id[lane];
            meta_pdst_q[meta_alloc_index[lane]] <= rename_alloc_preg[lane];
            meta_rd_wen_q[meta_alloc_index[lane]] <= dec[lane].rd_wen;
            meta_checkpoint_valid_q[meta_alloc_index[lane]] <=
              predictor_dispatch_checkpoint_valid[lane];
            meta_checkpoint_id_q[meta_alloc_index[lane]] <=
              checkpoint_alloc_id[lane];
          end
        end
      end

      if (retire_count != 0) begin
        // An interrupt may be accepted in the empty-ROB cycle immediately
        // after MRET.  In that cycle the architectural next PC is MEPC, not
        // the sequential PC recorded when the MRET uop was dispatched.
        if (commit_mret)
          next_committed_pc_q <= csr_mret_pc;
        else if (retire_count == 2)
          next_committed_pc_q <= head_meta[1].actual_next_pc;
        else
          next_committed_pc_q <= head_meta[0].actual_next_pc;
      end
    end
  end

  assign debug_pc_o = fetch_buffer_valid_q ? fetch_buffer_pc_q : fetch_pc_q;
  assign debug_rob_count_o = rob_count;
  assign icache_flush_o = commit_flush && commit_fencei_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      for (int unsigned r = 1; r < 32; r++) begin
        assert (!free_bits[speculative_map[r]])
          else $fatal(1,
            "RAT x%0d maps free p%0d", r, speculative_map[r]);
        for (int unsigned s = r + 1; s < 32; s++) begin
          assert (speculative_map[r] != speculative_map[s])
            else $fatal(1,
              "RAT aliases x%0d and x%0d to p%0d",
              r, s, speculative_map[r]);
        end
      end
      if (sq_query_valid)
        assert (sq_query_ready)
          else $fatal(1, "issued load reached EX1 before older store data was ready");
      assert (!(dispatch_take[1] && !dispatch_take[0]))
        else $fatal(1, "core dispatched lane1 without lane0");
      assert (!(rob_recovery_valid && (|dispatch_take)))
        else $fatal(1, "core dispatched during recovery");
      assert (!(wb0_valid && wb1_valid && wb0_id == wb1_id))
        else $fatal(1, "completion ports targeted the same uop");
      if (dmem_fast_load_valid_o) begin
        assert (dmem_req_valid_o && dmem_load_valid_o &&
                !dmem_req_write_o &&
                (dmem_fast_load_addr_o == dmem_req_addr_o) &&
                (dmem_fast_load_seq_o == dmem_req_seq_o) &&
                (dmem_fast_load_uop_id_o == dmem_req_uop_id_o))
          else $fatal(1, "EX-local load lane diverged from canonical request");
      end
      assert (fetch_inflight_count_q <= 8)
        else $fatal(1, "fetch request credit count overflowed");
      // Eight prediction-metadata entries plus the I-cache's elastic response
      // slot form nine total frontend credits.  The fetch queue itself never
      // exceeds its independent eight-entry bound.
      assert ((fetch_queue_count + fetch_inflight_count_q) <= 9)
        else $fatal(1, "frontend request/response credits overflowed");
    end
  end
`endif
endmodule
