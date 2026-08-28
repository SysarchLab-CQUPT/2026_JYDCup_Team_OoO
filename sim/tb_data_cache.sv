`timescale 1ns/1ps
module tb_data_cache;
  logic clk, rst_n;
  logic core_req_valid, core_req_ready, core_req_write;
  logic [31:0] core_req_addr, core_req_wdata;
  logic [3:0] core_req_wstrb;
  logic [3:0] core_req_seq, core_rsp_seq;
  logic [7:0] core_req_uop_id, core_rsp_uop_id;
  logic core_rsp_valid, core_rsp_error;
  logic cache_idle;
  logic clean_req, clean_done;
  logic [31:0] core_rsp_data;
  logic mem_req_valid, mem_req_ready, mem_req_write;
  logic [31:0] mem_req_addr;
  logic [63:0] mem_req_wdata;
  logic [7:0] mem_req_wstrb;
  logic mem_rsp_valid, mem_rsp_error;
  logic [63:0] mem_rsp_data;
  logic [63:0] memory [0:8191];
  int unsigned memory_reads, memory_writes;
  int reads_before, writes_before;

  data_cache dut (
    .clk_i(clk), .rst_ni(rst_n),
    .core_load_valid_i(core_req_valid && !core_req_write),
    .core_load_addr_i(core_req_addr),
    .core_store_valid_i(core_req_valid && core_req_write),
    .core_store_addr_i(core_req_addr),
    .core_req_ready_o(core_req_ready), .core_req_wdata_i(core_req_wdata),
    .core_req_wstrb_i(core_req_wstrb), .core_req_seq_i(core_req_seq),
    .core_req_uop_id_i(core_req_uop_id), .core_rsp_valid_o(core_rsp_valid),
    .core_rsp_data_o(core_rsp_data), .core_rsp_error_o(core_rsp_error),
    .core_rsp_seq_o(core_rsp_seq), .core_rsp_uop_id_o(core_rsp_uop_id),
    .idle_o(cache_idle),
    .clean_req_i(clean_req), .clean_done_o(clean_done),
    .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready),
    .mem_req_write_o(mem_req_write), .mem_req_addr_o(mem_req_addr),
    .mem_req_wdata_o(mem_req_wdata), .mem_req_wstrb_o(mem_req_wstrb),
    .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_data_i(mem_rsp_data),
    .mem_rsp_error_i(mem_rsp_error)
  );

  always #5 clk = ~clk;
  assign mem_req_ready = 1'b1;

  always @(posedge clk) begin
    mem_rsp_valid <= mem_req_valid && mem_req_ready && !mem_req_write;
    mem_rsp_error <= 1'b0;
    if (mem_req_valid && mem_req_ready) begin
      if (mem_req_write) begin
        for (int unsigned byte_idx = 0; byte_idx < 8; byte_idx++)
          if (mem_req_wstrb[byte_idx])
            memory[mem_req_addr >> 3][byte_idx*8 +: 8] <=
              mem_req_wdata[byte_idx*8 +: 8];
        memory_writes <= memory_writes + 1;
      end else begin
        mem_rsp_data <= memory[mem_req_addr >> 3];
        memory_reads <= memory_reads + 1;
      end
    end
  end

  task automatic load_word(input logic [31:0] addr, input logic [31:0] expected);
    @(negedge clk);
    core_req_valid = 1; core_req_write = 0; core_req_addr = addr;
    while (!core_req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    core_req_valid = 0;
    while (!core_rsp_valid) @(negedge clk);
    assert (!core_rsp_error && (core_rsp_data == expected))
      else $fatal(1, "D-cache load addr=%08x expected=%08x got=%08x error=%0b",
                  addr, expected, core_rsp_data, core_rsp_error);
    assert (core_rsp_seq == core_req_seq && core_rsp_uop_id == core_req_uop_id)
      else $fatal(1, "D-cache response identity was not preserved");
  endtask

  task automatic store_word(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    core_req_valid = 1; core_req_write = 1; core_req_addr = addr;
    core_req_wdata = data; core_req_wstrb = 4'hf;
    while (!core_req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    core_req_valid = 0; core_req_write = 0;
  endtask

  task automatic send_load(
    input logic [31:0] addr,
    input logic [3:0] seq,
    input logic [7:0] id
  );
    @(negedge clk);
    core_req_valid = 1; core_req_write = 0; core_req_addr = addr;
    core_req_seq = seq; core_req_uop_id = id;
    while (!core_req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    core_req_valid = 0;
  endtask

  task automatic expect_response(
    input logic [3:0] seq,
    input logic [7:0] id,
    input logic [31:0] expected
  );
    while (!core_rsp_valid) @(negedge clk);
    assert (!core_rsp_error && core_rsp_seq == seq && core_rsp_uop_id == id &&
            core_rsp_data == expected)
      else $fatal(1, "D-cache response expected %x/%x/%x got %x/%x/%x err=%0b",
                  seq, id, expected, core_rsp_seq, core_rsp_uop_id,
                  core_rsp_data, core_rsp_error);
    @(posedge clk);
    @(negedge clk);
  endtask

  task automatic wait_idle;
    while (!cache_idle) @(negedge clk);
  endtask

  initial begin
    #10000 $fatal(1, "D-cache test timeout");
  end

  initial begin
    clk = 0; rst_n = 0; core_req_valid = 0; core_req_write = 0;
    core_req_addr = 0; core_req_wdata = 0; core_req_wstrb = 0;
    core_req_seq = 4'ha; core_req_uop_id = 8'h5a;
    clean_req = 1'b0;
    mem_rsp_valid = 0; mem_rsp_error = 0; mem_rsp_data = 0;
    memory_reads = 0; memory_writes = 0;
    for (int unsigned i = 0; i < 8192; i++)
      memory[i] = {32'hd000_0000 + i, 32'hb000_0000 + i};
    repeat (3) @(posedge clk);
    rst_n = 1;

    load_word(32'h0000_003c, 32'hd000_0007);
    assert (memory_reads == 4) else $fatal(1, "cold D-cache line used %0d reads", memory_reads);
    load_word(32'h0000_0030, 32'hb000_0006);
    assert (memory_reads == 4) else $fatal(1, "D-cache hit touched backing memory");

    store_word(32'h0000_0030, 32'h1234_5678);
    assert (memory_writes == 0 && memory[6][31:0] == 32'hb000_0006)
      else $fatal(1, "D-cache store hit was not write-back");
    load_word(32'h0000_0030, 32'h1234_5678);
    assert (memory_reads == 4) else $fatal(1, "store hit lost cache residency");

    store_word(32'h0000_1030, 32'hfeed_beef);
    wait_idle();
    assert (memory_reads == 8 && memory_writes == 0)
      else $fatal(1, "write-allocate store miss traffic incorrect");
    load_word(32'h0000_1030, 32'hfeed_beef);
    assert (memory_reads == 8) else $fatal(1, "write-allocate line did not hit");

    // A third tag in the same set evicts the dirty first way and writes all
    // four 64-bit beats back before refill.
    load_word(32'h0000_2030, memory[32'h2030 >> 3][31:0]);
    wait_idle();
    assert (memory_writes == 4 && memory[6][31:0] == 32'h1234_5678)
      else $fatal(1, "dirty victim writeback was incomplete");

    // Two different-set misses coexist.  The single backing engine services
    // them in order, while both identities remain resident in the MSHRs.
    reads_before = memory_reads;
    send_load(32'h0000_4000, 4'h1, 8'h81);
    send_load(32'h0000_4020, 4'h2, 8'h82);
    @(posedge clk); @(negedge clk);
    assert (dut.mshr_valid_q[0] && dut.mshr_valid_q[1])
      else $fatal(1, "D-cache did not record two concurrent misses");
    expect_response(4'h1, 8'h81, memory[32'h4000 >> 3][31:0]);
    expect_response(4'h2, 8'h82, memory[32'h4020 >> 3][31:0]);
    wait_idle();
    assert ((memory_reads - reads_before) == 8)
      else $fatal(1, "two MSHRs did not perform two line refills");

    // A second load to the same in-flight line uses the waiter instead of
    // allocating/refilling the line twice.
    reads_before = memory_reads;
    send_load(32'h0000_5000, 4'h3, 8'h83);
    send_load(32'h0000_5008, 4'h4, 8'h84);
    expect_response(4'h3, 8'h83, memory[32'h5000 >> 3][31:0]);
    expect_response(4'h4, 8'h84, memory[32'h5008 >> 3][31:0]);
    wait_idle();
    assert ((memory_reads - reads_before) == 4)
      else $fatal(1, "same-line load merge refilled more than once");

    // Two waiters consume the MSHR slots; a third same-line load remains in
    // the lookup register until install completes.  Prime both ways of the
    // same set so stale RAM data is deterministic and cannot masquerade as a
    // successful replay.
    load_word(32'h0000_6000, memory[32'h6000 >> 3][31:0]);
    load_word(32'h0000_7000, memory[32'h7000 >> 3][31:0]);
    reads_before = memory_reads;
    send_load(32'h0000_8000, 4'h5, 8'h85);
    send_load(32'h0000_8008, 4'h6, 8'h86);
    // Hold the third lookup on the final refill beat.  This is the worst-case
    // true-dual-port BRAM collision: the maintenance port installs beat 3
    // while the CPU port is trying to refresh the same beat.
    send_load(32'h0000_8018, 4'h7, 8'h87);
    expect_response(4'h5, 8'h85, memory[32'h8000 >> 3][31:0]);
    expect_response(4'h6, 8'h86, memory[32'h8008 >> 3][31:0]);
    expect_response(4'h7, 8'h87, memory[32'h8018 >> 3][31:0]);
    wait_idle();
    assert ((memory_reads - reads_before) == 4)
      else $fatal(1, "held same-line lookup performed an extra refill");

    // A store accepted while the preceding hit is returned must use the new
    // input address for its BRAM write, while the stable old BRAM output still
    // supplies the load response.  This checks the pipelined read/write port
    // handoff rather than requiring an artificial empty cycle.
    load_word(32'h0000_9000, memory[32'h9000 >> 3][31:0]);
    load_word(32'h0000_9020, memory[32'h9020 >> 3][31:0]);
    @(negedge clk);
    core_req_valid = 1'b1;
    core_req_write = 1'b0;
    core_req_addr = 32'h0000_9000;
    core_req_seq = 4'h8;
    core_req_uop_id = 8'h88;
    while (!core_req_ready) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    core_req_write = 1'b1;
    core_req_addr = 32'h0000_9020;
    core_req_wdata = 32'h1357_9bdf;
    core_req_wstrb = 4'hf;
    while (!core_req_ready) @(negedge clk);
    assert (core_rsp_valid && !core_rsp_error && core_rsp_seq == 4'h8 &&
            core_rsp_uop_id == 8'h88 &&
            core_rsp_data == memory[32'h9000 >> 3][31:0])
      else $fatal(1, "held store changed the in-flight load response");
    @(posedge clk);
    @(negedge clk);
    core_req_valid = 1'b0;
    core_req_write = 1'b0;
    load_word(32'h0000_9000, memory[32'h9000 >> 3][31:0]);
    load_word(32'h0000_9020, 32'h1357_9bdf);

    // FENCE.I clean walks both ways/sets and writes every dirty beat back.
    store_word(32'h0000_6020, 32'hcafe_1234);
    wait_idle();
    assert (memory[32'h6020 >> 3][31:0] != 32'hcafe_1234)
      else $fatal(1, "clean-test store unexpectedly reached backing memory");
    writes_before = memory_writes;
    @(negedge clk); clean_req = 1'b1;
    @(posedge clk); @(negedge clk); clean_req = 1'b0;
    while (!clean_done) @(negedge clk);
    assert (memory[32'h6020 >> 3][31:0] == 32'hcafe_1234 &&
            memory[32'h9020 >> 3][31:0] == 32'h1357_9bdf &&
            (memory_writes - writes_before) == 8)
      else $fatal(1, "D-cache clean failed data=%08x writes=%0d before=%0d dirty=%0b/%0b",
                  memory[32'h6020 >> 3][31:0], memory_writes,
                  writes_before, dut.dirty_q[0][1], dut.dirty_q[1][1]);
    $display("PASS tb_data_cache");
    $finish;
  end
endmodule
