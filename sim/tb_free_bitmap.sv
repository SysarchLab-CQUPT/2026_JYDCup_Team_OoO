`timescale 1ns/1ps
module tb_free_bitmap;
  import soc_cfg_pkg::*;
  import core_types_pkg::*;

  logic clk;
  logic rst_n;
  logic [1:0] alloc_req;
  logic [1:0] alloc_take;
  logic [1:0] alloc_gnt;
  preg_t alloc_preg [2];
  logic bank_conflict;
  logic [1:0] commit_free_valid;
  preg_t commit_free_preg [2];
  logic recovery_valid;
  logic [PHYS_REGS-1:0] recovery_free_mask;
  logic rebuild_valid;
  logic [PHYS_REGS-1:0] rebuild_free_mask;
  logic [PHYS_REGS-1:0] free_bits;

  free_bitmap dut (.*,
    .clk_i(clk), .rst_ni(rst_n),
    .alloc_req_i(alloc_req), .alloc_take_i(alloc_take), .alloc_gnt_o(alloc_gnt),
    .alloc_preg_o(alloc_preg),
    .rename_bank_conflict_o(bank_conflict),
    .commit_free_valid_i(commit_free_valid),
    .commit_free_preg_i(commit_free_preg),
    .recovery_valid_i(recovery_valid),
    .recovery_free_mask_i(recovery_free_mask),
    .rebuild_valid_i(rebuild_valid),
    .rebuild_free_mask_i(rebuild_free_mask),
    .free_bits_o(free_bits)
  );

  always #5 clk = ~clk;

  task automatic step;
    @(posedge clk);
    #1;
  endtask

  initial begin
    clk = 0;
    rst_n = 0;
    alloc_req = '0;
    alloc_take = '0;
    commit_free_valid = '0;
    commit_free_preg[0] = '0;
    commit_free_preg[1] = '0;
    recovery_valid = 0;
    recovery_free_mask = '0;
    rebuild_valid = 0;
    rebuild_free_mask = '0;
    step();
    rst_n = 1;
    step();

    assert (free_bits[31:0] == '0);
    assert (&free_bits[63:32]);

    alloc_req = 2'b11;
    alloc_take = 2'b11;
    #1;
    assert (alloc_gnt == 2'b11);
    assert (alloc_preg[0] == 6'd32);
    assert (alloc_preg[1] == 6'd33);
    step();
    alloc_req = '0;
    alloc_take = '0;
    assert (!free_bits[32] && !free_bits[33]);

    // Commit and recovery frees must merge in the same registered update.
    commit_free_valid = 2'b01;
    commit_free_preg[0] = 6'd32;
    recovery_valid = 1;
    recovery_free_mask = 64'b1 << 33;
    #1;
    assert (alloc_gnt == 0);
    step();
    commit_free_valid = 0;
    recovery_valid = 0;
    recovery_free_mask = 0;
    assert (free_bits[32] && free_bits[33]);

    // A commit release updates the registered bitmap at the edge.  It must
    // not feed the allocator priority encoder in that same cycle.
    rebuild_valid = 1;
    rebuild_free_mask = '0;
    step();
    rebuild_valid = 0;
    alloc_req = 2'b01;
    alloc_take = 2'b00;
    commit_free_valid = 2'b01;
    commit_free_preg[0] = 6'd32;
    #1;
    assert (alloc_gnt == 2'b00)
      else $fatal(1, "commit-freed preg reused combinationally");
    step();
    commit_free_valid = 0;
    #1;
    assert (alloc_gnt == 2'b01 && alloc_preg[0] == 6'd32)
      else $fatal(1, "commit-freed preg unavailable after registered boundary");
    alloc_take = 2'b01;
    step();
    alloc_req = 0;
    alloc_take = 0;
    assert (!free_bits[32]);

    // Repeated single allocations alternate parity while both banks are free,
    // preserving dual-allocation headroom instead of draining even first.
    rebuild_valid = 1;
    rebuild_free_mask = (64'b1 << 34) | (64'b1 << 35) |
                        (64'b1 << 36) | (64'b1 << 37);
    step();
    rebuild_valid = 0;
    alloc_req = 2'b01; alloc_take = 2'b01; #1;
    assert (alloc_preg[0] == 6'd35)
      else $fatal(1, "single-allocation parity did not rotate to odd");
    step(); #1;
    assert (alloc_preg[0] == 6'd34)
      else $fatal(1, "single-allocation parity did not rotate to even");
    step(); alloc_req = 0; alloc_take = 0;

    // With only one parity bank free, lane1 is deliberately deferred.
    rebuild_valid = 1;
    rebuild_free_mask = (64'b1 << 32) | (64'b1 << 34);
    step();
    rebuild_valid = 0;
    alloc_req = 2'b11;
    alloc_take = 2'b01;
    #1;
    assert (alloc_gnt == 2'b01);
    assert (alloc_preg[0] == 6'd32);
    assert (bank_conflict);
    step();
    alloc_req = 0;
    alloc_take = 0;
    assert (!free_bits[0]);

    $display("PASS tb_free_bitmap");
    $finish;
  end
endmodule
