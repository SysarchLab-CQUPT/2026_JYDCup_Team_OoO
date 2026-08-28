`timescale 1ns/1ps
module tb_rv32_alu;
  import rv32_pkg::*;
  uop_op_e op;
  logic [31:0] pc;
  logic [31:0] a;
  logic [31:0] b;
  logic [31:0] imm;
  logic [31:0] result;
  logic control_flow;
  logic taken;
  logic [31:0] target;

  rv32_alu dut (
    .op_i(op), .pc_i(pc), .rs1_i(a), .rs2_i(b), .imm_i(imm),
    .result_o(result), .control_flow_o(control_flow),
    .taken_o(taken), .target_o(target)
  );

  task automatic check_result(
    input uop_op_e check_op,
    input logic [31:0] check_a,
    input logic [31:0] check_b,
    input logic [31:0] check_imm,
    input logic [31:0] expected
  );
    op = check_op; a = check_a; b = check_b; imm = check_imm;
    #1;
    assert (result == expected)
      else $fatal(1, "ALU op=%0d got=%08x expected=%08x", check_op, result, expected);
  endtask

  initial begin
    pc = 32'h0000_1000;
    check_result(UOP_ADD, 32'hffff_ffff, 32'd1, 0, 0);
    check_result(UOP_SUB, 32'd3, 32'd7, 0, 32'hffff_fffc);
    check_result(UOP_SLT, 32'hffff_ffff, 32'd1, 0, 1);
    check_result(UOP_SLTU, 32'hffff_ffff, 32'd1, 0, 0);
    check_result(UOP_SRAI, 32'h8000_0000, 0, 32'd4, 32'hf800_0000);
    check_result(UOP_SH1ADD, 32'd7, 32'd5, 0, 32'd19);
    check_result(UOP_SH2ADD, 32'd7, 32'd5, 0, 32'd33);
    check_result(UOP_SH3ADD, 32'd7, 32'd5, 0, 32'd61);

    op = UOP_BEQ; a = 32'd5; b = 32'd5; imm = 32'hffff_fff8; #1;
    assert (control_flow && taken && target == 32'h0000_0ff8)
      else $fatal(1, "BEQ target");

    op = UOP_BLT; a = 32'hffff_ffff; b = 32'd0; imm = 32'd12; #1;
    assert (taken && target == 32'h0000_100c) else $fatal(1, "BLT signed");

    op = UOP_JALR; a = 32'h0000_2001; imm = 32'd4; #1;
    assert (taken && target == 32'h0000_2004 && result == 32'h0000_1004)
      else $fatal(1, "JALR alignment/link");
    $display("PASS tb_rv32_alu");
    $finish;
  end
endmodule
