`timescale 1ns/1ps
module tb_muldiv_unit;
  import rv32_pkg::*;
  import core_types_pkg::*;

  logic clk;
  logic rst_n;
  logic req_valid;
  logic req_ready;
  uop_op_e req_op;
  logic [31:0] req_a;
  logic [31:0] req_b;
  uop_id_t req_id;
  logic rsp_valid;
  logic rsp_ready;
  logic [31:0] rsp_result;
  uop_id_t rsp_id;

  muldiv_unit dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_valid_i(req_valid), .req_ready_o(req_ready),
    .req_op_i(req_op), .req_a_i(req_a), .req_b_i(req_b),
    .req_uop_id_i(req_id), .rsp_valid_o(rsp_valid),
    .rsp_ready_i(rsp_ready), .rsp_result_o(rsp_result), .rsp_uop_id_o(rsp_id)
  );

  always #5 clk = ~clk;

  task automatic run_case(
    input uop_op_e op,
    input logic [31:0] a,
    input logic [31:0] b,
    input logic [31:0] expected,
    input uop_id_t id
  );
    @(negedge clk);
    assert (req_ready) else $fatal(1, "muldiv not ready before request");
    req_op = op; req_a = a; req_b = b; req_id = id; req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    while (!rsp_valid) @(negedge clk);
    assert (rsp_result == expected && rsp_id == id)
      else $fatal(1, "M op=%0d a=%08x b=%08x got=%08x expected=%08x id=%02x",
                  op, a, b, rsp_result, expected, rsp_id);
    @(posedge clk);
  endtask

  initial begin : watchdog
    repeat (500) @(posedge clk);
    $fatal(1, "tb_muldiv_unit exceeded 500 cycles");
  end

  initial begin
    clk = 0; rst_n = 0; req_valid = 0; req_op = UOP_MUL;
    req_a = 0; req_b = 0; req_id = 0; rsp_ready = 1;
    repeat (3) @(posedge clk);
    rst_n = 1;

    run_case(UOP_MUL, 32'hffff_fff9, 32'd9, 32'hffff_ffc1, 8'h01);
    run_case(UOP_MULH, 32'hffff_fffe, 32'd3, 32'hffff_ffff, 8'h02);
    run_case(UOP_MULHSU, 32'hffff_fffe, 32'h8000_0000, 32'hffff_ffff, 8'h03);
    run_case(UOP_MULHU, 32'hffff_ffff, 32'd2, 32'h0000_0001, 8'h04);
    run_case(UOP_DIV, 32'hffff_ffec, 32'd3, 32'hffff_fffa, 8'h05);
    run_case(UOP_REM, 32'hffff_ffec, 32'd3, 32'hffff_fffe, 8'h06);
    run_case(UOP_DIVU, 32'd20, 32'd3, 32'd6, 8'h07);
    run_case(UOP_REMU, 32'd20, 32'd3, 32'd2, 8'h08);
    run_case(UOP_DIV, 32'd123, 32'd0, 32'hffff_ffff, 8'h09);
    run_case(UOP_REMU, 32'h1234_5678, 32'd0, 32'h1234_5678, 8'h0a);
    run_case(UOP_DIV, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000, 8'h0b);
    run_case(UOP_REM, 32'h8000_0000, 32'hffff_ffff, 32'b0, 8'h0c);
    $display("PASS tb_muldiv_unit");
    $finish;
  end
endmodule
