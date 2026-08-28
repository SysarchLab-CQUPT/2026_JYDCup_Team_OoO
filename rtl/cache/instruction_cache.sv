`timescale 1ns/1ps
module instruction_cache #(
  parameter int unsigned SETS = 128,
  parameter int unsigned LINE_BYTES = 32,
  parameter int unsigned EPOCH_W = 4
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic                 flush_i,

  input  logic                 core_req_valid_i,
  output logic                 core_req_ready_o,
  input  logic [31:0]          core_req_addr_i,
  input  logic [EPOCH_W-1:0]   core_req_epoch_i,
  output logic                 core_rsp_valid_o,
  input  logic                 core_rsp_ready_i,
  output logic [31:0]          core_rsp_addr_o,
  output logic [EPOCH_W-1:0]   core_rsp_epoch_o,
  output logic [63:0]          core_rsp_data_o,
  output logic                 core_rsp_error_o,

  output logic                 mem_req_valid_o,
  input  logic                 mem_req_ready_i,
  output logic [31:0]          mem_req_addr_o,
  input  logic                 mem_rsp_valid_i,
  input  logic [63:0]          mem_rsp_data_i,
  input  logic                 mem_rsp_error_i
);
  localparam int unsigned INDEX_W = $clog2(SETS);
  localparam int unsigned WORDS_PER_LINE = LINE_BYTES / 8;
  localparam int unsigned WORD_W = $clog2(WORDS_PER_LINE);
  localparam int unsigned OFFSET_W = $clog2(LINE_BYTES);
  localparam int unsigned TAG_W = 32 - INDEX_W - OFFSET_W;
  localparam int unsigned DATA_DEPTH = SETS * WORDS_PER_LINE;

  // S_IDLE is the pipelined hit path.  The miss states stop new requests until
  // the single blocking refill has installed and replayed its owning request.
  typedef enum logic [2:0] {
    S_INVALIDATE, S_IDLE, S_REFILL_REQ, S_REFILL_WAIT, S_REPLAY_READ,
    S_ERROR_RSP
  } state_e;

  // Tags have one refill writer and one request read port.  valid_q guards
  // uninitialized contents, allowing a compact asynchronous LUTRAM lookup.
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_way0_q [SETS];
  (* ram_style = "distributed" *) logic [TAG_W-1:0] tag_way1_q [SETS];
  logic valid_q [2][SETS];
  logic lru_q [SETS];

  state_e state_q;
  (* max_fanout = 32 *) logic [31:0] req_addr_q;
  logic [EPOCH_W-1:0] req_epoch_q;
  logic victim_way_q;
  logic [WORD_W-1:0] refill_word_q;
  logic refill_error_q;
  logic [INDEX_W-1:0] invalidate_set_q;

  // The synchronous BRAM read is one lookup stage.  The response register is
  // elastic: it can be consumed and replaced in the same cycle, sustaining
  // one 64-bit hit response per clock without a combinational data path to the
  // core.
  logic s1_valid_q;
  logic [31:0] s1_addr_q;
  logic [EPOCH_W-1:0] s1_epoch_q;
  logic rsp_valid_q, rsp_error_q;
  logic [31:0] rsp_addr_q;
  logic [EPOCH_W-1:0] rsp_epoch_q;
  logic [63:0] rsp_data_q;
  logic rsp_slot_ready;

  logic [INDEX_W-1:0] core_req_index, s1_index, miss_index;
  logic [WORD_W-1:0] core_req_word, miss_word;
  logic [TAG_W-1:0] s1_tag, miss_tag;
  logic s1_hit_way0, s1_hit_way1, s1_hit;
  logic s1_chosen_victim;
  logic core_req_fire;
  logic data_cpu_en, data_refill_en;
  logic [$clog2(DATA_DEPTH)-1:0] data_cpu_addr, data_refill_addr;
  logic [7:0] data_way0_refill_we, data_way1_refill_we;
  logic [63:0] data_way0_cpu_rdata, data_way1_cpu_rdata;

  assign core_req_index = core_req_addr_i[OFFSET_W + INDEX_W - 1:OFFSET_W];
  assign core_req_word = core_req_addr_i[OFFSET_W-1:3];
  assign s1_index = s1_addr_q[OFFSET_W + INDEX_W - 1:OFFSET_W];
  assign s1_tag = s1_addr_q[31:OFFSET_W + INDEX_W];
  assign s1_hit_way0 = valid_q[0][s1_index] &&
                       (tag_way0_q[s1_index] == s1_tag);
  assign s1_hit_way1 = valid_q[1][s1_index] &&
                       (tag_way1_q[s1_index] == s1_tag);
  assign s1_hit = s1_hit_way0 || s1_hit_way1;
  assign s1_chosen_victim = !valid_q[0][s1_index] ? 1'b0 :
                            !valid_q[1][s1_index] ? 1'b1 :
                            lru_q[s1_index];

  assign miss_index = req_addr_q[OFFSET_W + INDEX_W - 1:OFFSET_W];
  assign miss_word = req_addr_q[OFFSET_W-1:3];
  assign miss_tag = req_addr_q[31:OFFSET_W + INDEX_W];

  assign rsp_slot_ready = !rsp_valid_q || core_rsp_ready_i;
  // S1 owns the registered request address.  A live EX0 redirect therefore
  // drives only the BRAM address on the acceptance edge; tag/refill/victim
  // decisions start after the register boundary.  A hit can leave S1 while a
  // new request replaces it on the same edge, sustaining one request/cycle.
  assign core_req_ready_o = (state_q == S_IDLE) && !flush_i &&
                            (!s1_valid_q || (s1_hit && rsp_slot_ready));
  assign core_req_fire = core_req_valid_i && core_req_ready_o;

  // Read both ways for every accepted request.  This deliberately removes the
  // live asynchronous tag-hit result from RAM EN and preserves the existing
  // hit latency because tag compare and BRAM output are consumed together in
  // S1 on the following edge.
  assign data_cpu_en = core_req_fire || (state_q == S_REPLAY_READ);
  assign data_cpu_addr = (state_q == S_REPLAY_READ)
                       ? {miss_index, miss_word}
                       : {core_req_index, core_req_word};
  assign data_refill_en = (state_q == S_REFILL_WAIT) && mem_rsp_valid_i &&
                          !mem_rsp_error_i;
  assign data_refill_addr = {miss_index, refill_word_q};
  assign data_way0_refill_we = data_refill_en && !victim_way_q ? 8'hff : 8'h00;
  assign data_way1_refill_we = data_refill_en && victim_way_q ? 8'hff : 8'h00;

  cache_data_ram #(.DEPTH(DATA_DEPTH)) u_data_way0 (
    .clk_i(clk_i), .a_en_i(data_cpu_en), .a_we_i(8'h00),
    .a_addr_i(data_cpu_addr), .a_wdata_i('0),
    .a_rdata_o(data_way0_cpu_rdata), .b_en_i(data_refill_en),
    .b_we_i(data_way0_refill_we), .b_addr_i(data_refill_addr),
    .b_wdata_i(mem_rsp_data_i), .b_rdata_o()
  );

  cache_data_ram #(.DEPTH(DATA_DEPTH)) u_data_way1 (
    .clk_i(clk_i), .a_en_i(data_cpu_en), .a_we_i(8'h00),
    .a_addr_i(data_cpu_addr), .a_wdata_i('0),
    .a_rdata_o(data_way1_cpu_rdata), .b_en_i(data_refill_en),
    .b_we_i(data_way1_refill_we), .b_addr_i(data_refill_addr),
    .b_wdata_i(mem_rsp_data_i), .b_rdata_o()
  );

  assign core_rsp_valid_o = rsp_valid_q;
  assign core_rsp_addr_o = rsp_addr_q;
  assign core_rsp_epoch_o = rsp_epoch_q;
  assign core_rsp_data_o = rsp_data_q;
  assign core_rsp_error_o = rsp_error_q;
  assign mem_req_valid_o = (state_q == S_REFILL_REQ) && !flush_i;
  assign mem_req_addr_o = {req_addr_q[31:OFFSET_W], refill_word_q, 3'b000};

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q <= S_INVALIDATE;
      req_addr_q <= '0;
      req_epoch_q <= '0;
      victim_way_q <= 1'b0;
      refill_word_q <= '0;
      refill_error_q <= 1'b0;
      invalidate_set_q <= '0;
      s1_valid_q <= 1'b0;
      s1_addr_q <= '0;
      s1_epoch_q <= '0;
      rsp_valid_q <= 1'b0;
      rsp_error_q <= 1'b0;
      rsp_addr_q <= '0;
      rsp_epoch_q <= '0;
      rsp_data_q <= '0;
    end else begin
      // Move an S1 hit and its synchronous BRAM output into the elastic
      // response slot.  A blocked response holds S1 and all of its metadata.
      if (rsp_slot_ready) begin
        rsp_valid_q <= (state_q == S_IDLE) && s1_valid_q && s1_hit;
        if ((state_q == S_IDLE) && s1_valid_q && s1_hit) begin
          rsp_error_q <= 1'b0;
          rsp_addr_q <= s1_addr_q;
          rsp_epoch_q <= s1_epoch_q;
          rsp_data_q <= s1_hit_way1 ? data_way1_cpu_rdata
                                    : data_way0_cpu_rdata;
          lru_q[s1_index] <= s1_hit_way0 ? 1'b1 : 1'b0;
        end
      end
      if ((state_q == S_IDLE) && s1_valid_q && s1_hit && rsp_slot_ready)
        s1_valid_q <= 1'b0;

      unique case (state_q)
        S_INVALIDATE: begin
          valid_q[0][invalidate_set_q] <= 1'b0;
          valid_q[1][invalidate_set_q] <= 1'b0;
          lru_q[invalidate_set_q] <= 1'b0;
          if (invalidate_set_q == INDEX_W'(SETS-1)) begin
            invalidate_set_q <= '0;
            state_q <= S_IDLE;
          end else begin
            invalidate_set_q <= invalidate_set_q + 1'b1;
          end
        end

        S_IDLE: begin
          // Miss detection uses only registered S1 metadata.  The request that
          // missed becomes the sole refill owner before any younger request is
          // admitted.
          if (s1_valid_q && !s1_hit) begin
            req_addr_q <= s1_addr_q;
            req_epoch_q <= s1_epoch_q;
            victim_way_q <= s1_chosen_victim;
            valid_q[s1_chosen_victim][s1_index] <= 1'b0;
            refill_word_q <= '0;
            refill_error_q <= 1'b0;
            s1_valid_q <= 1'b0;
            state_q <= S_REFILL_REQ;
          end

          if (core_req_fire) begin
            s1_valid_q <= 1'b1;
            s1_addr_q <= core_req_addr_i;
            s1_epoch_q <= core_req_epoch_i;
          end
        end

        S_REFILL_REQ: begin
          if (mem_req_valid_o && mem_req_ready_i)
            state_q <= S_REFILL_WAIT;
        end

        S_REFILL_WAIT: begin
          if (mem_rsp_valid_i) begin
            refill_error_q <= refill_error_q || mem_rsp_error_i;
            if (refill_word_q == WORD_W'(WORDS_PER_LINE-1)) begin
              if (refill_error_q || mem_rsp_error_i) begin
                state_q <= S_ERROR_RSP;
              end else begin
                if (victim_way_q)
                  tag_way1_q[miss_index] <= miss_tag;
                else
                  tag_way0_q[miss_index] <= miss_tag;
                valid_q[victim_way_q][miss_index] <= 1'b1;
                lru_q[miss_index] <= ~victim_way_q;
                state_q <= S_REPLAY_READ;
              end
            end else begin
              refill_word_q <= refill_word_q + 1'b1;
              state_q <= S_REFILL_REQ;
            end
          end
        end

        S_REPLAY_READ: begin
          // data_cpu_en performs the BRAM read at this edge.  Its metadata
          // enters the normal S1 stage and is returned through the same
          // ready/valid response path as an ordinary hit.
          s1_valid_q <= 1'b1;
          s1_addr_q <= req_addr_q;
          s1_epoch_q <= req_epoch_q;
          state_q <= S_IDLE;
        end

        S_ERROR_RSP: begin
          if (rsp_slot_ready) begin
            rsp_valid_q <= 1'b1;
            rsp_error_q <= 1'b1;
            rsp_addr_q <= req_addr_q;
            rsp_epoch_q <= req_epoch_q;
            rsp_data_q <= '0;
            state_q <= S_IDLE;
          end
        end

        default: state_q <= S_INVALIDATE;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (LINE_BYTES == 32) else $fatal(1, "I-cache line must be 32 bytes");
    assert (SETS == 128) else $fatal(1, "I-cache must have 128 sets for 8 KiB/2-way");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      assert (!(s1_valid_q && (!s1_hit || !rsp_slot_ready) && core_req_ready_o))
        else $fatal(1, "I-cache accepted request without S1 capacity");
      assert (!(core_rsp_valid_o && !core_rsp_ready_i && rsp_slot_ready))
        else $fatal(1, "I-cache response stability contract violated");
    end
  end
`endif
endmodule
