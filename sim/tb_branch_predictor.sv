`timescale 1ns/1ps
module tb_branch_predictor;
  logic clk, rst_n;
  logic [1:0] q_valid;
  logic [31:0] q_pc [2], q_target [2];
  logic [1:0] q_taken, q_hit;
  logic [10:0] spec_ghr;
  logic [1:0] d_valid, d_cp_valid, d_branch, d_call, d_return, d_taken;
  logic [3:0] d_cp_id [2];
  logic [31:0] d_pc [2];
  logic resolve_valid, resolve_taken, resolve_branch, resolve_jalr;
  logic resolve_call, resolve_return, resolve_trap, resolve_mispredict, resolve_cp_valid;
  logic [31:0] resolve_pc, resolve_target;
  logic [3:0] resolve_cp_id;
  logic release_valid;
  logic [3:0] release_id;
  logic [1:0] c_valid, c_branch, c_taken, c_call, c_return;
  logic [31:0] c_pc [2];
  logic global_flush, invalidate;

  branch_predictor dut (
    .clk_i(clk), .rst_ni(rst_n), .query_valid_i(q_valid), .query_pc_i(q_pc),
    .query_taken_o(q_taken),
    .query_target_o(q_target), .query_btb_hit_o(q_hit),
    .speculative_ghr_o(spec_ghr), .dispatch_valid_i(d_valid),
    .dispatch_checkpoint_valid_i(d_cp_valid), .dispatch_checkpoint_id_i(d_cp_id),
    .dispatch_pc_i(d_pc), .dispatch_is_branch_i(d_branch),
    .dispatch_is_call_i(d_call), .dispatch_is_return_i(d_return),
    .dispatch_pred_taken_i(d_taken), .resolve_valid_i(resolve_valid),
    .resolve_pc_i(resolve_pc), .resolve_target_i(resolve_target),
    .resolve_actual_taken_i(resolve_taken), .resolve_is_branch_i(resolve_branch),
    .resolve_is_jalr_i(resolve_jalr), .resolve_is_call_i(resolve_call),
    .resolve_is_return_i(resolve_return), .resolve_trap_i(resolve_trap),
    .resolve_mispredict_i(resolve_mispredict),
    .resolve_checkpoint_valid_i(resolve_cp_valid),
    .resolve_checkpoint_id_i(resolve_cp_id), .release_valid_i(release_valid),
    .release_checkpoint_id_i(release_id), .commit_valid_i(c_valid),
    .commit_pc_i(c_pc), .commit_is_branch_i(c_branch),
    .commit_actual_taken_i(c_taken), .commit_is_call_i(c_call),
    .commit_is_return_i(c_return), .global_flush_i(global_flush),
    .invalidate_i(invalidate)
  );

  always #5 clk = ~clk;

  task automatic clear_cycle_inputs;
    q_valid = 0;
    d_valid = 0; d_cp_valid = 0; d_branch = 0; d_call = 0; d_return = 0; d_taken = 0;
    resolve_valid = 0; resolve_taken = 0; resolve_branch = 0;
    resolve_jalr = 0;
    resolve_call = 0; resolve_return = 0; resolve_trap = 0;
    resolve_mispredict = 0; resolve_cp_valid = 0; resolve_cp_id = 0;
    release_valid = 0; release_id = 0; c_valid = 0; c_branch = 0;
    c_taken = 0; c_call = 0; c_return = 0; global_flush = 0; invalidate = 0;
  endtask

  initial begin
    #3000 $fatal(1, "branch predictor test timeout");
  end

  initial begin
    clk = 0; rst_n = 0; clear_cycle_inputs();
    q_pc[0] = 32'h100; q_pc[1] = 32'h104;
    d_pc[0] = 0; d_pc[1] = 0; d_cp_id[0] = 0; d_cp_id[1] = 0;
    c_pc[0] = 0; c_pc[1] = 0;
    repeat (3) @(posedge clk); rst_n = 1; @(negedge clk);

    // Cold conditional branches are weak-not-taken and require a BTB hit.
    q_valid[0] = 1;
    #1; assert (!q_taken[0] && !q_hit[0]) else $fatal(1, "cold branch predicted taken");

    // Capture history, then resolve taken. One update moves 01 -> 10.
    d_valid[0] = 1; d_cp_valid[0] = 1; d_cp_id[0] = 3'd0;
    d_pc[0] = 32'h100; d_branch[0] = 1; d_taken[0] = 0;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    // Snapshot payload/address cross the dedicated predictor write boundary;
    // a real branch cannot resolve until after issue and execute either.
    @(posedge clk); @(negedge clk);
    resolve_valid = 1; resolve_pc = 32'h100; resolve_target = 32'h180;
    resolve_taken = 1; resolve_branch = 1; resolve_mispredict = 1;
    resolve_cp_valid = 1; resolve_cp_id = 3'd0;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    assert (spec_ghr == 11'd1) else $fatal(1, "mispredict history recovery failed");
    global_flush = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    q_valid[0] = 1; q_pc[0] = 32'h100;
    #1; assert (q_hit[0] && q_taken[0] && q_target[0] == 32'h180)
      else $fatal(1, "trained branch prediction failed");

    // A direct call pushes PC+4; a decoded return uses the 16-entry RAS.
    clear_cycle_inputs();
    d_valid[0] = 1; d_pc[0] = 32'h300; d_call[0] = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    // Fetch-time return prediction is gated by a typed BTB record.
    resolve_valid = 1; resolve_pc = 32'h500; resolve_target = 32'h304;
    resolve_taken = 1; resolve_jalr = 1; resolve_return = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    @(posedge clk); @(negedge clk);
    q_valid[0] = 1; q_pc[0] = 32'h500;
    #1; assert (q_taken[0] && q_target[0] == 32'h304)
      else $fatal(1, "RAS return prediction failed");

    // Seed the architectural RAS and restore it into the speculative copy.
    // A precise interrupt/fence-style flush must see a call committed in the
    // same cycle rather than the pre-commit stack image.
    clear_cycle_inputs();
    c_valid[0] = 1; c_call[0] = 1; c_pc[0] = 32'h600;
    global_flush = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    q_valid[0] = 1; q_pc[0] = 32'h500;
    #1; assert (q_taken[0] && q_target[0] == 32'h604)
      else $fatal(1, "same-cycle commit/flush RAS restore failed");

    // A return and the target's call can retire together.  They must be
    // folded lane0 then lane1: pop 0x604 and replace it with 0x704.  The old
    // single-event else-if implementation lost lane1 and predicted below the
    // interrupted UART call.
    clear_cycle_inputs();
    c_valid = 2'b11; c_return[0] = 1; c_call[1] = 1;
    c_pc[1] = 32'h700; global_flush = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    q_valid[0] = 1; q_pc[0] = 32'h500;
    #1; assert (q_taken[0] && q_target[0] == 32'h704)
      else $fatal(1, "dual-retire RAS program-order fold failed");

    // FENCE.I invalidates stale BTB state without disturbing legal execution.
    clear_cycle_inputs(); invalidate = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    q_valid[0] = 1; q_pc[0] = 32'h100;
    #1; assert (!q_hit[0] && !q_taken[0]) else $fatal(1, "BTB invalidate failed");

    // Invalidate must also cancel a training record waiting at the new local
    // write boundary; it may not repopulate the BTB on the following cycle.
    clear_cycle_inputs();
    resolve_valid = 1; resolve_pc = 32'h200; resolve_target = 32'h280;
    resolve_taken = 1; resolve_branch = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    invalidate = 1;
    @(posedge clk); @(negedge clk); clear_cycle_inputs();
    q_valid[0] = 1; q_pc[0] = 32'h200;
    #1; assert (!q_hit[0] && !q_taken[0])
      else $fatal(1, "pending BTB training survived invalidate");

    $display("PASS tb_branch_predictor");
    $finish;
  end
endmodule
