`timescale 1ns/1ps
module tb_dmem_request_fifo;
  import core_types_pkg::*;

  logic clk, rst_n;
  logic enq_valid, enq_ready, enq_write, enq_fast;
  logic [31:0] enq_addr, enq_wdata;
  logic [3:0] enq_wstrb, enq_seq;
  uop_id_t enq_uop_id;
  logic deq_valid, deq_ready, deq_write;
  logic [31:0] deq_addr, deq_wdata;
  logic [3:0] deq_wstrb, deq_seq;
  uop_id_t deq_uop_id;
  logic empty;
  logic [1:0] count;

  dmem_request_fifo dut (
    .clk_i(clk), .rst_ni(rst_n), .enq_valid_i(enq_valid),
    .enq_ready_o(enq_ready), .enq_write_i(enq_write), .enq_addr_i(enq_addr),
    .enq_wdata_i(enq_wdata), .enq_wstrb_i(enq_wstrb), .enq_seq_i(enq_seq),
    .enq_uop_id_i(enq_uop_id),
    .enq_fast_load_i(enq_fast),
    .deq_valid_o(deq_valid),
    .deq_ready_i(deq_ready), .deq_write_o(deq_write), .deq_addr_o(deq_addr),
    .deq_wdata_o(deq_wdata), .deq_wstrb_o(deq_wstrb), .deq_seq_o(deq_seq),
    .deq_uop_id_o(deq_uop_id),
    .empty_o(empty), .count_o(count)
  );

  always #5 clk = ~clk;

  task automatic drive_request(
    input logic [31:0] addr,
    input logic [3:0] seq,
    input logic fast
  );
    enq_valid = 1'b1;
    enq_write = seq[0];
    enq_addr = addr;
    enq_wdata = {28'h1234567, seq};
    enq_wstrb = 4'b1010;
    enq_seq = seq;
    enq_uop_id = {4'ha, seq};
    enq_fast = fast;
  endtask

  initial begin
    #2000 $fatal(1, "dmem request FIFO test timeout");
  end

  initial begin
    clk = 0; rst_n = 0; enq_valid = 0; enq_write = 0;
    enq_addr = 0; enq_wdata = 0; enq_wstrb = 0; enq_seq = 0;
    enq_uop_id = 0; enq_fast = 0; deq_ready = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);

    // Empty requests fall through without consuming storage when ready.
    deq_ready = 1;
    drive_request(32'h080, 4'h0, 1'b1);
    #1;
    assert (deq_valid && deq_addr == 32'h080 && deq_seq == 4'h0 && empty)
      else $fatal(1, "empty FIFO did not fall through");
    @(posedge clk); @(negedge clk);
    enq_valid = 0;
    enq_fast = 0;
    deq_ready = 0;
    assert (empty && count == 0)
      else $fatal(1, "consumed fall-through request was buffered");

    drive_request(32'h100, 4'h1, 1'b0);
    assert (enq_ready) else $fatal(1, "empty FIFO was not ready");
    @(posedge clk); @(negedge clk);
    drive_request(32'h200, 4'h2, 1'b1);
    assert (deq_valid && deq_addr == 32'h100 && deq_seq == 4'h1)
      else $fatal(1, "FIFO head payload mismatch");
    @(posedge clk); @(negedge clk);
    enq_valid = 0;
    enq_fast = 0;
    assert (!enq_ready && count == 2)
      else $fatal(1, "full FIFO admission was not occupancy-only");

    // A same-cycle dequeue does not make a full queue combinationally ready.
    deq_ready = 1;
    #1;
    assert (!enq_ready) else $fatal(1, "FIFO reused a same-cycle dequeue slot");
    @(posedge clk); @(negedge clk);
    deq_ready = 0;
    assert (enq_ready && deq_valid && deq_addr == 32'h200 && count == 1)
      else $fatal(1, "FIFO did not expose the second request after dequeue");

    // With one resident entry, dequeue and enqueue sustain one transfer/cycle.
    drive_request(32'h300, 4'h3, 1'b0);
    deq_ready = 1;
    @(posedge clk); @(negedge clk);
    enq_valid = 0; enq_fast = 0; deq_ready = 0;
    assert (deq_valid && deq_addr == 32'h300 && count == 1)
      else $fatal(1, "simultaneous enqueue/dequeue ordering failed");
    deq_ready = 1;
    @(posedge clk); @(negedge clk);
    assert (empty && count == 0) else $fatal(1, "FIFO did not drain");

    $display("PASS tb_dmem_request_fifo");
    $finish;
  end
endmodule
