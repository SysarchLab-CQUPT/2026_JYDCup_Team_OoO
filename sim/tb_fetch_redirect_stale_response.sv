`timescale 1ns/1ps
module tb_fetch_redirect_stale_response;
  import core_types_pkg::*;

  logic clk, rst_n;
  logic imem_req_valid, imem_req_ready;
  logic [31:0] imem_req_addr;
  logic [3:0] imem_req_epoch;
  logic imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
  logic [31:0] imem_rsp_addr;
  logic [3:0] imem_rsp_epoch;
  logic [63:0] imem_rsp_data;
  logic icache_flush, dcache_clean_req;
  logic dmem_req_valid, dmem_req_ready, dmem_req_write;
  logic [31:0] dmem_req_addr, dmem_req_wdata, dmem_rsp_data;
  logic [3:0] dmem_req_wstrb, dmem_req_seq, dmem_rsp_seq;
  uop_id_t dmem_req_uop_id, dmem_rsp_uop_id;
  logic dmem_rsp_valid, dmem_rsp_error;
  commit_trace_t trace [2];
  logic [31:0] debug_pc;
  logic [5:0] debug_rob_count;
  logic [3:0] old_epoch, new_epoch;
  int unsigned phase;

  ooo_core dut (
    .clk_i(clk), .rst_ni(rst_n),
    .imem_req_valid_o(imem_req_valid), .imem_req_ready_i(imem_req_ready),
    .imem_req_addr_o(imem_req_addr), .imem_req_epoch_o(imem_req_epoch),
    .imem_rsp_valid_i(imem_rsp_valid), .imem_rsp_ready_o(imem_rsp_ready),
    .imem_rsp_addr_i(imem_rsp_addr), .imem_rsp_epoch_i(imem_rsp_epoch),
    .imem_rsp_data_i(imem_rsp_data), .imem_rsp_error_i(imem_rsp_error),
    .icache_flush_o(icache_flush), .dcache_idle_i(1'b1),
    .dcache_clean_req_o(dcache_clean_req), .dcache_clean_done_i(1'b1),
    .dmem_req_valid_o(dmem_req_valid), .dmem_req_ready_i(dmem_req_ready),
    .dmem_req_write_o(dmem_req_write), .dmem_req_addr_o(dmem_req_addr),
    .dmem_req_wdata_o(dmem_req_wdata), .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_req_seq_o(dmem_req_seq), .dmem_req_uop_id_o(dmem_req_uop_id),
    .dmem_rsp_valid_i(dmem_rsp_valid), .dmem_rsp_data_i(dmem_rsp_data),
    .dmem_rsp_error_i(dmem_rsp_error), .dmem_rsp_seq_i(dmem_rsp_seq),
    .dmem_rsp_uop_id_i(dmem_rsp_uop_id), .timer_irq_i(1'b0),
    .external_irq_i(1'b0), .commit_trace_o(trace),
    .debug_pc_o(debug_pc), .debug_rob_count_o(debug_rob_count)
  );

  always #5 clk = ~clk;
  assign dmem_req_ready = 1'b1;

  initial begin
    repeat (200) @(posedge clk);
    $fatal(1,
      "stale-response timeout phase=%0d pc=%08x epoch=%0h inflight=%0d queue=%0d req=%0b/%0b rsp=%0b/%0b",
      phase, dut.fetch_pc_q, dut.fetch_epoch_q, dut.fetch_inflight_count_q,
      dut.fetch_queue_count, imem_req_valid, imem_req_ready,
      imem_rsp_valid, imem_rsp_ready);
  end

  initial begin
    clk = 1'b0;
    phase = 0;
    rst_n = 1'b0;
    imem_req_ready = 1'b0;
    imem_rsp_valid = 1'b0;
    imem_rsp_addr = '0;
    imem_rsp_epoch = '0;
    imem_rsp_data = '0;
    imem_rsp_error = 1'b0;
    dmem_rsp_valid = 1'b0;
    dmem_rsp_data = '0;
    dmem_rsp_error = 1'b0;
    dmem_rsp_seq = '0;
    dmem_rsp_uop_id = '0;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    // Accept exactly one reset-vector request and retain its PC/epoch tag.
    wait (imem_req_valid && (imem_req_addr == 32'h0000_0000));
    phase = 1;
    old_epoch = imem_req_epoch;
    @(negedge clk); imem_req_ready = 1'b1;
    @(posedge clk); #1;
    imem_req_ready = 1'b0;
    assert (dut.fetch_inflight_count_q == 1)
      else $fatal(1, "initial request credit was not recorded");

    // Redirect to an upper half of a 64-bit fetch word.  This is the exact
    // JALR target shape that previously skipped PC+4 in CoreMark.
    @(negedge clk);
    force dut.redirect_valid = 1'b1;
    force dut.redirect_target = 32'h0000_0044;
    phase = 2;
    @(posedge clk); #1;
    new_epoch = dut.fetch_epoch_q;
    assert ((new_epoch != old_epoch) && (dut.fetch_pc_q == 32'h0000_0044))
      else $fatal(1, "redirect did not install upper-word PC/new epoch");
    @(negedge clk);
    force dut.redirect_valid = 1'b0;

    // The old response must handshake and release credit, but never enqueue.
    imem_rsp_valid = 1'b1;
    imem_rsp_addr = 32'h0000_0000;
    imem_rsp_epoch = old_epoch;
    imem_rsp_data = 64'hdead_beef_cafe_babe;
    phase = 3;
    assert (imem_rsp_ready)
      else $fatal(1, "stale epoch response was not drainable");
    @(posedge clk); #1;
    assert ((dut.fetch_inflight_count_q == 0) && !dut.fetch_buffer_valid_q)
      else $fatal(1, "stale response changed redirected fetch state");
    @(negedge clk); imem_rsp_valid = 1'b0;

    // Issue and return the redirected request with its explicit metadata.
    imem_req_ready = 1'b1;
    wait (imem_req_valid);
    phase = 4;
    assert ((imem_req_addr == 32'h0000_0044) &&
            (imem_req_epoch == new_epoch))
      else $fatal(1, "redirected request metadata was wrong");
    @(posedge clk); #1;
    imem_req_ready = 1'b0;

    @(negedge clk);
    imem_rsp_valid = 1'b1;
    imem_rsp_addr = 32'h0000_0044;
    imem_rsp_epoch = new_epoch;
    imem_rsp_data = 64'h0000_0013_1234_5678;
    phase = 5;
    @(posedge clk); #1;
    assert (dut.fetch_buffer_valid_q &&
            (dut.fetch_buffer_pc_q == 32'h0000_0044) &&
            (dut.fetch_inst[0] == 32'h0000_0013))
      else $fatal(1, "upper-word redirect response lost or selected lower word");

    release dut.redirect_valid;
    release dut.redirect_target;
    $display("PASS tb_fetch_redirect_stale_response");
    $finish;
  end
endmodule
