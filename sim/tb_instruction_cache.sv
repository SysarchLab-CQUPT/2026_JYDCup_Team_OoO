`timescale 1ns/1ps
module tb_instruction_cache;
  logic clk, rst_n, flush;
  logic core_req_valid, core_req_ready;
  logic [31:0] core_req_addr;
  logic [3:0] core_req_epoch;
  logic core_rsp_valid, core_rsp_ready, core_rsp_error;
  logic [31:0] core_rsp_addr;
  logic [3:0] core_rsp_epoch;
  logic [63:0] core_rsp_data;
  logic mem_req_valid, mem_req_ready;
  logic [31:0] mem_req_addr;
  logic mem_rsp_valid, mem_rsp_error;
  logic [63:0] mem_rsp_data;
  logic [63:0] memory [0:255];
  int unsigned memory_reads;

  instruction_cache dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .core_req_valid_i(core_req_valid), .core_req_ready_o(core_req_ready),
    .core_req_addr_i(core_req_addr), .core_req_epoch_i(core_req_epoch),
    .core_rsp_valid_o(core_rsp_valid), .core_rsp_ready_i(core_rsp_ready),
    .core_rsp_addr_o(core_rsp_addr), .core_rsp_epoch_o(core_rsp_epoch),
    .core_rsp_data_o(core_rsp_data), .core_rsp_error_o(core_rsp_error),
    .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready),
    .mem_req_addr_o(mem_req_addr), .mem_rsp_valid_i(mem_rsp_valid),
    .mem_rsp_data_i(mem_rsp_data), .mem_rsp_error_i(mem_rsp_error)
  );

  always #5 clk = ~clk;
  assign mem_req_ready = 1'b1;

  always @(posedge clk) begin
    mem_rsp_valid <= mem_req_valid && mem_req_ready;
    mem_rsp_error <= 1'b0;
    if (mem_req_valid && mem_req_ready) begin
      mem_rsp_data <= memory[mem_req_addr >> 3];
      memory_reads <= memory_reads + 1;
    end
  end

  task automatic fetch_word(input logic [31:0] addr, input logic [63:0] expected);
    @(negedge clk);
    core_req_valid = 1'b1;
    core_req_addr = addr;
    while (!core_req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    core_req_valid = 1'b0;
    while (!core_rsp_valid) @(negedge clk);
    assert (!core_rsp_error && (core_rsp_addr == addr) &&
           (core_rsp_epoch == core_req_epoch) && (core_rsp_data == expected))
      else $fatal(1, "I-cache addr=%08x expected=%016x got=%016x error=%0b",
                  addr, expected, core_rsp_data, core_rsp_error);
  endtask

  initial begin
    #5000 $fatal(1, "I-cache test timeout");
  end

  initial begin
    clk = 0; rst_n = 0; flush = 0; core_req_valid = 0; core_req_addr = 0;
    core_req_epoch = 4'h3; core_rsp_ready = 1;
    mem_rsp_valid = 0; mem_rsp_error = 0; mem_rsp_data = 0; memory_reads = 0;
    for (int unsigned i = 0; i < 256; i++)
      memory[i] = {32'hc000_0000 + i, 32'ha000_0000 + i};
    repeat (3) @(posedge clk);
    rst_n = 1;

    fetch_word(32'h0000_0038, memory[7]);
    assert (memory_reads == 4) else $fatal(1, "cold I-cache line used %0d reads", memory_reads);
    fetch_word(32'h0000_0030, memory[6]);
    assert (memory_reads == 4) else $fatal(1, "I-cache hit touched backing memory");

    // Two cached requests must be accepted on consecutive clocks and return
    // in order on consecutive clocks with their independent PC/epoch tags.
    @(negedge clk);
    core_req_valid = 1'b1;
    core_req_addr = 32'h0000_0030;
    core_req_epoch = 4'h5;
    assert (core_req_ready) else $fatal(1, "first pipelined hit not accepted");
    @(posedge clk);
    @(negedge clk);
    core_req_addr = 32'h0000_0038;
    core_req_epoch = 4'h6;
    assert (core_req_ready) else $fatal(1, "second consecutive hit not accepted");
    @(posedge clk);
    @(negedge clk);
    core_req_valid = 1'b0;
    assert (core_rsp_valid && core_rsp_addr == 32'h0000_0030 &&
            core_rsp_epoch == 4'h5 && core_rsp_data == memory[6])
      else $fatal(1, "first pipelined response metadata/data mismatch");
    @(posedge clk);
    @(negedge clk);
    assert (core_rsp_valid && core_rsp_addr == 32'h0000_0038 &&
            core_rsp_epoch == 4'h6 && core_rsp_data == memory[7])
      else $fatal(1, "second pipelined response metadata/data mismatch");

    // Hold a response for two clocks and verify every payload field is stable.
    @(posedge clk);
    @(negedge clk);
    core_rsp_ready = 1'b0;
    core_req_valid = 1'b1;
    core_req_addr = 32'h0000_0030;
    core_req_epoch = 4'h9;
    assert (core_req_ready) else $fatal(1, "backpressure test request not accepted");
    @(posedge clk);
    @(negedge clk); core_req_valid = 1'b0;
    @(posedge clk);
    @(negedge clk);
    assert (core_rsp_valid && core_rsp_addr == 32'h0000_0030 &&
            core_rsp_epoch == 4'h9 && core_rsp_data == memory[6])
      else $fatal(1, "response missing before backpressure hold");
    repeat (2) begin
      @(posedge clk);
      @(negedge clk);
      assert (core_rsp_valid && core_rsp_addr == 32'h0000_0030 &&
              core_rsp_epoch == 4'h9 && core_rsp_data == memory[6])
        else $fatal(1, "response changed while ready was low");
    end
    core_rsp_ready = 1'b1;
    @(posedge clk);

    @(negedge clk); flush = 1;
    @(posedge clk); @(negedge clk); flush = 0;
    fetch_word(32'h0000_0038, memory[7]);
    assert (memory_reads == 8) else $fatal(1, "I-cache flush did not force refill");
    $display("PASS tb_instruction_cache");
    $finish;
  end
endmodule
