`timescale 1ns/1ps
module data_cache #(
  parameter int unsigned SETS = 128,
  parameter int unsigned LINE_BYTES = 32
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        core_load_valid_i,
  input  logic [31:0] core_load_addr_i,
  input  logic        core_store_valid_i,
  input  logic [31:0] core_store_addr_i,
  output logic        core_req_ready_o,
  output logic        core_load_ready_o,
  output logic        core_store_ready_o,
  input  logic [31:0] core_req_wdata_i,
  input  logic [3:0]  core_req_wstrb_i,
  input  logic [3:0]  core_req_seq_i,
  input  logic [7:0]  core_req_uop_id_i,
  output logic        core_rsp_valid_o,
  output logic [31:0] core_rsp_data_o,
  output logic        core_rsp_error_o,
  output logic [3:0]  core_rsp_seq_o,
  output logic [7:0]  core_rsp_uop_id_o,
  output logic        idle_o,
  input  logic        clean_req_i,
  output logic        clean_done_o,

  output logic        mem_req_valid_o,
  input  logic        mem_req_ready_i,
  output logic        mem_req_write_o,
  output logic [31:0] mem_req_addr_o,
  output logic [63:0] mem_req_wdata_o,
  output logic [7:0]  mem_req_wstrb_o,
  input  logic        mem_rsp_valid_i,
  input  logic [63:0] mem_rsp_data_i,
  input  logic        mem_rsp_error_i
);
  localparam int unsigned INDEX_W = $clog2(SETS);
  localparam int unsigned OFFSET_W = $clog2(LINE_BYTES);
  localparam int unsigned TAG_W = 32 - INDEX_W - OFFSET_W;
  localparam int unsigned BEATS_PER_LINE = LINE_BYTES / 8;
  localparam int unsigned DATA_DEPTH = SETS * BEATS_PER_LINE;
  localparam logic [INDEX_W-1:0] LAST_SET = INDEX_W'(SETS - 1);

  typedef enum logic {MS_WAIT, MS_RESP} mshr_state_e;
  typedef enum logic [3:0] {
    E_IDLE, E_WB_READ, E_WB_CAPTURE, E_WB_REQ,
    E_REFILL_REQ, E_REFILL_WAIT, E_INSTALL
  } engine_state_e;
  typedef enum logic [1:0] {C_SCAN, C_READ, C_CAPTURE, C_REQ} clean_state_e;

  typedef struct packed {
    logic        valid;
    logic [31:0] addr;
    logic [3:0]  seq;
    logic [7:0]  uop_id;
  } waiter_t;

  // The tag has one install writer and three simultaneous asynchronous
  // consumers.  Keep a replica per concurrent consumer so Vivado can infer
  // LUTRAM instead of resettable set-wide flip-flop mux trees.  Cache cleaning
  // is mutually exclusive with normal requests and therefore reuses the input
  // replica rather than consuming a fourth physical copy.  valid_q is the
  // architectural reset guard.
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_input_way0_q [SETS];
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_input_way1_q [SETS];
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_load_way0_q [SETS];
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_load_way1_q [SETS];
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_lookup_way0_q [SETS];
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_lookup_way1_q [SETS];
  logic valid_q [2][SETS];
  logic dirty_q [2][SETS];
  logic lru_q [SETS];

  logic lookup_valid_q;
  logic lookup_data_ready_q;
  logic [31:0] lookup_addr_q;
  logic [3:0] lookup_seq_q;
  logic [7:0] lookup_uop_id_q;
  logic data_cpu_en;
  logic [7:0] data_way0_cpu_we, data_way1_cpu_we;
  logic [$clog2(DATA_DEPTH)-1:0] data_cpu_addr;
  logic [63:0] data_cpu_wdata;
  logic [63:0] data_way0_cpu_rdata, data_way1_cpu_rdata;
  logic data_maint_en;
  logic [7:0] data_way0_maint_we, data_way1_maint_we;
  logic [$clog2(DATA_DEPTH)-1:0] data_maint_addr;
  logic [63:0] data_maint_wdata;
  logic [63:0] data_way0_maint_rdata, data_way1_maint_rdata;

  logic mshr_valid_q [2];
  mshr_state_e mshr_state_q [2];
  logic [31:0] mshr_line_addr_q [2];
  logic [INDEX_W-1:0] mshr_set_q [2];
  logic [TAG_W-1:0] mshr_tag_q [2];
  logic mshr_victim_way_q [2];
  logic mshr_victim_valid_q [2];
  logic mshr_victim_dirty_q [2];
  logic [TAG_W-1:0] mshr_victim_tag_q [2];
  logic [255:0] mshr_store_data_q [2];
  logic [31:0] mshr_store_mask_q [2];
  logic [63:0] mshr_line_data_q [2][BEATS_PER_LINE];
  logic mshr_error_q [2];
  waiter_t mshr_waiter_q [2][2];

  engine_state_e engine_state_q;
  logic engine_active_q;
  logic engine_mshr_q;
  logic [1:0] engine_beat_q;
  logic [63:0] maint_data_q;

  logic clean_active_q, clean_done_q;
  clean_state_e clean_state_q;
  logic [INDEX_W-1:0] clean_set_q;
  logic clean_way_q;
  logic [1:0] clean_beat_q;
  logic [63:0] clean_data_q;

  logic rsp_valid_q, rsp_error_q;
  logic [31:0] rsp_data_q;
  logic [3:0] rsp_seq_q;
  logic [7:0] rsp_uop_id_q;

  logic [INDEX_W-1:0] store_index, load_index, lookup_index;
  logic [TAG_W-1:0] store_tag, load_tag, lookup_tag;
  logic [31:0] store_line_addr, lookup_line_addr;
  logic input_install_conflict, lookup_install_conflict;
  logic store_hit0, store_hit1, load_hit0, load_hit1;
  logic lookup_hit0, lookup_hit1;
  logic lookup_hit0_q, lookup_hit1_q;
  logic lookup_repl_way_q;
  logic store_hit;
  logic store_hit_way;
  logic [7:0] store_wstrb64;
  logic [63:0] store_wdata64;
  logic store_match_found, store_match_idx;
  logic store_set_locked;
  logic store_merge_allowed;
  logic store_free_found, store_free_idx;
  logic store_can_accept;
  logic store_hit_write_fire;
  logic data_cpu_spec_load, data_cpu_replay, data_cpu_read_request;
  logic data_cpu_write_conflict;
  logic data_maint_busy;
  logic store_blocks_load;
  logic store_lookup_word_conflict;
  logic store_exec_ready;

  logic lookup_match_found, lookup_match_idx;
  logic lookup_set_locked;
  logic lookup_merge_allowed;
  logic lookup_free_found, lookup_free_idx;
  logic lookup_waiter_free, lookup_waiter_idx;
  logic lookup_victim_way;
  logic lookup_can_advance, lookup_hit_response, core_load_accept;

  logic response_mshr_found, response_mshr_idx;
  logic response_waiter_found, response_waiter_idx;
  logic [63:0] response_line_word;
  logic [63:0] install_merged_data;
  logic [31:0] victim_line_addr;

  function automatic logic [63:0] overlay_beat(
    input logic [63:0] raw,
    input logic [255:0] overlay_data,
    input logic [31:0] overlay_mask,
    input logic [1:0] beat
  );
    logic [63:0] merged;
    int unsigned line_byte;
    merged = raw;
    for (int unsigned byte_idx = 0; byte_idx < 8; byte_idx++) begin
      line_byte = beat * 8 + byte_idx;
      if (overlay_mask[line_byte])
        merged[byte_idx*8 +: 8] = overlay_data[line_byte*8 +: 8];
    end
    return merged;
  endfunction

  assign store_index = core_store_addr_i[OFFSET_W + INDEX_W - 1:OFFSET_W];
  assign store_tag = core_store_addr_i[31:OFFSET_W + INDEX_W];
  assign store_line_addr = {core_store_addr_i[31:OFFSET_W],
                            {OFFSET_W{1'b0}}};
  assign load_index = core_load_addr_i[OFFSET_W + INDEX_W - 1:OFFSET_W];
  assign load_tag = core_load_addr_i[31:OFFSET_W + INDEX_W];
  assign lookup_index = lookup_addr_q[OFFSET_W + INDEX_W - 1:OFFSET_W];
  assign lookup_tag = lookup_addr_q[31:OFFSET_W + INDEX_W];
  assign lookup_line_addr = {lookup_addr_q[31:OFFSET_W], {OFFSET_W{1'b0}}};

  assign store_hit0 = valid_q[0][store_index] &&
                      (tag_input_way0_q[store_index] == store_tag);
  assign store_hit1 = valid_q[1][store_index] &&
                      (tag_input_way1_q[store_index] == store_tag);
  assign store_hit = store_hit0 || store_hit1;
  assign store_hit_way = store_hit1;
  assign load_hit0 = valid_q[0][load_index] &&
                     (tag_load_way0_q[load_index] == load_tag);
  assign load_hit1 = valid_q[1][load_index] &&
                     (tag_load_way1_q[load_index] == load_tag);
  assign lookup_hit0 = valid_q[0][lookup_index] &&
                       (tag_lookup_way0_q[lookup_index] == lookup_tag);
  assign lookup_hit1 = valid_q[1][lookup_index] &&
                       (tag_lookup_way1_q[lookup_index] == lookup_tag);
  assign lookup_victim_way = !valid_q[0][lookup_index] ? 1'b0 :
                             !valid_q[1][lookup_index] ? 1'b1 : lru_q[lookup_index];

  assign store_wstrb64 = core_store_addr_i[2] ? {core_req_wstrb_i, 4'b0}
                                             : {4'b0, core_req_wstrb_i};
  assign store_wdata64 = core_store_addr_i[2] ? {core_req_wdata_i, 32'b0}
                                             : {32'b0, core_req_wdata_i};

  // A load can remain in lookup_valid_q while both same-line MSHR waiter
  // slots are occupied.  Keep the existing RAM read port on that lookup so
  // an intervening line install refreshes its data before the eventual hit;
  // otherwise the tag can become valid while a_rdata still belongs to the
  // evicted line that was sampled when the request first arrived.
  // The inferred 7-series true-dual-port BRAM has no architecturally useful
  // result for a cross-port read/write collision.  A lookup already held in
  // the one-entry CPU pipeline may target the refill beat being installed on
  // the maintenance port, so suppress that read until installation leaves the
  // set.  lookup_data_ready_q below records that a clean synchronous read has
  // completed before tag/data are allowed to produce a response.
  assign lookup_install_conflict = engine_active_q &&
                                   (engine_state_q == E_INSTALL) &&
                                   (mshr_set_q[engine_mshr_q] == lookup_index);
  // A held lookup needs a second BRAM read only after an install collision
  // invalidated its sampled data.  Give that replay explicit ownership;
  // otherwise address the RAM directly from the incoming load.  The BRAM
  // address mux is now controlled by local registered lookup state instead
  // of the full load-valid -> ready/arbitration feedback cone.
  // A BRAM read has no architectural effect until lookup_valid_q captures an
  // accepted request.  Start that harmless read from the incoming load alone
  // instead of driving ENA through the MSHR/store/ready arbitration cone.
  // Reads issued while maintenance blocks admission are ignored and replayed
  // when the request is accepted.
  // An install writes port B on every beat.  Input admission is already
  // blocked for those four cycles, so an incoming load read would be purely
  // speculative and its value discarded.  Suppress it to avoid the
  // undefined same-address cross-port read/write case of 7-series BRAM.
  assign data_cpu_spec_load = core_load_valid_i &&
    !(engine_active_q && (engine_state_q == E_INSTALL));
  assign data_cpu_replay = lookup_valid_q && !lookup_data_ready_q &&
                           !lookup_install_conflict;
  assign data_cpu_read_request = data_cpu_spec_load || data_cpu_replay;
  // Do not let an unaccepted speculative input overwrite the synchronous
  // BRAM output that belongs to a lookup held by response/MSHR backpressure.
  // Re-read the held word until the slot can advance; on an actual pipeline
  // handoff the incoming address owns the port and supplies the next lookup.
  assign data_cpu_addr = data_cpu_replay ||
                         (lookup_valid_q && !lookup_can_advance)
                       ? {lookup_index, lookup_addr_q[4:3]}
                       : {load_index, core_load_addr_i[4:3]};
  assign data_cpu_wdata = store_wdata64;
  assign store_hit_write_fire = core_store_valid_i && core_store_ready_o &&
                                store_hit;
  assign data_way0_cpu_we = 8'h00;
  assign data_way1_cpu_we = 8'h00;
  assign data_maint_busy = (clean_active_q && (clean_state_q == C_READ)) ||
                           (engine_active_q &&
                            ((engine_state_q == E_WB_READ) ||
                             (engine_state_q == E_INSTALL)));

  always_comb begin
    data_maint_en = 1'b0;
    data_way0_maint_we = 8'h00;
    data_way1_maint_we = 8'h00;
    data_maint_addr = '0;
    data_maint_wdata = '0;
    if (clean_active_q && (clean_state_q == C_READ)) begin
      data_maint_en = 1'b1;
      data_maint_addr = {clean_set_q, clean_beat_q};
    end else if (engine_active_q && (engine_state_q == E_WB_READ)) begin
      data_maint_en = 1'b1;
      data_maint_addr = {mshr_set_q[engine_mshr_q], engine_beat_q};
    end else if (engine_active_q && (engine_state_q == E_INSTALL)) begin
      data_maint_en = 1'b1;
      data_maint_addr = {mshr_set_q[engine_mshr_q], engine_beat_q};
      data_maint_wdata = install_merged_data;
      if (mshr_victim_way_q[engine_mshr_q])
        data_way1_maint_we = 8'hff;
      else
        data_way0_maint_we = 8'hff;
    end else if (store_hit_write_fire) begin
      // A registered store hit uses the second BRAM port, so a following load
      // can issue through port A in the same cycle.  Same-beat accesses are
      // blocked below because 7-series cross-port read/write data is undefined.
      data_maint_en = 1'b1;
      data_maint_addr = {store_index, core_store_addr_i[4:3]};
      data_maint_wdata = store_wdata64;
      if (store_hit1)
        data_way1_maint_we = store_wstrb64;
      else
        data_way0_maint_we = store_wstrb64;
    end
  end

  // A port-B write always wins ownership of a physical BRAM word.  The
  // higher-level admission checks normally prevent this overlap, but a
  // speculative port-A read is intentionally allowed before admission and
  // can otherwise collide with a store accepted in the same cycle.  Suppress
  // only the exact physical word collision.  If that read belonged to a newly
  // accepted load, lookup_data_ready_q remains clear and the existing replay
  // path performs the read on the next collision-free cycle.
  assign data_cpu_write_conflict = data_maint_en &&
    ((|data_way0_maint_we) || (|data_way1_maint_we)) &&
    (data_cpu_addr == data_maint_addr);
  assign data_cpu_en = data_cpu_read_request && !data_cpu_write_conflict;

  cache_data_ram #(.DEPTH(DATA_DEPTH)) u_data_way0 (
    .clk_i(clk_i), .a_en_i(data_cpu_en), .a_we_i(data_way0_cpu_we),
    .a_addr_i(data_cpu_addr), .a_wdata_i(data_cpu_wdata),
    .a_rdata_o(data_way0_cpu_rdata), .b_en_i(data_maint_en),
    .b_we_i(data_way0_maint_we), .b_addr_i(data_maint_addr),
    .b_wdata_i(data_maint_wdata), .b_rdata_o(data_way0_maint_rdata)
  );

  cache_data_ram #(.DEPTH(DATA_DEPTH)) u_data_way1 (
    .clk_i(clk_i), .a_en_i(data_cpu_en), .a_we_i(data_way1_cpu_we),
    .a_addr_i(data_cpu_addr), .a_wdata_i(data_cpu_wdata),
    .a_rdata_o(data_way1_cpu_rdata), .b_en_i(data_maint_en),
    .b_we_i(data_way1_maint_we), .b_addr_i(data_maint_addr),
    .b_wdata_i(data_maint_wdata), .b_rdata_o(data_way1_maint_rdata)
  );

  always_comb begin
    store_match_found = 1'b0;
    store_match_idx = 1'b0;
    store_set_locked = 1'b0;
    store_free_found = 1'b0;
    store_free_idx = 1'b0;
    lookup_match_found = 1'b0;
    lookup_match_idx = 1'b0;
    lookup_set_locked = 1'b0;
    lookup_free_found = 1'b0;
    lookup_free_idx = 1'b0;
    for (int unsigned m = 0; m < 2; m++) begin
      if (mshr_valid_q[m] && (mshr_line_addr_q[m] == store_line_addr) &&
          !store_match_found) begin
        store_match_found = 1'b1;
        store_match_idx = m[0];
      end
      if (mshr_valid_q[m] && (mshr_set_q[m] == store_index))
        store_set_locked = 1'b1;
      if (!mshr_valid_q[m] && !store_free_found) begin
        store_free_found = 1'b1;
        store_free_idx = m[0];
      end

      if (mshr_valid_q[m] && (mshr_line_addr_q[m] == lookup_line_addr) &&
          !lookup_match_found) begin
        lookup_match_found = 1'b1;
        lookup_match_idx = m[0];
      end
      if (mshr_valid_q[m] && (mshr_set_q[m] == lookup_index))
        lookup_set_locked = 1'b1;
      if (!mshr_valid_q[m] && !lookup_free_found) begin
        lookup_free_found = 1'b1;
        lookup_free_idx = m[0];
      end
    end

    store_merge_allowed = store_match_found &&
      !(engine_active_q && (engine_mshr_q == store_match_idx) &&
        (engine_state_q == E_INSTALL));
    lookup_merge_allowed = lookup_match_found &&
      !(engine_active_q && (engine_mshr_q == lookup_match_idx) &&
        (engine_state_q == E_INSTALL));
    lookup_waiter_free = 1'b0;
    lookup_waiter_idx = 1'b0;
    if (lookup_match_found) begin
      if (!mshr_waiter_q[lookup_match_idx][0].valid) begin
        lookup_waiter_free = 1'b1;
        lookup_waiter_idx = 1'b0;
      end else if (!mshr_waiter_q[lookup_match_idx][1].valid) begin
        lookup_waiter_free = 1'b1;
        lookup_waiter_idx = 1'b1;
      end
    end

    // The maintenance BRAM port is active for only four install beats.  Stall
    // the CPU input for those beats irrespective of its address, instead of
    // comparing the live request index against the MSHR set in the ready
    // cone.  This makes request admission independent of LQ/SQ address data
    // and terminates that control path at the dmem request FIFO.  The held
    // lookup still uses the precise same-set collision check above.
    input_install_conflict = engine_active_q && (engine_state_q == E_INSTALL);
    store_can_accept = store_hit || store_merge_allowed ||
                       (store_free_found && !store_set_locked);
    store_lookup_word_conflict = lookup_valid_q &&
      (store_index == lookup_index) &&
      (core_store_addr_i[4:3] == lookup_addr_q[4:3]);
    store_exec_ready = store_can_accept &&
      (!store_hit || (!data_maint_busy && !store_lookup_word_conflict));
    // A resident store may be accepted with a younger load.  If both touch
    // the same physical word, data_cpu_write_conflict suppresses only the
    // BRAM read and the registered lookup replays on the following cycle.
    // This keeps memory ordering in the LQ/SQ and removes the combinational
    // execute-address -> store-forward-overlay -> load-response chain.
    store_blocks_load = core_store_valid_i &&
      (!store_exec_ready || !store_hit);
    core_load_ready_o = 1'b0;
    core_store_ready_o = 1'b0;
    if ((!lookup_valid_q || lookup_can_advance) &&
        !input_install_conflict && !clean_active_q &&
        !clean_req_i) begin
      core_load_ready_o = !store_blocks_load;
      core_store_ready_o = store_exec_ready;
    end
    core_req_ready_o = core_store_valid_i ? core_store_ready_o
                                          : core_load_ready_o;
  end

  always_comb begin
    response_mshr_found = 1'b0;
    response_mshr_idx = 1'b0;
    response_waiter_found = 1'b0;
    response_waiter_idx = 1'b0;
    for (int unsigned m = 0; m < 2; m++) begin
      if (mshr_valid_q[m] && (mshr_state_q[m] == MS_RESP) &&
          !response_mshr_found) begin
        response_mshr_found = 1'b1;
        response_mshr_idx = m[0];
      end
    end
    if (response_mshr_found) begin
      if (mshr_waiter_q[response_mshr_idx][0].valid) begin
        response_waiter_found = 1'b1;
        response_waiter_idx = 1'b0;
      end else if (mshr_waiter_q[response_mshr_idx][1].valid) begin
        response_waiter_found = 1'b1;
        response_waiter_idx = 1'b1;
      end
    end
    response_line_word = mshr_line_data_q[response_mshr_idx]
      [mshr_waiter_q[response_mshr_idx][response_waiter_idx].addr[4:3]];
  end

  // Tag comparison and replacement choice are captured on the same existing
  // request/BRAM-read edge.  The following cycle therefore combines registered
  // hit state with the synchronous BRAM output; no hit cycle is added, and the
  // LUTRAM tag mux no longer reaches the LQ/ROB response endpoints.  A held
  // miss is re-read and refreshes these bits after any conflicting install.
  always_comb begin
    lookup_hit_response = lookup_valid_q && lookup_data_ready_q &&
                           !rsp_valid_q &&
                           (lookup_hit0_q || lookup_hit1_q);
    lookup_can_advance = lookup_valid_q && lookup_data_ready_q &&
      (lookup_hit_response ||
       (!response_mshr_found &&
         (!(lookup_hit0_q || lookup_hit1_q) &&
          lookup_match_found &&
          lookup_merge_allowed && lookup_waiter_free)) ||
       (!response_mshr_found &&
         (!(lookup_hit0_q || lookup_hit1_q) &&
          !lookup_match_found &&
          lookup_free_found && !lookup_set_locked)));
  end

  assign core_load_accept = core_load_valid_i && core_load_ready_o;

  assign victim_line_addr = {
    mshr_victim_tag_q[engine_mshr_q], mshr_set_q[engine_mshr_q],
    {OFFSET_W{1'b0}}
  };
  assign install_merged_data = overlay_beat(
    mshr_line_data_q[engine_mshr_q][engine_beat_q],
    mshr_store_data_q[engine_mshr_q], mshr_store_mask_q[engine_mshr_q],
    engine_beat_q
  );

  always_comb begin
    mem_req_valid_o = 1'b0;
    mem_req_write_o = 1'b0;
    mem_req_addr_o = '0;
    mem_req_wdata_o = '0;
    mem_req_wstrb_o = '0;
    if (clean_active_q && (clean_state_q == C_REQ)) begin
      mem_req_valid_o = 1'b1;
      mem_req_write_o = 1'b1;
      mem_req_addr_o = {clean_way_q ? tag_input_way1_q[clean_set_q]
                                    : tag_input_way0_q[clean_set_q], clean_set_q,
                        {OFFSET_W{1'b0}}} +
                       {27'b0, clean_beat_q, 3'b000};
      mem_req_wdata_o = clean_data_q;
      mem_req_wstrb_o = 8'hff;
    end else if (engine_active_q && (engine_state_q == E_WB_REQ)) begin
      mem_req_valid_o = 1'b1;
      mem_req_write_o = 1'b1;
      mem_req_addr_o = victim_line_addr + {27'b0, engine_beat_q, 3'b000};
      mem_req_wdata_o = maint_data_q;
      mem_req_wstrb_o = 8'hff;
    end else if (engine_active_q && (engine_state_q == E_REFILL_REQ)) begin
      mem_req_valid_o = 1'b1;
      mem_req_addr_o = mshr_line_addr_q[engine_mshr_q] +
                       {27'b0, engine_beat_q, 3'b000};
    end
  end

  assign core_rsp_valid_o = lookup_hit_response || rsp_valid_q;
  assign core_rsp_data_o = lookup_hit_response
                          ? (lookup_addr_q[2]
                             ? (lookup_hit0_q ? data_way0_cpu_rdata[63:32]
                                             : data_way1_cpu_rdata[63:32])
                             : (lookup_hit0_q ? data_way0_cpu_rdata[31:0]
                                             : data_way1_cpu_rdata[31:0]))
                          : rsp_data_q;
  assign core_rsp_error_o = lookup_hit_response ? 1'b0 : rsp_error_q;
  assign core_rsp_seq_o = lookup_hit_response ? lookup_seq_q : rsp_seq_q;
  assign core_rsp_uop_id_o = lookup_hit_response ? lookup_uop_id_q
                                                  : rsp_uop_id_q;
  assign idle_o = !lookup_valid_q && !mshr_valid_q[0] && !mshr_valid_q[1] &&
                  !engine_active_q && !rsp_valid_q && !clean_active_q;
  assign clean_done_o = clean_done_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      lookup_valid_q <= 1'b0;
      lookup_data_ready_q <= 1'b0;
      lookup_addr_q <= '0;
      lookup_seq_q <= '0;
      lookup_uop_id_q <= '0;
      lookup_hit0_q <= 1'b0;
      lookup_hit1_q <= 1'b0;
      lookup_repl_way_q <= 1'b0;
      engine_state_q <= E_IDLE;
      engine_active_q <= 1'b0;
      engine_mshr_q <= 1'b0;
      engine_beat_q <= '0;
      maint_data_q <= '0;
      clean_active_q <= 1'b0;
      clean_done_q <= 1'b0;
      clean_state_q <= C_SCAN;
      clean_set_q <= '0;
      clean_way_q <= 1'b0;
      clean_beat_q <= '0;
      clean_data_q <= '0;
      rsp_valid_q <= 1'b0;
      rsp_error_q <= 1'b0;
      rsp_data_q <= '0;
      rsp_seq_q <= '0;
      rsp_uop_id_q <= '0;
      for (int unsigned way = 0; way < 2; way++) begin
        for (int unsigned set_idx = 0; set_idx < SETS; set_idx++) begin
          valid_q[way][set_idx] <= 1'b0;
          dirty_q[way][set_idx] <= 1'b0;
        end
      end
      for (int unsigned set_idx = 0; set_idx < SETS; set_idx++) lru_q[set_idx] <= 1'b0;
      for (int unsigned m = 0; m < 2; m++) begin
        mshr_valid_q[m] <= 1'b0;
        mshr_state_q[m] <= MS_WAIT;
        mshr_line_addr_q[m] <= '0;
        mshr_set_q[m] <= '0;
        mshr_tag_q[m] <= '0;
        mshr_victim_way_q[m] <= 1'b0;
        mshr_victim_valid_q[m] <= 1'b0;
        mshr_victim_dirty_q[m] <= 1'b0;
        mshr_victim_tag_q[m] <= '0;
        mshr_store_data_q[m] <= '0;
        mshr_store_mask_q[m] <= '0;
        mshr_error_q[m] <= 1'b0;
        for (int unsigned beat = 0; beat < BEATS_PER_LINE; beat++)
          mshr_line_data_q[m][beat] <= '0;
        for (int unsigned w = 0; w < 2; w++) mshr_waiter_q[m][w] <= '0;
      end
    end else begin
      rsp_valid_q <= 1'b0;
      clean_done_q <= 1'b0;

      if (!lookup_valid_q)
        lookup_data_ready_q <= 1'b0;
      else if (lookup_install_conflict)
        lookup_data_ready_q <= 1'b0;
      else if (data_cpu_en)
        lookup_data_ready_q <= 1'b1;

      // A held lookup is refreshed only when the CPU BRAM read is collision-
      // free.  On initial acceptance use the input-side tag replica because
      // lookup_addr_q still contains the preceding request at this edge.
      if (lookup_valid_q && !lookup_install_conflict && data_cpu_en) begin
        lookup_hit0_q <= lookup_hit0;
        lookup_hit1_q <= lookup_hit1;
        lookup_repl_way_q <= lookup_victim_way;
      end

      // FENCE.I requests a complete dirty-line clean after all normal cache
      // traffic has quiesced.  The scan reuses the one 64-bit maintenance
      // port; no extra data-array read path or timing-critical mux is added.
      if (!clean_active_q && clean_req_i && idle_o) begin
        clean_active_q <= 1'b1;
        clean_state_q <= C_SCAN;
        clean_set_q <= '0;
        clean_way_q <= 1'b0;
        clean_beat_q <= '0;
      end else if (clean_active_q) begin
        unique case (clean_state_q)
          C_SCAN: begin
            if (valid_q[clean_way_q][clean_set_q] &&
                dirty_q[clean_way_q][clean_set_q]) begin
              clean_beat_q <= '0;
              clean_state_q <= C_READ;
            end else if (clean_way_q && (clean_set_q == LAST_SET)) begin
              clean_active_q <= 1'b0;
              clean_done_q <= 1'b1;
            end else begin
              if (clean_way_q) clean_set_q <= clean_set_q + 1'b1;
              clean_way_q <= ~clean_way_q;
            end
          end
          C_READ: begin
            clean_state_q <= C_CAPTURE;
          end
          C_CAPTURE: begin
            clean_data_q <= clean_way_q ? data_way1_maint_rdata
                                         : data_way0_maint_rdata;
            clean_state_q <= C_REQ;
          end
          C_REQ: begin
            if (mem_req_valid_o && mem_req_ready_i) begin
              if (clean_beat_q == 2'd3) begin
                dirty_q[clean_way_q][clean_set_q] <= 1'b0;
                clean_beat_q <= '0;
                clean_state_q <= C_SCAN;
                if (clean_way_q && (clean_set_q == LAST_SET)) begin
                  clean_active_q <= 1'b0;
                  clean_done_q <= 1'b1;
                end else begin
                  if (clean_way_q) clean_set_q <= clean_set_q + 1'b1;
                  clean_way_q <= ~clean_way_q;
                end
              end else begin
                clean_beat_q <= clean_beat_q + 1'b1;
                clean_state_q <= C_READ;
              end
            end
          end
          default: clean_state_q <= C_SCAN;
        endcase
      end

      // A committed store either updates a resident dirty line, merges into
      // an existing miss, or atomically transfers ownership to a new MSHR.
      if (core_store_valid_i && core_store_ready_o) begin
        if (store_hit) begin
          dirty_q[store_hit_way][store_index] <= 1'b1;
          lru_q[store_index] <= ~store_hit_way;
        end else if (store_merge_allowed) begin
          for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
            int unsigned line_byte;
            line_byte = {27'b0, core_store_addr_i[4:2], 2'b00} + byte_idx;
            if (core_req_wstrb_i[byte_idx]) begin
              mshr_store_mask_q[store_match_idx][line_byte] <= 1'b1;
              mshr_store_data_q[store_match_idx][line_byte*8 +: 8] <=
                core_req_wdata_i[byte_idx*8 +: 8];
            end
          end
        end else begin
          logic victim;
          victim = !valid_q[0][store_index] ? 1'b0 :
                   !valid_q[1][store_index] ? 1'b1 : lru_q[store_index];
          mshr_valid_q[store_free_idx] <= 1'b1;
          mshr_state_q[store_free_idx] <= MS_WAIT;
          mshr_line_addr_q[store_free_idx] <= store_line_addr;
          mshr_set_q[store_free_idx] <= store_index;
          mshr_tag_q[store_free_idx] <= store_tag;
          mshr_victim_way_q[store_free_idx] <= victim;
          mshr_victim_valid_q[store_free_idx] <= valid_q[victim][store_index];
          mshr_victim_dirty_q[store_free_idx] <= valid_q[victim][store_index] &&
                                                   dirty_q[victim][store_index];
          mshr_victim_tag_q[store_free_idx] <= victim
            ? tag_input_way1_q[store_index] : tag_input_way0_q[store_index];
          // The mask is the validity state for every byte.  Do not clear the
          // 256-bit data payload on allocation: bytes whose mask is zero are
          // architecturally ignored, while written bytes are assigned below.
          // Avoiding the redundant clear also removes a wide, data-dependent
          // synchronous-reset fanout from the store admission cone.
          mshr_store_mask_q[store_free_idx] <= '0;
          mshr_error_q[store_free_idx] <= 1'b0;
          mshr_waiter_q[store_free_idx][0] <= '0;
          mshr_waiter_q[store_free_idx][1] <= '0;
          valid_q[victim][store_index] <= 1'b0;
          dirty_q[victim][store_index] <= 1'b0;
          for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
            int unsigned line_byte;
            line_byte = {27'b0, core_store_addr_i[4:2], 2'b00} + byte_idx;
            if (core_req_wstrb_i[byte_idx]) begin
              mshr_store_mask_q[store_free_idx][line_byte] <= 1'b1;
              mshr_store_data_q[store_free_idx][line_byte*8 +: 8] <=
                core_req_wdata_i[byte_idx*8 +: 8];
            end
          end
        end
      end

      // Loads use the CPU read port.  Their tags/data are checked one cycle
      // later; a miss leaves IQ/LQ and waits in one of the two MSHRs.
      if (core_load_accept) begin
        lookup_valid_q <= 1'b1;
        lookup_data_ready_q <= data_cpu_en;
        lookup_addr_q <= core_load_addr_i;
        lookup_seq_q <= core_req_seq_i;
        lookup_uop_id_q <= core_req_uop_id_i;
        lookup_hit0_q <= load_hit0;
        lookup_hit1_q <= load_hit1;
        lookup_repl_way_q <= !valid_q[0][load_index] ? 1'b0 :
                             !valid_q[1][load_index] ? 1'b1 :
                             lru_q[load_index];
      end

      if (lookup_valid_q && lookup_data_ready_q) begin
        if (lookup_hit_response) begin
          lru_q[lookup_index] <= lookup_hit0_q ? 1'b1 : 1'b0;
          lookup_valid_q <= core_load_accept;
          lookup_data_ready_q <= core_load_accept &&
                                 data_cpu_en;
        end else if (!response_mshr_found &&
                     !(lookup_hit0_q || lookup_hit1_q) && lookup_match_found &&
                      lookup_merge_allowed && lookup_waiter_free) begin
          mshr_waiter_q[lookup_match_idx][lookup_waiter_idx].valid <= 1'b1;
          mshr_waiter_q[lookup_match_idx][lookup_waiter_idx].addr <= lookup_addr_q;
          mshr_waiter_q[lookup_match_idx][lookup_waiter_idx].seq <= lookup_seq_q;
          mshr_waiter_q[lookup_match_idx][lookup_waiter_idx].uop_id <= lookup_uop_id_q;
          lookup_valid_q <= core_load_accept;
          lookup_data_ready_q <= core_load_accept &&
                                 data_cpu_en;
        end else if (!response_mshr_found &&
                     !(lookup_hit0_q || lookup_hit1_q) && !lookup_match_found &&
                      lookup_free_found && !lookup_set_locked) begin
          mshr_valid_q[lookup_free_idx] <= 1'b1;
          mshr_state_q[lookup_free_idx] <= MS_WAIT;
          mshr_line_addr_q[lookup_free_idx] <= lookup_line_addr;
          mshr_set_q[lookup_free_idx] <= lookup_index;
          mshr_tag_q[lookup_free_idx] <= lookup_tag;
          mshr_victim_way_q[lookup_free_idx] <= lookup_repl_way_q;
          mshr_victim_valid_q[lookup_free_idx] <=
            valid_q[lookup_repl_way_q][lookup_index];
          mshr_victim_dirty_q[lookup_free_idx] <=
            valid_q[lookup_repl_way_q][lookup_index] &&
            dirty_q[lookup_repl_way_q][lookup_index];
          mshr_victim_tag_q[lookup_free_idx] <= lookup_repl_way_q
            ? tag_lookup_way1_q[lookup_index]
            : tag_lookup_way0_q[lookup_index];
          // A load-allocated MSHR has an empty overlay mask, so stale overlay
          // payload bits are don't-care until a later store writes and masks
          // the corresponding bytes.
          mshr_store_mask_q[lookup_free_idx] <= '0;
          mshr_error_q[lookup_free_idx] <= 1'b0;
          mshr_waiter_q[lookup_free_idx][0] <= '{
            valid: 1'b1, addr: lookup_addr_q, seq: lookup_seq_q,
            uop_id: lookup_uop_id_q
          };
          mshr_waiter_q[lookup_free_idx][1] <= '0;
          valid_q[lookup_repl_way_q][lookup_index] <= 1'b0;
          dirty_q[lookup_repl_way_q][lookup_index] <= 1'b0;
          lookup_valid_q <= core_load_accept;
          lookup_data_ready_q <= core_load_accept &&
                                 data_cpu_en;
        end
      end

      // Completed MSHRs serialize only their response channel; lookup/miss
      // allocation remains independent, preserving hit-under-miss behavior.
      if (response_mshr_found) begin
        if (response_waiter_found) begin
          rsp_valid_q <= 1'b1;
          rsp_error_q <= mshr_error_q[response_mshr_idx];
          rsp_seq_q <= mshr_waiter_q[response_mshr_idx][response_waiter_idx].seq;
          rsp_uop_id_q <= mshr_waiter_q[response_mshr_idx][response_waiter_idx].uop_id;
          if (mshr_waiter_q[response_mshr_idx][response_waiter_idx].addr[2])
            rsp_data_q <= response_line_word[63:32];
          else
            rsp_data_q <= response_line_word[31:0];
          mshr_waiter_q[response_mshr_idx][response_waiter_idx].valid <= 1'b0;
          if (!mshr_waiter_q[response_mshr_idx][~response_waiter_idx].valid)
            mshr_valid_q[response_mshr_idx] <= 1'b0;
        end else begin
          mshr_valid_q[response_mshr_idx] <= 1'b0;
        end
      end

      // One 64-bit maintenance engine services both recorded misses.  Dirty
      // victim writeback and refill are mutually exclusive by construction.
      if (!engine_active_q && !clean_active_q) begin
        if (mshr_valid_q[0] && (mshr_state_q[0] == MS_WAIT)) begin
          engine_active_q <= 1'b1;
          engine_mshr_q <= 1'b0;
          engine_beat_q <= '0;
          engine_state_q <= (mshr_victim_valid_q[0] && mshr_victim_dirty_q[0])
                          ? E_WB_READ : E_REFILL_REQ;
        end else if (mshr_valid_q[1] && (mshr_state_q[1] == MS_WAIT)) begin
          engine_active_q <= 1'b1;
          engine_mshr_q <= 1'b1;
          engine_beat_q <= '0;
          engine_state_q <= (mshr_victim_valid_q[1] && mshr_victim_dirty_q[1])
                          ? E_WB_READ : E_REFILL_REQ;
        end
      end else begin
        unique case (engine_state_q)
          E_WB_READ: begin
            engine_state_q <= E_WB_CAPTURE;
          end
          E_WB_CAPTURE: begin
            maint_data_q <= mshr_victim_way_q[engine_mshr_q]
                          ? data_way1_maint_rdata : data_way0_maint_rdata;
            engine_state_q <= E_WB_REQ;
          end
          E_WB_REQ: begin
            if (mem_req_valid_o && mem_req_ready_i) begin
              if (engine_beat_q == 2'd3) begin
                engine_beat_q <= '0;
                engine_state_q <= E_REFILL_REQ;
              end else begin
                engine_beat_q <= engine_beat_q + 1'b1;
                engine_state_q <= E_WB_READ;
              end
            end
          end
          E_REFILL_REQ: begin
            if (mem_req_valid_o && mem_req_ready_i) engine_state_q <= E_REFILL_WAIT;
          end
          E_REFILL_WAIT: begin
            if (mem_rsp_valid_i) begin
              mshr_line_data_q[engine_mshr_q][engine_beat_q] <= mem_rsp_data_i;
              mshr_error_q[engine_mshr_q] <=
                mshr_error_q[engine_mshr_q] || mem_rsp_error_i;
              if (engine_beat_q == 2'd3) begin
                engine_beat_q <= '0;
                engine_state_q <= E_INSTALL;
              end else begin
                engine_beat_q <= engine_beat_q + 1'b1;
                engine_state_q <= E_REFILL_REQ;
              end
            end
          end
          E_INSTALL: begin
            if (mshr_error_q[engine_mshr_q]) begin
              mshr_state_q[engine_mshr_q] <= MS_RESP;
              engine_active_q <= 1'b0;
              engine_state_q <= E_IDLE;
            end else begin
              mshr_line_data_q[engine_mshr_q][engine_beat_q] <= install_merged_data;
              if (engine_beat_q == 2'd3) begin
                if (mshr_victim_way_q[engine_mshr_q]) begin
                  tag_input_way1_q[mshr_set_q[engine_mshr_q]] <=
                    mshr_tag_q[engine_mshr_q];
                  tag_load_way1_q[mshr_set_q[engine_mshr_q]] <=
                    mshr_tag_q[engine_mshr_q];
                  tag_lookup_way1_q[mshr_set_q[engine_mshr_q]] <=
                    mshr_tag_q[engine_mshr_q];
                end else begin
                  tag_input_way0_q[mshr_set_q[engine_mshr_q]] <=
                    mshr_tag_q[engine_mshr_q];
                  tag_load_way0_q[mshr_set_q[engine_mshr_q]] <=
                    mshr_tag_q[engine_mshr_q];
                  tag_lookup_way0_q[mshr_set_q[engine_mshr_q]] <=
                    mshr_tag_q[engine_mshr_q];
                end
                valid_q[mshr_victim_way_q[engine_mshr_q]][mshr_set_q[engine_mshr_q]] <=
                  1'b1;
                dirty_q[mshr_victim_way_q[engine_mshr_q]][mshr_set_q[engine_mshr_q]] <=
                  |mshr_store_mask_q[engine_mshr_q];
                lru_q[mshr_set_q[engine_mshr_q]] <= ~mshr_victim_way_q[engine_mshr_q];
                mshr_state_q[engine_mshr_q] <= MS_RESP;
                engine_active_q <= 1'b0;
                engine_state_q <= E_IDLE;
                engine_beat_q <= '0;
              end else begin
                engine_beat_q <= engine_beat_q + 1'b1;
              end
            end
          end
          default: begin
            engine_active_q <= 1'b0;
            engine_state_q <= E_IDLE;
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (LINE_BYTES == 32) else $fatal(1, "D-cache line must be 32 bytes");
    assert ((SETS == 64) || (SETS == 128))
      else $fatal(1, "D-cache supports 4 KiB or 8 KiB, two-way");
  end
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(mshr_valid_q[0] && mshr_valid_q[1] &&
                (mshr_set_q[0] == mshr_set_q[1])))
        else $fatal(1, "D-cache allocated two replacement owners for one set");
      if (engine_active_q)
        assert (mshr_valid_q[engine_mshr_q])
          else $fatal(1, "D-cache engine lost its MSHR owner");
    end
  end
`endif
endmodule
