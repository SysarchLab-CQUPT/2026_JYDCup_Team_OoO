`timescale 1ns/1ps
module branch_predictor (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic [1:0]  query_valid_i,
  input  logic [31:0] query_pc_i [2],
  output logic [1:0]  query_taken_o,
  output logic [31:0] query_target_o [2],
  output logic [1:0]  query_btb_hit_o,
  output logic [10:0] speculative_ghr_o,

  input  logic [1:0]  dispatch_valid_i,
  input  logic [1:0]  dispatch_checkpoint_valid_i,
  input  logic [3:0]  dispatch_checkpoint_id_i [2],
  input  logic [31:0] dispatch_pc_i [2],
  input  logic [1:0]  dispatch_is_branch_i,
  input  logic [1:0]  dispatch_is_call_i,
  input  logic [1:0]  dispatch_is_return_i,
  input  logic [1:0]  dispatch_pred_taken_i,

  input  logic        resolve_valid_i,
  input  logic [31:0] resolve_pc_i,
  input  logic [31:0] resolve_target_i,
  input  logic        resolve_actual_taken_i,
  input  logic        resolve_is_branch_i,
  input  logic        resolve_is_jalr_i,
  input  logic        resolve_is_call_i,
  input  logic        resolve_is_return_i,
  input  logic        resolve_trap_i,
  input  logic        resolve_mispredict_i,
  input  logic        resolve_checkpoint_valid_i,
  input  logic [3:0]  resolve_checkpoint_id_i,
  input  logic        release_valid_i,
  input  logic [3:0]  release_checkpoint_id_i,

  input  logic [1:0]  commit_valid_i,
  input  logic [31:0] commit_pc_i [2],
  input  logic [1:0]  commit_is_branch_i,
  input  logic [1:0]  commit_actual_taken_i,
  input  logic [1:0]  commit_is_call_i,
  input  logic [1:0]  commit_is_return_i,
  input  logic        global_flush_i,
  input  logic        invalidate_i
);
  localparam int unsigned BTB_SETS = 128;
  localparam int unsigned BTB_PAYLOAD_W = 57;
  localparam int unsigned PHT_ENTRIES = 2048;
  localparam int unsigned RAS_ENTRIES = 8;
  localparam int unsigned RAS_PTR_W = $clog2(RAS_ENTRIES);
  localparam int unsigned RAS_COUNT_W = $clog2(RAS_ENTRIES + 1);
  // The architectural checkpoint pool has eight total entries split across
  // two write banks.  Four rows per bank match that capacity; eight rows in
  // each bank duplicated half of every 275-bit history/RAS snapshot.
  localparam int unsigned SNAPSHOT_BANK_ENTRIES = 4;
  localparam logic [RAS_COUNT_W-1:0] RAS_FULL_COUNT =
    RAS_COUNT_W'(RAS_ENTRIES);

  typedef struct packed {
    logic [10:0]                    ghr;
    logic [RAS_PTR_W-1:0]           ras_sp;
    logic [RAS_COUNT_W-1:0]         ras_count;
    logic [RAS_ENTRIES*32-1:0]      ras;
  } checkpoint_snapshot_t;
  localparam int unsigned SNAPSHOT_W = $bits(checkpoint_snapshot_t);

  logic btb_valid_q [2][BTB_SETS];
  // The payload has no architectural reset requirement: btb_valid_q guards
  // every read.  Keeping it out of reset lets Vivado implement each way as a
  // replicated 2R/1W LUTRAM instead of 14,080 resettable flip-flops and their
  // write-enable mux network.
  (* ram_style = "distributed" *)
  logic [BTB_PAYLOAD_W-1:0] btb_payload_way0_q [BTB_SETS];
  (* ram_style = "distributed" *)
  logic [BTB_PAYLOAD_W-1:0] btb_payload_way1_q [BTB_SETS];
  logic btb_lru_q [BTB_SETS];
  (* ram_style = "distributed" *) logic [1:0] pht_q [PHT_ENTRIES];

  logic [10:0] spec_ghr_q, committed_ghr_q;
  logic [31:0] spec_ras_q [RAS_ENTRIES];
  logic [31:0] committed_ras_q [RAS_ENTRIES];
  logic [RAS_PTR_W-1:0] spec_ras_sp_q, committed_ras_sp_q;
  logic [RAS_COUNT_W-1:0] spec_ras_count_q, committed_ras_count_q;
  logic [RAS_PTR_W-1:0] committed_ras_sp_after [2];
  logic [RAS_COUNT_W-1:0] committed_ras_count_after [2];

  logic snapshot_valid_bank0_q [SNAPSHOT_BANK_ENTRIES];
  logic snapshot_valid_bank1_q [SNAPSHOT_BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [SNAPSHOT_W-1:0] snapshot_bank0_q [SNAPSHOT_BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [SNAPSHOT_W-1:0] snapshot_bank1_q [SNAPSHOT_BANK_ENTRIES];
  logic snapshot_bank0_we, snapshot_bank1_we;
  logic [1:0] snapshot_bank0_waddr, snapshot_bank1_waddr;
  checkpoint_snapshot_t snapshot_bank0_wdata, snapshot_bank1_wdata;
  checkpoint_snapshot_t dispatch_snapshot [2];
  checkpoint_snapshot_t resolve_snapshot_bank0, resolve_snapshot_bank1;
  checkpoint_snapshot_t resolve_snapshot;
  logic resolve_snapshot_valid;
  logic [10:0] dispatch_next_ghr;
  // Dispatch first enters a narrow local event register.  Updating all RAS
  // words directly from the core's resource/rename decision produced hundreds
  // of cross-hierarchy setup paths.  The event pipe accepts one dual-lane
  // dispatch per cycle, so this is a control retiming boundary rather than a
  // throughput restriction.
  logic [1:0] predictor_dispatch_valid_q;
  logic [1:0] predictor_dispatch_checkpoint_valid_q;
  logic [3:0] predictor_dispatch_checkpoint_id_q [2];
  logic [31:0] predictor_dispatch_pc_q [2];
  logic [1:0] predictor_dispatch_is_branch_q;
  logic [1:0] predictor_dispatch_is_call_q;
  logic [1:0] predictor_dispatch_is_return_q;
  logic [1:0] predictor_dispatch_pred_taken_q;

  logic btb_train_valid_d;
  (* max_fanout = 32 *) logic btb_train_valid_q;
  logic btb_train_way_d;
  (* max_fanout = 32 *) logic btb_train_way_q;
  logic [6:0] btb_train_set_d;
  (* max_fanout = 32 *) logic [6:0] btb_train_set_q;
  logic [BTB_PAYLOAD_W-1:0] btb_train_payload_d, btb_train_payload_q;
  logic pht_train_valid_d, pht_train_valid_q;
  logic [10:0] pht_train_index_d;
  (* max_fanout = 32 *) logic [10:0] pht_train_index_q;
  logic pht_train_taken_d, pht_train_taken_q;

  logic [6:0] query_set [2];
  logic [10:0] query_pht_index [2];
  logic query_hit_way [2];

  typedef enum logic [1:0] {
    BTB_BRANCH, BTB_JALR, BTB_RETURN
  } btb_kind_e;

  initial begin
    for (int unsigned i = 0; i < PHT_ENTRIES; i++) pht_q[i] = 2'b01;
  end

  always_comb begin
    query_taken_o = '0;
    query_btb_hit_o = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      logic hit0, hit1;
      query_set[lane] = query_pc_i[lane][8:2];
      hit0 = btb_valid_q[0][query_set[lane]] &&
             (btb_payload_way0_q[query_set[lane]][56:34] ==
              query_pc_i[lane][31:9]);
      hit1 = btb_valid_q[1][query_set[lane]] &&
             (btb_payload_way1_q[query_set[lane]][56:34] ==
              query_pc_i[lane][31:9]);
      query_btb_hit_o[lane] = hit0 || hit1;
      query_hit_way[lane] = hit1;
      query_pht_index[lane] = query_pc_i[lane][12:2];
      query_target_o[lane] = query_hit_way[lane]
                           ? btb_payload_way1_q[query_set[lane]][31:0]
                           : btb_payload_way0_q[query_set[lane]][31:0];
      if (query_valid_i[lane] && query_btb_hit_o[lane]) begin
        btb_kind_e hit_kind;
        hit_kind = btb_kind_e'(query_hit_way[lane]
          ? btb_payload_way1_q[query_set[lane]][33:32]
          : btb_payload_way0_q[query_set[lane]][33:32]);
        unique case (hit_kind)
          BTB_BRANCH: query_taken_o[lane] =
            pht_q[query_pht_index[lane]][1];
          BTB_RETURN: begin
            query_taken_o[lane] = 1'b1;
            if (spec_ras_count_q != 0)
              query_target_o[lane] = spec_ras_q[spec_ras_sp_q - 1'b1];
          end
          default: query_taken_o[lane] = 1'b1;
        endcase
      end
    end
  end

  assign speculative_ghr_o = spec_ghr_q;

  // Fold both retirement lanes into the architectural RAS in program order.
  // A return and the next target's call can retire together even though they
  // were dispatched in different cycles.  Treating the lanes as an else-if
  // pair silently dropped lane 1 and made an interrupt flush restore a stale
  // caller address.
  always_comb begin : build_committed_ras_state
    committed_ras_sp_after[0] = committed_ras_sp_q;
    committed_ras_count_after[0] = committed_ras_count_q;
    if (commit_valid_i[0] && commit_is_call_i[0]) begin
      committed_ras_sp_after[0] = committed_ras_sp_q + 1'b1;
      if (committed_ras_count_q != RAS_FULL_COUNT)
        committed_ras_count_after[0] = committed_ras_count_q + 1'b1;
    end else if (commit_valid_i[0] && commit_is_return_i[0] &&
                 (committed_ras_count_q != 0)) begin
      committed_ras_sp_after[0] = committed_ras_sp_q - 1'b1;
      committed_ras_count_after[0] = committed_ras_count_q - 1'b1;
    end

    committed_ras_sp_after[1] = committed_ras_sp_after[0];
    committed_ras_count_after[1] = committed_ras_count_after[0];
    if (commit_valid_i[1] && commit_is_call_i[1]) begin
      committed_ras_sp_after[1] = committed_ras_sp_after[0] + 1'b1;
      if (committed_ras_count_after[0] != RAS_FULL_COUNT)
        committed_ras_count_after[1] = committed_ras_count_after[0] + 1'b1;
    end else if (commit_valid_i[1] && commit_is_return_i[1] &&
                 (committed_ras_count_after[0] != 0)) begin
      committed_ras_sp_after[1] = committed_ras_sp_after[0] - 1'b1;
      committed_ras_count_after[1] = committed_ras_count_after[0] - 1'b1;
    end
  end

  // Resolve-side predictor training crosses a local one-cycle boundary.  The
  // old direct EX0-PC to thousands of replicated LUTRAM write-address pins was
  // a large zero-logic hold family.  Local registered address/data records let
  // placement replicate them beside the BTB/PHT without detouring the EX path.
  always_comb begin : build_training_record
    logic hit0, hit1, valid0, valid1, effective_lru;
    logic [BTB_PAYLOAD_W-1:0] payload0, payload1;

    btb_train_valid_d = resolve_valid_i && !resolve_trap_i &&
                        (resolve_is_branch_i || resolve_is_jalr_i);
    btb_train_set_d = resolve_pc_i[8:2];
    btb_train_payload_d = {
      resolve_pc_i[31:9],
      resolve_is_return_i ? BTB_RETURN :
      resolve_is_jalr_i ? BTB_JALR : BTB_BRANCH,
      resolve_target_i
    };

    valid0 = btb_valid_q[0][btb_train_set_d];
    valid1 = btb_valid_q[1][btb_train_set_d];
    payload0 = btb_payload_way0_q[btb_train_set_d];
    payload1 = btb_payload_way1_q[btb_train_set_d];
    effective_lru = btb_lru_q[btb_train_set_d];
    // Make a back-to-back update observe the record being committed this edge.
    if (btb_train_valid_q && !invalidate_i &&
        (btb_train_set_q == btb_train_set_d)) begin
      effective_lru = ~btb_train_way_q;
      if (btb_train_way_q) begin
        valid1 = 1'b1;
        payload1 = btb_train_payload_q;
      end else begin
        valid0 = 1'b1;
        payload0 = btb_train_payload_q;
      end
    end
    hit0 = valid0 && (payload0[56:34] == resolve_pc_i[31:9]);
    hit1 = valid1 && (payload1[56:34] == resolve_pc_i[31:9]);
    btb_train_way_d = hit1 ? 1'b1 : hit0 ? 1'b0 :
                      !valid0 ? 1'b0 : !valid1 ? 1'b1 : effective_lru;

    pht_train_valid_d = resolve_valid_i && !resolve_trap_i &&
                        resolve_is_branch_i;
    pht_train_index_d = resolve_pc_i[12:2];
    pht_train_taken_d = resolve_actual_taken_i;
  end

  // The allocator guarantees at most one new checkpoint in each bank.  The
  // dispatch event has already crossed the local predictor register above, so
  // this write may go directly to LUTRAM without the former redundant pending
  // stage.  Snapshot visibility remains one cycle after core dispatch.
  always_comb begin
    snapshot_bank0_we = 1'b0;
    snapshot_bank1_we = 1'b0;
    snapshot_bank0_waddr = '0;
    snapshot_bank1_waddr = '0;
    snapshot_bank0_wdata = '0;
    snapshot_bank1_wdata = '0;
    dispatch_next_ghr = spec_ghr_q;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      dispatch_snapshot[lane] = '0;
      dispatch_snapshot[lane].ghr = dispatch_next_ghr;
      dispatch_snapshot[lane].ras_sp = spec_ras_sp_q;
      dispatch_snapshot[lane].ras_count = spec_ras_count_q;
      for (int unsigned r = 0; r < RAS_ENTRIES; r++)
        dispatch_snapshot[lane].ras[r*32 +: 32] = spec_ras_q[r];
      if (!global_flush_i && !resolve_mispredict_i &&
          predictor_dispatch_valid_q[lane] &&
          predictor_dispatch_checkpoint_valid_q[lane]) begin
        if (predictor_dispatch_checkpoint_id_q[lane][3]) begin
          snapshot_bank1_we = 1'b1;
          snapshot_bank1_waddr =
            predictor_dispatch_checkpoint_id_q[lane][1:0];
        end else begin
          snapshot_bank0_we = 1'b1;
          snapshot_bank0_waddr =
            predictor_dispatch_checkpoint_id_q[lane][1:0];
        end
      end
      if (predictor_dispatch_valid_q[lane] &&
          predictor_dispatch_is_branch_q[lane])
        dispatch_next_ghr = {dispatch_next_ghr[9:0],
                              predictor_dispatch_pred_taken_q[lane]};
    end

    // Dual allocation always assigns lane 0/1 to opposite banks.  With only
    // lane 1 checkpointed, lane 0 cannot be a conditional branch, so both GHR
    // snapshots are identical.  This lets payload selection depend only on
    // the narrow checkpoint-id bank bit, never on the long dispatch-valid
    // cone that controls the write pipeline valid/address.
    snapshot_bank0_wdata = predictor_dispatch_checkpoint_id_q[0][3]
                         ? dispatch_snapshot[1] : dispatch_snapshot[0];
    snapshot_bank1_wdata = predictor_dispatch_checkpoint_id_q[0][3]
                         ? dispatch_snapshot[0] : dispatch_snapshot[1];

    resolve_snapshot_bank0 = checkpoint_snapshot_t'(
      snapshot_bank0_q[resolve_checkpoint_id_i[1:0]]
    );
    resolve_snapshot_bank1 = checkpoint_snapshot_t'(
      snapshot_bank1_q[resolve_checkpoint_id_i[1:0]]
    );
    resolve_snapshot = resolve_checkpoint_id_i[3]
                     ? resolve_snapshot_bank1 : resolve_snapshot_bank0;
    resolve_snapshot_valid = resolve_checkpoint_id_i[3]
      ? snapshot_valid_bank1_q[resolve_checkpoint_id_i[1:0]]
      : snapshot_valid_bank0_q[resolve_checkpoint_id_i[1:0]];
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      predictor_dispatch_valid_q <= '0;
      predictor_dispatch_checkpoint_valid_q <= '0;
      predictor_dispatch_is_branch_q <= '0;
      predictor_dispatch_is_call_q <= '0;
      predictor_dispatch_is_return_q <= '0;
      predictor_dispatch_pred_taken_q <= '0;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        predictor_dispatch_checkpoint_id_q[lane] <= '0;
        predictor_dispatch_pc_q[lane] <= '0;
      end
    end else begin
      predictor_dispatch_valid_q <=
        (global_flush_i || resolve_mispredict_i) ? '0 : dispatch_valid_i;
      predictor_dispatch_checkpoint_valid_q <= dispatch_checkpoint_valid_i;
      predictor_dispatch_is_branch_q <= dispatch_is_branch_i;
      predictor_dispatch_is_call_q <= dispatch_is_call_i;
      predictor_dispatch_is_return_q <= dispatch_is_return_i;
      predictor_dispatch_pred_taken_q <= dispatch_pred_taken_i;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        predictor_dispatch_checkpoint_id_q[lane] <=
          dispatch_checkpoint_id_i[lane];
        predictor_dispatch_pc_q[lane] <= dispatch_pc_i[lane];
      end
      if (snapshot_bank0_we)
        snapshot_bank0_q[snapshot_bank0_waddr] <= snapshot_bank0_wdata;
      if (snapshot_bank1_we)
        snapshot_bank1_q[snapshot_bank1_waddr] <= snapshot_bank1_wdata;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      btb_train_valid_q <= 1'b0;
      btb_train_way_q <= 1'b0;
      btb_train_set_q <= '0;
      btb_train_payload_q <= '0;
      pht_train_valid_q <= 1'b0;
      pht_train_index_q <= '0;
      pht_train_taken_q <= 1'b0;
      spec_ghr_q <= '0;
      committed_ghr_q <= '0;
      spec_ras_sp_q <= '0;
      committed_ras_sp_q <= '0;
      spec_ras_count_q <= '0;
      committed_ras_count_q <= '0;
      for (int unsigned way = 0; way < 2; way++) begin
        for (int unsigned set_idx = 0; set_idx < BTB_SETS; set_idx++) begin
          btb_valid_q[way][set_idx] <= 1'b0;
        end
      end
      for (int unsigned set_idx = 0; set_idx < BTB_SETS; set_idx++)
        btb_lru_q[set_idx] <= 1'b0;
      for (int unsigned i = 0; i < SNAPSHOT_BANK_ENTRIES; i++) begin
        snapshot_valid_bank0_q[i] <= 1'b0;
        snapshot_valid_bank1_q[i] <= 1'b0;
      end
    end else begin
      btb_train_valid_q <= btb_train_valid_d && !invalidate_i;
      if (btb_train_valid_d && !invalidate_i) begin
        btb_train_way_q <= btb_train_way_d;
        btb_train_set_q <= btb_train_set_d;
        btb_train_payload_q <= btb_train_payload_d;
      end
      pht_train_valid_q <= pht_train_valid_d;
      if (pht_train_valid_d) begin
        pht_train_index_q <= pht_train_index_d;
        pht_train_taken_q <= pht_train_taken_d;
      end

      if (btb_train_valid_q && !invalidate_i) begin
        btb_valid_q[btb_train_way_q][btb_train_set_q] <= 1'b1;
        if (btb_train_way_q)
          btb_payload_way1_q[btb_train_set_q] <= btb_train_payload_q;
        else
          btb_payload_way0_q[btb_train_set_q] <= btb_train_payload_q;
        btb_lru_q[btb_train_set_q] <= ~btb_train_way_q;
      end
      if (pht_train_valid_q) begin
        if (pht_train_taken_q) begin
          if (pht_q[pht_train_index_q] != 2'b11)
            pht_q[pht_train_index_q] <= pht_q[pht_train_index_q] + 1'b1;
        end else begin
          if (pht_q[pht_train_index_q] != 2'b00)
            pht_q[pht_train_index_q] <= pht_q[pht_train_index_q] - 1'b1;
        end
      end
      if (invalidate_i) begin
        btb_train_valid_q <= 1'b0;
        for (int unsigned way = 0; way < 2; way++)
          for (int unsigned set_idx = 0; set_idx < BTB_SETS; set_idx++)
            btb_valid_q[way][set_idx] <= 1'b0;
      end

      if (release_valid_i) begin
        if (release_checkpoint_id_i[3])
          snapshot_valid_bank1_q[release_checkpoint_id_i[1:0]] <= 1'b0;
        else
          snapshot_valid_bank0_q[release_checkpoint_id_i[1:0]] <= 1'b0;
      end

      // Architectural history advances only in retirement order.
      begin
        logic [10:0] next_committed_ghr;
        next_committed_ghr = committed_ghr_q;
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (commit_valid_i[lane] && commit_is_branch_i[lane])
            next_committed_ghr = {next_committed_ghr[9:0],
                                  commit_actual_taken_i[lane]};
        end
        committed_ghr_q <= next_committed_ghr;
      end
      if (commit_valid_i[0] && commit_is_call_i[0]) begin
        committed_ras_q[committed_ras_sp_q] <= commit_pc_i[0] + 32'd4;
      end
      if (commit_valid_i[1] && commit_is_call_i[1])
        committed_ras_q[committed_ras_sp_after[0]] <= commit_pc_i[1] + 32'd4;
      committed_ras_sp_q <= committed_ras_sp_after[1];
      committed_ras_count_q <= committed_ras_count_after[1];

      if (global_flush_i) begin
        spec_ghr_q <= committed_ghr_q;
        spec_ras_sp_q <= committed_ras_sp_after[1];
        spec_ras_count_q <= committed_ras_count_after[1];
        for (int unsigned r = 0; r < RAS_ENTRIES; r++)
          spec_ras_q[r] <= committed_ras_q[r];
        if (commit_valid_i[0] && commit_is_call_i[0])
          spec_ras_q[committed_ras_sp_q] <= commit_pc_i[0] + 32'd4;
        if (commit_valid_i[1] && commit_is_call_i[1])
          spec_ras_q[committed_ras_sp_after[0]] <= commit_pc_i[1] + 32'd4;
        for (int unsigned i = 0; i < SNAPSHOT_BANK_ENTRIES; i++) begin
          snapshot_valid_bank0_q[i] <= 1'b0;
          snapshot_valid_bank1_q[i] <= 1'b0;
        end
      end else if (resolve_mispredict_i && resolve_checkpoint_valid_i &&
                   resolve_snapshot_valid) begin
        spec_ghr_q <= resolve_snapshot.ghr;
        if (resolve_is_branch_i && !resolve_trap_i)
          spec_ghr_q <= {resolve_snapshot.ghr[9:0],
                         resolve_actual_taken_i};
        spec_ras_sp_q <= resolve_snapshot.ras_sp;
        spec_ras_count_q <= resolve_snapshot.ras_count;
        for (int unsigned r = 0; r < RAS_ENTRIES; r++)
          spec_ras_q[r] <= resolve_snapshot.ras[r*32 +: 32];
        if (resolve_is_call_i && !resolve_trap_i) begin
          spec_ras_q[resolve_snapshot.ras_sp] <=
            resolve_pc_i + 32'd4;
          spec_ras_sp_q <= resolve_snapshot.ras_sp + 1'b1;
          if (resolve_snapshot.ras_count != RAS_FULL_COUNT)
            spec_ras_count_q <= resolve_snapshot.ras_count + 1'b1;
        end else if (resolve_is_return_i && !resolve_trap_i &&
                     (resolve_snapshot.ras_count != 0)) begin
          spec_ras_sp_q <= resolve_snapshot.ras_sp - 1'b1;
          spec_ras_count_q <= resolve_snapshot.ras_count - 1'b1;
        end
        if (resolve_checkpoint_id_i[3])
          snapshot_valid_bank1_q[resolve_checkpoint_id_i[1:0]] <= 1'b0;
        else
          snapshot_valid_bank0_q[resolve_checkpoint_id_i[1:0]] <= 1'b0;
      end else begin
        if (snapshot_bank0_we)
          snapshot_valid_bank0_q[snapshot_bank0_waddr] <= 1'b1;
        if (snapshot_bank1_we)
          snapshot_valid_bank1_q[snapshot_bank1_waddr] <= 1'b1;
        spec_ghr_q <= dispatch_next_ghr;
        if (predictor_dispatch_valid_q[0] &&
            predictor_dispatch_is_call_q[0]) begin
          spec_ras_q[spec_ras_sp_q] <= predictor_dispatch_pc_q[0] + 32'd4;
          spec_ras_sp_q <= spec_ras_sp_q + 1'b1;
          if (spec_ras_count_q != RAS_FULL_COUNT)
            spec_ras_count_q <= spec_ras_count_q + 1'b1;
        end else if (predictor_dispatch_valid_q[0] &&
                    predictor_dispatch_is_return_q[0] &&
                    (spec_ras_count_q != 0)) begin
          spec_ras_sp_q <= spec_ras_sp_q - 1'b1;
          spec_ras_count_q <= spec_ras_count_q - 1'b1;
        end else if (predictor_dispatch_valid_q[1] &&
                    predictor_dispatch_is_call_q[1]) begin
          spec_ras_q[spec_ras_sp_q] <= predictor_dispatch_pc_q[1] + 32'd4;
          spec_ras_sp_q <= spec_ras_sp_q + 1'b1;
          if (spec_ras_count_q != RAS_FULL_COUNT)
            spec_ras_count_q <= spec_ras_count_q + 1'b1;
        end else if (predictor_dispatch_valid_q[1] &&
                    predictor_dispatch_is_return_q[1] &&
                    (spec_ras_count_q != 0)) begin
          spec_ras_sp_q <= spec_ras_sp_q - 1'b1;
          spec_ras_count_q <= spec_ras_count_q - 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  // A checkpoint snapshot is committed after the local dispatch-event and
  // LUTRAM-write boundaries.  The IQ/EX and registered resolve boundaries
  // still guarantee that resolution cannot overtake that write.
  always_ff @(posedge clk_i) begin
    if (rst_ni && resolve_valid_i && resolve_checkpoint_valid_i) begin
      assert (!(resolve_checkpoint_id_i[3]
                ? (snapshot_bank1_we &&
                   (snapshot_bank1_waddr == resolve_checkpoint_id_i[1:0]))
                : (snapshot_bank0_we &&
                   (snapshot_bank0_waddr == resolve_checkpoint_id_i[1:0]))))
        else $fatal(1, "branch resolution overtook checkpoint snapshot write");
    end
  end
`endif
endmodule
