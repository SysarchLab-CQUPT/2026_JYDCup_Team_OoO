`timescale 1ns/1ps
module store_queue #(
  parameter int unsigned ENTRIES = 8
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [1:0]                   alloc_valid_i,
  input  core_types_pkg::uop_id_t      alloc_uop_id_i [2],
  output logic [1:0]                   alloc_accept_o,
  output logic [3:0]                   alloc_seq_o [2],

  input  logic                         execute_valid_i,
  input  logic [3:0]                   execute_seq_i,
  input  core_types_pkg::uop_id_t      execute_uop_id_i,
  input  logic [31:0]                  execute_addr_i,
  input  logic [31:0]                  execute_data_i,
  input  logic [3:0]                   execute_mask_i,
  output logic [7:0]                   addr_done_onehot_o,

  input  logic                         commit_valid_i,
  input  logic [3:0]                   commit_seq_i,
  input  logic                         commit_remove_i,
  input  logic                         recovery_valid_i,
  input  logic [3:0]                   recovery_alloc_tail_i,

  output logic                         drain_valid_o,
  input  logic                         drain_ready_i,
  output logic [31:0]                  drain_addr_o,
  output logic [31:0]                  drain_data_o,
  output logic [3:0]                   drain_mask_o,
  output logic [3:0]                   drain_seq_o,

  input  logic                         query_valid_i,
  input  logic [31:0]                  query_addr_i,
  input  logic [3:0]                   query_mask_i,
  input  logic [3:0]                   query_older_tail_i,
  output logic [3:0]                   query_forward_mask_o,
  output logic [31:0]                  query_forward_data_o,
  output logic                         query_forward_ready_o,

  output logic [7:0]                   addr_not_ready_mask_o,
  output logic [3:0]                   head_o,
  output logic [3:0]                   commit_tail_o,
  output logic [3:0]                   alloc_tail_o,
  output logic [3:0]                   count_o,
  output logic                         committed_empty_o
);
  import core_types_pkg::*;

  localparam int unsigned INDEX_W = $clog2(ENTRIES);
  localparam logic [3:0] ENTRY_COUNT = 4'(ENTRIES);

  // Only ownership/status is reset and written by allocation.  Address/data
  // payload has a single producer (store execution), so keeping it in
  // separate unreset arrays prevents dual dispatch from clearing and driving
  // every wide payload bit.  Stale payload is harmless while addr_ready=0.
  logic valid_q [ENTRIES];
  logic addr_ready_q [ENTRIES];
  logic [3:0] seq_q [ENTRIES];
  uop_id_t uop_id_q [ENTRIES];
  (* ram_style = "distributed" *) logic [31:0] addr_q [ENTRIES];
  (* ram_style = "distributed" *) logic [31:0] data_q [ENTRIES];
  (* ram_style = "distributed" *) logic [3:0] mask_q [ENTRIES];
  logic [3:0] head_q, commit_tail_q, alloc_tail_q;
  logic drain_fire;
  logic [3:0] occupancy;
  logic [1:0] alloc_count;
  logic [3:0] tail_after_lane0;
  logic [3:0] removed_count;

  logic [ENTRIES-1:0] fwd_match [4];
  logic [(2*ENTRIES)-1:0] fwd_match_doubled [4];
  logic [ENTRIES-1:0] fwd_match_rotated [4];
  logic [INDEX_W-1:0] fwd_offset [4];
  logic [INDEX_W-1:0] fwd_index [4];

  assign occupancy = alloc_tail_q - head_q;
  assign drain_valid_o = (head_q != commit_tail_q) &&
                         valid_q[head_q[INDEX_W-1:0]] &&
                         addr_ready_q[head_q[INDEX_W-1:0]] &&
                         (seq_q[head_q[INDEX_W-1:0]] == head_q);
  assign drain_addr_o = addr_q[head_q[INDEX_W-1:0]];
  assign drain_data_o = data_q[head_q[INDEX_W-1:0]];
  assign drain_mask_o = mask_q[head_q[INDEX_W-1:0]];
  assign drain_seq_o = head_q;
  assign drain_fire = drain_valid_o && drain_ready_i;

  always_comb begin
    alloc_accept_o = '0;
    alloc_seq_o[0] = alloc_tail_q;
    if (!recovery_valid_i && alloc_valid_i[0] &&
        (occupancy < ENTRY_COUNT))
      alloc_accept_o[0] = 1'b1;
    tail_after_lane0 = alloc_tail_q + {3'b0, alloc_accept_o[0]};
    alloc_seq_o[1] = tail_after_lane0;
    if (!recovery_valid_i && alloc_valid_i[1] &&
        ((occupancy + {3'b0, alloc_accept_o[0]}) < ENTRY_COUNT))
      alloc_accept_o[1] = 1'b1;
    alloc_count = {1'b0, alloc_accept_o[0]} + {1'b0, alloc_accept_o[1]};
    removed_count = alloc_tail_q - recovery_alloc_tail_i;
  end

  always_comb begin
    addr_done_onehot_o = '0;
    if (execute_valid_i &&
        valid_q[execute_seq_i[INDEX_W-1:0]] &&
        (seq_q[execute_seq_i[INDEX_W-1:0]] == execute_seq_i) &&
        (uop_id_q[execute_seq_i[INDEX_W-1:0]] == execute_uop_id_i))
      addr_done_onehot_o[execute_seq_i[INDEX_W-1:0]] = 1'b1;

    for (int unsigned i = 0; i < ENTRIES; i++)
      addr_not_ready_mask_o[i] = valid_q[i] && !addr_ready_q[i];
  end

  always_comb begin
    query_forward_mask_o = '0;
    query_forward_data_o = '0;
    query_forward_ready_o = 1'b1;
    for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
      fwd_match[byte_idx] = '0;
      for (int unsigned entry_idx = 0; entry_idx < ENTRIES; entry_idx++) begin
        logic [3:0] delta;
        delta = query_older_tail_i - seq_q[entry_idx];
        fwd_match[byte_idx][entry_idx] = query_valid_i &&
          query_mask_i[byte_idx] && valid_q[entry_idx] &&
          addr_ready_q[entry_idx] && (delta >= 1) &&
          (delta <= ENTRY_COUNT) &&
          (addr_q[entry_idx][31:2] == query_addr_i[31:2]) &&
          mask_q[entry_idx][byte_idx];
      end

      // Rotate slot order so the newest older store is bit zero, then isolate
      // one match.  Selection is a narrow bitmap/encoder; store data is read
      // only after the index is known instead of flowing through three levels
      // of candidate records for every byte.
      fwd_match_doubled[byte_idx] = {fwd_match[byte_idx],
                                     fwd_match[byte_idx]};
      fwd_match_rotated[byte_idx] = fwd_match_doubled[byte_idx]
        [{1'b0, query_older_tail_i[INDEX_W-1:0]} +: ENTRIES];
      fwd_offset[byte_idx] = '0;
      for (int unsigned entry_idx = 0; entry_idx < ENTRIES; entry_idx++)
        if (fwd_match_rotated[byte_idx][entry_idx])
          fwd_offset[byte_idx] = entry_idx[INDEX_W-1:0];
      fwd_index[byte_idx] = query_older_tail_i[INDEX_W-1:0] +
                            fwd_offset[byte_idx];
      if (|fwd_match_rotated[byte_idx]) begin
        query_forward_mask_o[byte_idx] = 1'b1;
        query_forward_data_o[byte_idx*8 +: 8] =
          data_q[fwd_index[byte_idx]][byte_idx*8 +: 8];
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      head_q <= '0;
      commit_tail_q <= '0;
      alloc_tail_q <= '0;
      for (int unsigned i = 0; i < ENTRIES; i++) begin
        valid_q[i] <= 1'b0;
        addr_ready_q[i] <= 1'b0;
      end
    end else begin
      if (drain_fire) begin
        valid_q[head_q[INDEX_W-1:0]] <= 1'b0;
        head_q <= head_q + 1'b1;
      end

      if (commit_valid_i) begin
        commit_tail_q <= commit_tail_q + 1'b1;
        // Precisely accepted MMIO stores transfer ownership directly to the
        // peripheral instead of entering the cache-drain prefix.
        if (commit_remove_i) begin
          valid_q[commit_seq_i[INDEX_W-1:0]] <= 1'b0;
          head_q <= head_q + 1'b1;
        end
      end

      if (execute_valid_i && addr_done_onehot_o[execute_seq_i[INDEX_W-1:0]]) begin
        addr_ready_q[execute_seq_i[INDEX_W-1:0]] <= 1'b1;
        addr_q[execute_seq_i[INDEX_W-1:0]] <= execute_addr_i;
        data_q[execute_seq_i[INDEX_W-1:0]] <= execute_data_i;
        mask_q[execute_seq_i[INDEX_W-1:0]] <= execute_mask_i;
      end

      if (recovery_valid_i) begin
        alloc_tail_q <= recovery_alloc_tail_i;
        for (int unsigned i = 0; i < ENTRIES; i++) begin
          logic [3:0] from_recovery;
          from_recovery = seq_q[i] - recovery_alloc_tail_i;
          if (valid_q[i] && (from_recovery < removed_count))
            valid_q[i] <= 1'b0;
        end
      end else begin
        alloc_tail_q <= alloc_tail_q + {2'b0, alloc_count};
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (alloc_accept_o[lane]) begin
            valid_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b1;
            addr_ready_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b0;
            seq_q[alloc_seq_o[lane][INDEX_W-1:0]] <= alloc_seq_o[lane];
            uop_id_q[alloc_seq_o[lane][INDEX_W-1:0]] <= alloc_uop_id_i[lane];
          end
        end
      end
    end
  end

  assign head_o = head_q;
  assign commit_tail_o = commit_tail_q;
  assign alloc_tail_o = alloc_tail_q;
  assign count_o = occupancy;
  assign committed_empty_o = (head_q == commit_tail_q);

`ifndef SYNTHESIS
  initial assert (ENTRIES == 8) else $fatal(1, "SQ requires exactly 8 entries");
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (occupancy <= ENTRY_COUNT) else $fatal(1, "SQ occupancy overflow");
      assert ((commit_tail_q - head_q) <= ENTRY_COUNT)
        else $fatal(1, "SQ committed prefix overflow");
      assert ((alloc_tail_q - commit_tail_q) <= ENTRY_COUNT)
        else $fatal(1, "SQ speculative suffix overflow");
      if (commit_valid_i) begin
        assert (commit_seq_i == commit_tail_q)
          else $fatal(1, "SQ commit was not in program order");
        assert (valid_q[commit_seq_i[INDEX_W-1:0]] &&
                addr_ready_q[commit_seq_i[INDEX_W-1:0]] &&
                seq_q[commit_seq_i[INDEX_W-1:0]] == commit_seq_i)
          else $fatal(1, "SQ committed an incomplete entry");
        if (commit_remove_i)
          assert ((head_q == commit_tail_q) && (commit_seq_i == head_q) && !drain_fire)
            else $fatal(1, "SQ MMIO removal bypassed an older committed store");
      end
      if (recovery_valid_i)
        assert ((recovery_alloc_tail_i - commit_tail_q) <= ENTRY_COUNT)
          else $fatal(1, "SQ recovery discarded committed ownership");
    end
  end
`endif
endmodule
