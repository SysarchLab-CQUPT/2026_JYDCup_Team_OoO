`timescale 1ns/1ps
module tb_store_queue;
  import core_types_pkg::*;

  logic clk, rst_n;
  logic [1:0] alloc_valid, alloc_accept;
  rob_ptr_t alloc_rob_ptr [2];
  uop_id_t alloc_uop_id [2];
  logic [3:0] alloc_seq [2];
  logic execute_valid;
  logic [3:0] execute_seq;
  uop_id_t execute_uop_id;
  logic [31:0] execute_addr, execute_data;
  logic [3:0] execute_mask;
  logic [7:0] addr_done_onehot;
  logic commit_valid;
  logic commit_remove;
  logic [3:0] commit_seq;
  logic recovery_valid;
  logic [3:0] recovery_tail;
  logic drain_valid, drain_ready;
  logic [31:0] drain_addr, drain_data;
  logic [3:0] drain_mask, drain_seq;
  logic query_valid;
  logic [31:0] query_addr;
  logic [3:0] query_mask, query_older_tail;
  logic [3:0] query_forward_mask;
  logic [31:0] query_forward_data;
  logic query_forward_ready;
  logic [7:0] addr_not_ready;
  logic [3:0] head, commit_tail, alloc_tail, count;
  logic committed_empty;

  store_queue dut (
    .clk_i(clk), .rst_ni(rst_n), .alloc_valid_i(alloc_valid),
    .alloc_uop_id_i(alloc_uop_id),
    .alloc_accept_o(alloc_accept), .alloc_seq_o(alloc_seq),
    .execute_valid_i(execute_valid), .execute_seq_i(execute_seq),
    .execute_uop_id_i(execute_uop_id), .execute_addr_i(execute_addr),
    .execute_data_i(execute_data), .execute_mask_i(execute_mask),
    .addr_done_onehot_o(addr_done_onehot), .commit_valid_i(commit_valid),
    .commit_seq_i(commit_seq), .commit_remove_i(commit_remove),
    .recovery_valid_i(recovery_valid),
    .recovery_alloc_tail_i(recovery_tail), .drain_valid_o(drain_valid),
    .drain_ready_i(drain_ready), .drain_addr_o(drain_addr),
    .drain_data_o(drain_data), .drain_mask_o(drain_mask),
    .drain_seq_o(drain_seq), .query_valid_i(query_valid),
    .query_addr_i(query_addr), .query_mask_i(query_mask),
    .query_older_tail_i(query_older_tail),
    .query_forward_mask_o(query_forward_mask),
    .query_forward_data_o(query_forward_data),
    .query_forward_ready_o(query_forward_ready),
    .addr_not_ready_mask_o(addr_not_ready), .head_o(head),
    .commit_tail_o(commit_tail), .alloc_tail_o(alloc_tail),
    .count_o(count), .committed_empty_o(committed_empty)
  );

  always #5 clk = ~clk;

  task automatic allocate_two;
    @(negedge clk);
    alloc_valid = 2'b11;
    alloc_rob_ptr[0] = 6'd4;
    alloc_rob_ptr[1] = 6'd5;
    alloc_uop_id[0] = 8'h14;
    alloc_uop_id[1] = 8'h15;
    #1;
    assert (alloc_accept == 2'b11 && alloc_seq[0] == 0 && alloc_seq[1] == 1)
      else $fatal(1, "SQ dual allocation sequence incorrect");
    @(posedge clk);
    @(negedge clk);
    alloc_valid = '0;
  endtask

  task automatic execute_store(
    input logic [3:0] seq,
    input uop_id_t id,
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0] mask
  );
    @(negedge clk);
    execute_valid = 1'b1;
    execute_seq = seq;
    execute_uop_id = id;
    execute_addr = addr;
    execute_data = data;
    execute_mask = mask;
    #1;
    assert (addr_done_onehot[seq[2:0]]) else $fatal(1, "SQ execute identity rejected");
    @(posedge clk);
    @(negedge clk);
    execute_valid = 1'b0;
  endtask

  task automatic commit_store(input logic [3:0] seq);
    @(negedge clk);
    commit_valid = 1'b1;
    commit_seq = seq;
    @(posedge clk);
    @(negedge clk);
    commit_valid = 1'b0;
  endtask

  initial begin
    #5000 $fatal(1, "SQ test timeout");
  end

  initial begin
    clk = 0; rst_n = 0; alloc_valid = 0; execute_valid = 0;
    commit_valid = 0; commit_remove = 0; commit_seq = 0;
    recovery_valid = 0; recovery_tail = 0;
    drain_ready = 0; query_valid = 0; query_addr = 0; query_mask = 0;
    query_older_tail = 0; execute_seq = 0; execute_uop_id = 0;
    execute_addr = 0; execute_data = 0; execute_mask = 0;
    alloc_rob_ptr[0] = 0; alloc_rob_ptr[1] = 0;
    alloc_uop_id[0] = 0; alloc_uop_id[1] = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    allocate_two();
    assert (count == 2 && addr_not_ready[1:0] == 2'b11)
      else $fatal(1, "SQ allocation occupancy/pending mask incorrect");

    execute_store(0, 8'h14, 32'h100, 32'h1122_3344, 4'b1111);
    execute_store(1, 8'h15, 32'h101, 32'h0000_aa00, 4'b0010);
    query_valid = 1'b1;
    query_addr = 32'h100;
    query_mask = 4'b1111;
    query_older_tail = 4'd2;
    #1;
    assert (query_forward_ready && query_forward_mask == 4'b1111 &&
            query_forward_data == 32'h1122_aa44)
      else $fatal(1, "SQ youngest-older byte forwarding incorrect: %x/%x",
                  query_forward_mask, query_forward_data);
    query_valid = 1'b0;

    commit_store(0);
    commit_store(1);
    assert (!committed_empty && drain_valid && drain_seq == 0 &&
            drain_data == 32'h1122_3344)
      else $fatal(1, "SQ committed drain head incorrect");
    drain_ready = 1'b1;
    @(posedge clk); @(negedge clk);
    assert (drain_valid && drain_seq == 1 && drain_data == 32'h0000_aa00)
      else $fatal(1, "SQ drain order incorrect");
    @(posedge clk); @(negedge clk);
    drain_ready = 1'b0;
    assert (count == 0 && committed_empty) else $fatal(1, "SQ did not drain empty");

    // Three speculative entries: commit the first and recover the other two.
    @(negedge clk);
    alloc_valid = 2'b11;
    alloc_rob_ptr[0] = 6'd8; alloc_rob_ptr[1] = 6'd9;
    alloc_uop_id[0] = 8'h28; alloc_uop_id[1] = 8'h29;
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    execute_store(2, 8'h28, 32'h120, 32'haaaa_0001, 4'hf);
    execute_store(3, 8'h29, 32'h124, 32'hbbbb_0002, 4'hf);
    commit_store(2);
    @(negedge clk);
    alloc_valid = 2'b10;
    alloc_rob_ptr[1] = 6'd10; alloc_uop_id[1] = 8'h2a;
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    assert (alloc_tail == 5) else $fatal(1, "SQ lane1-only allocation failed");
    recovery_tail = 4'd3;
    recovery_valid = 1'b1;
    @(posedge clk); @(negedge clk); recovery_valid = 1'b0;
    assert (alloc_tail == 3 && commit_tail == 3 && count == 1 && drain_seq == 2)
      else $fatal(1, "SQ recovery damaged committed prefix");
    drain_ready = 1'b1;
    @(posedge clk); @(negedge clk); drain_ready = 1'b0;
    assert (count == 0) else $fatal(1, "SQ committed recovery survivor did not drain");

    $display("PASS tb_store_queue");
    $finish;
  end
endmodule
