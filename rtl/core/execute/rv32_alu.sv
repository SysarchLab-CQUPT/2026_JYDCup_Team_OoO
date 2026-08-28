`timescale 1ns/1ps
module rv32_alu (
  input  rv32_pkg::uop_op_e op_i,
  input  logic [31:0]       pc_i,
  input  logic [31:0]       rs1_i,
  input  logic [31:0]       rs2_i,
  input  logic [31:0]       imm_i,
  output logic [31:0]       result_o,
  output logic              control_flow_o,
  output logic              taken_o,
  output logic [31:0]       target_o
);
  import rv32_pkg::*;

  always_comb begin
    result_o = 32'b0;
    control_flow_o = 1'b0;
    taken_o = 1'b0;
    target_o = pc_i + 32'd4;

    unique case (op_i)
      UOP_LUI:   result_o = imm_i;
      UOP_AUIPC: result_o = pc_i + imm_i;
      UOP_JAL: begin
        result_o = pc_i + 32'd4;
        control_flow_o = 1'b1;
        taken_o = 1'b1;
        target_o = pc_i + imm_i;
      end
      UOP_JALR: begin
        result_o = pc_i + 32'd4;
        control_flow_o = 1'b1;
        taken_o = 1'b1;
        target_o = (rs1_i + imm_i) & 32'hffff_fffe;
      end
      UOP_BEQ, UOP_BNE, UOP_BLT, UOP_BGE, UOP_BLTU, UOP_BGEU: begin
        control_flow_o = 1'b1;
        unique case (op_i)
          UOP_BEQ:  taken_o = (rs1_i == rs2_i);
          UOP_BNE:  taken_o = (rs1_i != rs2_i);
          UOP_BLT:  taken_o = ($signed(rs1_i) < $signed(rs2_i));
          UOP_BGE:  taken_o = ($signed(rs1_i) >= $signed(rs2_i));
          UOP_BLTU: taken_o = (rs1_i < rs2_i);
          default:  taken_o = (rs1_i >= rs2_i);
        endcase
        // A conditional branch's encoded target is independent of the
        // operand comparison.  Keep the compare out of this 32-bit result
        // cone; the recovery block selects target/fallthrough at its existing
        // architectural boundary.
        target_o = pc_i + imm_i;
      end
      UOP_ADDI, UOP_ADD: result_o = rs1_i + ((op_i == UOP_ADDI) ? imm_i : rs2_i);
      UOP_SUB:  result_o = rs1_i - rs2_i;
      UOP_SLTI: result_o = {31'b0, ($signed(rs1_i) < $signed(imm_i))};
      UOP_SLT:  result_o = {31'b0, ($signed(rs1_i) < $signed(rs2_i))};
      UOP_SLTIU: result_o = {31'b0, (rs1_i < imm_i)};
      UOP_SLTU:  result_o = {31'b0, (rs1_i < rs2_i)};
      UOP_XORI: result_o = rs1_i ^ imm_i;
      UOP_XOR:  result_o = rs1_i ^ rs2_i;
      UOP_ORI:  result_o = rs1_i | imm_i;
      UOP_OR:   result_o = rs1_i | rs2_i;
      UOP_ANDI: result_o = rs1_i & imm_i;
      UOP_AND:  result_o = rs1_i & rs2_i;
      UOP_SLLI: result_o = rs1_i << imm_i[4:0];
      UOP_SLL:  result_o = rs1_i << rs2_i[4:0];
      UOP_SRLI: result_o = rs1_i >> imm_i[4:0];
      UOP_SRL:  result_o = rs1_i >> rs2_i[4:0];
      UOP_SRAI: result_o = $signed(rs1_i) >>> imm_i[4:0];
      UOP_SRA:  result_o = $signed(rs1_i) >>> rs2_i[4:0];
      UOP_SH1ADD: result_o = (rs1_i << 1) + rs2_i;
      UOP_SH2ADD: result_o = (rs1_i << 2) + rs2_i;
      UOP_SH3ADD: result_o = (rs1_i << 3) + rs2_i;
      UOP_LB, UOP_LH, UOP_LW, UOP_LBU, UOP_LHU,
      UOP_SB, UOP_SH, UOP_SW: result_o = rs1_i + imm_i;
      default: result_o = 32'b0;
    endcase
  end
endmodule
