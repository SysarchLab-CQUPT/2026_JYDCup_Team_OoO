`timescale 1ns/1ps
module free_bitmap (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [1:0]                   alloc_req_i,
  input  logic [1:0]                   alloc_take_i,
  output logic [1:0]                   alloc_gnt_o,
  output core_types_pkg::preg_t        alloc_preg_o [2],
  output logic                         rename_bank_conflict_o,

  input  logic [1:0]                   commit_free_valid_i,
  input  core_types_pkg::preg_t        commit_free_preg_i [2],
  input  logic                         recovery_valid_i,
  input  logic [soc_cfg_pkg::PHYS_REGS-1:0] recovery_free_mask_i,

  input  logic                         rebuild_valid_i,
  input  logic [soc_cfg_pkg::PHYS_REGS-1:0] rebuild_free_mask_i,

  output logic [soc_cfg_pkg::PHYS_REGS-1:0] free_bits_o
);
  import soc_cfg_pkg::*;
  import core_types_pkg::*;

  logic [PHYS_REGS-1:0] free_bits_q;
  logic [PHYS_REGS-1:0] released_bits;
  logic [PHYS_REGS-1:0] normal_released_bits;
  logic [PHYS_REGS-1:0] taken_mask;
  logic [PHYS_REGS-1:0] next_free_bits;
  logic [PHYS_REGS-1:0] encoder_free_bits;
  logic [31:0] even_free;
  logic [31:0] odd_free;
  logic [31:0] next_even_free;
  logic [31:0] next_odd_free;
  preg_t first_even_q;
  preg_t first_odd_q;
  logic have_even_q;
  logic have_odd_q;
  logic single_prefer_odd_q;
  logic single_alloc_taken;

  // Encode four eight-bit groups in parallel instead of synthesizing the
  // source-order loop as a 64-input serial priority chain.  The allocator is
  // physically banked by register parity, so compacting each parity first
  // also removes 32 known-zero inputs from each encoder.
  function automatic logic [4:0] first_set32(input logic [31:0] bits);
    logic [3:0] group_valid;
    logic [1:0] group_index;
    logic [2:0] bit_index;
    logic [7:0] selected_group;
    for (int unsigned group = 0; group < 4; group++)
      group_valid[group] = |bits[group*8 +: 8];
    priority casez (group_valid)
      4'b???1: group_index = 2'd0;
      4'b??10: group_index = 2'd1;
      4'b?100: group_index = 2'd2;
      default: group_index = 2'd3;
    endcase
    selected_group = bits[group_index*8 +: 8];
    priority casez (selected_group)
      8'b????_???1: bit_index = 3'd0;
      8'b????_??10: bit_index = 3'd1;
      8'b????_?100: bit_index = 3'd2;
      8'b????_1000: bit_index = 3'd3;
      8'b???1_0000: bit_index = 3'd4;
      8'b??10_0000: bit_index = 3'd5;
      8'b?100_0000: bit_index = 3'd6;
      default:      bit_index = 3'd7;
    endcase
    return {group_index, bit_index};
  endfunction

  always_comb begin
    normal_released_bits = free_bits_q;
    if (commit_free_valid_i[0] && (commit_free_preg_i[0] != '0)) begin
      normal_released_bits[commit_free_preg_i[0]] = 1'b1;
    end
    if (commit_free_valid_i[1] && (commit_free_preg_i[1] != '0)) begin
      normal_released_bits[commit_free_preg_i[1]] = 1'b1;
    end
    normal_released_bits[0] = 1'b0;
    released_bits = normal_released_bits;
    if (recovery_valid_i) begin
      released_bits |= recovery_free_mask_i;
    end
    released_bits[0] = 1'b0;

    for (int unsigned i = 0; i < 32; i++) begin
      even_free[i] = free_bits_q[2*i];
      odd_free[i] = free_bits_q[2*i+1];
    end

    alloc_gnt_o = '0;
    alloc_preg_o[0] = '0;
    alloc_preg_o[1] = '0;
    rename_bank_conflict_o = 1'b0;

    // Allocation is suppressed during recovery/rebuild. Recovery state is
    // written in one register stage and rename retries on the next cycle.
    if (!recovery_valid_i && !rebuild_valid_i) begin
      if (alloc_req_i[0] && alloc_req_i[1]) begin
        if (have_even_q && have_odd_q) begin
          alloc_gnt_o = 2'b11;
          alloc_preg_o[0] = first_even_q;
          alloc_preg_o[1] = first_odd_q;
        end else if (have_even_q) begin
          alloc_gnt_o[0] = 1'b1;
          alloc_preg_o[0] = first_even_q;
          rename_bank_conflict_o = |(even_free & (even_free - 1'b1));
        end else if (have_odd_q) begin
          alloc_gnt_o[0] = 1'b1;
          alloc_preg_o[0] = first_odd_q;
          rename_bank_conflict_o = |(odd_free & (odd_free - 1'b1));
        end
      end else if (alloc_req_i[0] || alloc_req_i[1]) begin
        if (have_even_q && have_odd_q) begin
          alloc_gnt_o[alloc_req_i[0] ? 0 : 1] = 1'b1;
          alloc_preg_o[alloc_req_i[0] ? 0 : 1] = single_prefer_odd_q
            ? first_odd_q : first_even_q;
        end else if (have_even_q) begin
          alloc_gnt_o[alloc_req_i[0] ? 0 : 1] = 1'b1;
          alloc_preg_o[alloc_req_i[0] ? 0 : 1] = first_even_q;
        end else if (have_odd_q) begin
          alloc_gnt_o[alloc_req_i[0] ? 0 : 1] = 1'b1;
          alloc_preg_o[alloc_req_i[0] ? 0 : 1] = first_odd_q;
        end
      end
    end
  end

  always_comb begin
    taken_mask = '0;
    if (alloc_take_i[0] && alloc_gnt_o[0]) taken_mask[alloc_preg_o[0]] = 1'b1;
    if (alloc_take_i[1] && alloc_gnt_o[1]) taken_mask[alloc_preg_o[1]] = 1'b1;
    single_alloc_taken = ((alloc_take_i & alloc_gnt_o) == 2'b01) ||
                         ((alloc_take_i & alloc_gnt_o) == 2'b10);

    if (rebuild_valid_i)
      next_free_bits = rebuild_free_mask_i &
                       ~{{(PHYS_REGS-1){1'b0}}, 1'b1};
    else
      next_free_bits = released_bits & ~taken_mask;
    // Recovery suppresses allocation and holds the cached encoders.  Their D
    // inputs therefore need only the normal commit/allocation state; feeding
    // the 32-entry recovery kill reduction here created a false architectural
    // dependency and a real 13-level setup path into four candidate flops.
    if (rebuild_valid_i)
      encoder_free_bits = rebuild_free_mask_i &
                          ~{{(PHYS_REGS-1){1'b0}}, 1'b1};
    else
      encoder_free_bits = normal_released_bits & ~taken_mask;
    for (int unsigned i = 0; i < 32; i++) begin
      next_even_free[i] = encoder_free_bits[2*i];
      next_odd_free[i] = encoder_free_bits[2*i+1];
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      free_bits_q <= {{(PHYS_REGS-32){1'b1}}, 32'b0};
      first_even_q <= preg_t'(32);
      first_odd_q <= preg_t'(33);
      have_even_q <= 1'b1;
      have_odd_q <= 1'b1;
      single_prefer_odd_q <= 1'b0;
    end else begin
      free_bits_q <= next_free_bits;
      if (single_alloc_taken)
        single_prefer_odd_q <= ~single_prefer_odd_q;
      // Branch recovery only adds registers to the free set and suppresses
      // allocation on this edge.  The previously selected candidate therefore
      // remains safe for the following cycle; refresh it normally one edge
      // later.  Rebuild may also remove bits and must update immediately.
      // Holding only on recovery removes its 32-entry mask construction and
      // priority encoders from these four registers' D paths.
      if (!recovery_valid_i) begin
        first_even_q <= {first_set32(next_even_free), 1'b0};
        first_odd_q <= {first_set32(next_odd_free), 1'b1};
        have_even_q <= |next_even_free;
        have_odd_q <= |next_odd_free;
      end
    end
  end

  assign free_bits_o = free_bits_q;

`ifndef SYNTHESIS
  initial assert (PHYS_REGS == 64)
    else $fatal(1, "free_bitmap parity encoder requires 64 physical registers");
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!free_bits_q[0]) else $fatal(1, "p0 must never be free");
      assert (!(alloc_gnt_o[0] && alloc_gnt_o[1] &&
                (alloc_preg_o[0] == alloc_preg_o[1])))
        else $fatal(1, "dual allocation returned the same physical register");
      assert (!(recovery_valid_i && (|alloc_gnt_o)))
        else $fatal(1, "rename allocation occurred during recovery");
      assert ((alloc_take_i & ~alloc_gnt_o) == 0)
        else $fatal(1, "rename consumed an ungranted physical register");
    end
  end
`endif
endmodule
