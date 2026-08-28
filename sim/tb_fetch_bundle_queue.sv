`timescale 1ns/1ps
module tb_fetch_bundle_queue;
  logic clk, rst_n, flush;
  logic enq_valid, enq_ready;
  logic [31:0] enq_pc;
  logic [63:0] enq_data;
  logic enq_error;
  rv32_pkg::decoded_instr_t enq_dec [2];
  logic [1:0] enq_pred_taken;
  logic [31:0] enq_pred_target [2];
  logic deq_valid, deq_pop, deq_advance;
  logic [31:0] deq_pc;
  logic [63:0] deq_data;
  logic deq_error;
  rv32_pkg::decoded_instr_t deq_dec [2];
  rv32_pkg::decoded_instr_t expected_dec [2];
  logic [1:0] deq_pred_taken;
  logic [31:0] deq_pred_target [2];
  logic [1:0] count;

  fetch_bundle_queue #(.DEPTH(2)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .enq_valid_i(enq_valid), .enq_ready_o(enq_ready),
    .enq_pc_i(enq_pc), .enq_data_i(enq_data), .enq_error_i(enq_error),
    .enq_dec_i(enq_dec),
    .enq_pred_taken_i(enq_pred_taken), .enq_pred_target_i(enq_pred_target),
    .deq_valid_o(deq_valid), .deq_pc_o(deq_pc), .deq_data_o(deq_data),
    .deq_error_o(deq_error), .deq_pred_taken_o(deq_pred_taken),
    .deq_dec_o(deq_dec),
    .deq_pred_target_o(deq_pred_target), .deq_pop_i(deq_pop),
    .deq_advance_i(deq_advance), .count_o(count)
  );

  always #5 clk = ~clk;

  task automatic drive(
    input logic push_i,
    input logic [31:0] pc_i,
    input logic [63:0] data_i,
    input logic error_i,
    input logic pop_i,
    input logic advance_i,
    input logic flush_i
  );
    begin
      @(negedge clk);
      enq_valid = push_i;
      enq_pc = pc_i;
      enq_data = data_i;
      enq_error = error_i;
      deq_pop = pop_i;
      deq_advance = advance_i;
      flush = flush_i;
      @(posedge clk);
      #1;
      enq_valid = 1'b0;
      deq_pop = 1'b0;
      deq_advance = 1'b0;
      flush = 1'b0;
    end
  endtask

  task automatic expect_head(
    input logic [1:0] expected_count,
    input logic [31:0] expected_pc,
    input logic [63:0] expected_data,
    input logic expected_error
  );
    begin
      assert (count == expected_count)
        else $fatal(1, "count=%0d expected=%0d", count, expected_count);
      assert (deq_valid == (expected_count != 0))
        else $fatal(1, "deq_valid mismatch count=%0d", expected_count);
      if (expected_count != 0) begin
        assert ((deq_pc == expected_pc) && (deq_data == expected_data) &&
                (deq_error == expected_error))
          else $fatal(1,
            "head mismatch pc=%08x/%08x data=%016x/%016x error=%0b/%0b",
            deq_pc, expected_pc, deq_data, expected_data,
            deq_error, expected_error);
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    flush = 1'b0;
    enq_valid = 1'b0;
    enq_pc = '0;
    enq_data = '0;
    enq_error = 1'b0;
    enq_dec[0] = '0;
    enq_dec[1] = '0;
    enq_pred_taken = '0;
    enq_pred_target[0] = '0;
    enq_pred_target[1] = '0;
    deq_pop = 1'b0;
    deq_advance = 1'b0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    #1;
    expect_head(0, '0, '0, 1'b0);
    assert (enq_ready) else $fatal(1, "empty queue was not ready");

    drive(1'b1, 32'h0000_0000, 64'haaaa_0001_aaaa_0000, 1'b0,
          1'b0, 1'b0, 1'b0);
    expect_head(1, 32'h0000_0000, 64'haaaa_0001_aaaa_0000, 1'b0);

    // Retain the upper instruction of the aligned head while appending the
    // next bundle in the same cycle.
    expected_dec[0] = '0;
    expected_dec[0].valid = 1'b1;
    expected_dec[0].op = rv32_pkg::UOP_CSRRW;
    expected_dec[0].rs1 = 5'd17;
    expected_dec[0].rd = 5'd29;
    expected_dec[0].imm = 32'h89ab_cdef;
    expected_dec[0].csr_addr = 12'hc00;
    expected_dec[0].uses_rs1 = 1'b1;
    expected_dec[0].rd_wen = 1'b1;
    expected_dec[0].is_csr = 1'b1;
    expected_dec[1] = '0;
    expected_dec[1].valid = 1'b1;
    expected_dec[1].op = rv32_pkg::UOP_LHU;
    expected_dec[1].rs1 = 5'd7;
    expected_dec[1].rd = 5'd3;
    expected_dec[1].imm = 32'hffff_fffe;
    expected_dec[1].uses_rs1 = 1'b1;
    expected_dec[1].rd_wen = 1'b1;
    expected_dec[1].is_load = 1'b1;
    expected_dec[1].mem_size = rv32_pkg::MEM_SIZE_H;
    expected_dec[1].mem_unsigned = 1'b1;
    enq_dec[0] = expected_dec[0];
    enq_dec[1] = expected_dec[1];
    drive(1'b1, 32'h0000_0008, 64'hbbbb_0003_bbbb_0002, 1'b1,
          1'b0, 1'b1, 1'b0);
    expect_head(2, 32'h0000_0004, 64'haaaa_0001_aaaa_0000, 1'b0);
    assert (!enq_ready) else $fatal(1, "full queue incorrectly reported room");

    drive(1'b0, '0, '0, 1'b0, 1'b1, 1'b0, 1'b0);
    expect_head(1, 32'h0000_0008, 64'hbbbb_0003_bbbb_0002, 1'b1);
    assert ((deq_dec[0] === expected_dec[0]) &&
            (deq_dec[1] === expected_dec[1]))
      else $fatal(1, "packed decoded rows were not preserved through RAM");

    drive(1'b1, 32'h0000_0010, 64'hcccc_0005_cccc_0004, 1'b0,
          1'b0, 1'b0, 1'b0);
    expect_head(2, 32'h0000_0008, 64'hbbbb_0003_bbbb_0002, 1'b1);

    // A full queue exposes the released slot on the following cycle.  This
    // keeps response ready independent of the live dispatch/pop decision.
    @(negedge clk);
    deq_pop = 1'b1;
    enq_valid = 1'b1;
    enq_pc = 32'h0000_0018;
    enq_data = 64'hdddd_0007_dddd_0006;
    enq_error = 1'b0;
    #1;
    assert (!enq_ready) else $fatal(1, "full pop leaked into enqueue ready");
    @(posedge clk);
    #1;
    enq_valid = 1'b0;
    deq_pop = 1'b0;
    expect_head(1, 32'h0000_0010, 64'hcccc_0005_cccc_0004, 1'b0);

    drive(1'b1, 32'h0000_0018, 64'hdddd_0007_dddd_0006, 1'b0,
          1'b0, 1'b0, 1'b0);
    expect_head(2, 32'h0000_0010, 64'hcccc_0005_cccc_0004, 1'b0);

    drive(1'b0, '0, '0, 1'b0, 1'b1, 1'b0, 1'b0);
    expect_head(1, 32'h0000_0018, 64'hdddd_0007_dddd_0006, 1'b0);

    drive(1'b0, '0, '0, 1'b0, 1'b0, 1'b0, 1'b1);
    expect_head(0, '0, '0, 1'b0);

    enq_pred_taken = 2'b10;
    enq_dec[0].op = rv32_pkg::UOP_ADD;
    enq_dec[1].op = rv32_pkg::UOP_SUB;
    enq_pred_target[0] = 32'h1111_1111;
    enq_pred_target[1] = 32'h2222_2222;
    drive(1'b1, 32'h0000_0040, 64'h0000_006f_dead_beef, 1'b0,
          1'b0, 1'b0, 1'b0);
    drive(1'b0, '0, '0, 1'b0, 1'b0, 1'b1, 1'b0);
    assert (deq_pred_taken == 2'b01 &&
            deq_pred_target[0] == 32'h2222_2222 &&
            deq_dec[0].op == rv32_pkg::UOP_SUB)
      else $fatal(1, "half-advance did not fold lane1 prediction metadata");
    drive(1'b0, '0, '0, 1'b0, 1'b0, 1'b0, 1'b1);

    // A redirect may begin at the upper word of an aligned 64-bit response.
    // Its explicit PC must be preserved so the core selects data[63:32].
    drive(1'b1, 32'h0000_0044, 64'h0000_0013_dead_beef, 1'b0,
          1'b0, 1'b0, 1'b0);
    expect_head(1, 32'h0000_0044, 64'h0000_0013_dead_beef, 1'b0);

    $display("PASS tb_fetch_bundle_queue");
    $finish;
  end
endmodule
