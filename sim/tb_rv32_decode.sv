`timescale 1ns/1ps
module tb_rv32_decode;
  import rv32_pkg::*;
  logic [31:0] inst;
  decoded_instr_t dec;

  rv32_decode dut (.inst_i(inst), .dec_o(dec));

  task automatic check_op(input logic [31:0] value, input uop_op_e expected);
    inst = value;
    #1;
    assert (!dec.illegal && dec.op == expected)
      else $fatal(1, "decode mismatch inst=%08x op=%0d illegal=%0b", value, dec.op, dec.illegal);
  endtask

  initial begin
    check_op(32'h0020_81b3, UOP_ADD);
    assert (dec.rs1 == 1 && dec.rs2 == 2 && dec.rd == 3 && dec.rd_wen &&
            dec.uses_rs1 && dec.uses_rs2) else $fatal(1, "ADD fields");

    check_op(32'h2020_a1b3, UOP_SH1ADD);
    check_op(32'h2020_c1b3, UOP_SH2ADD);
    check_op(32'h2020_e1b3, UOP_SH3ADD);

    check_op(32'h0220_91b3, UOP_MULH);
    assert (dec.is_muldiv) else $fatal(1, "MULH class");

    check_op(32'h0020_818b, UOP_CRC16);
    check_op(32'h0020_a18b, UOP_CRC32);
    assert (dec.rs1 == 1 && dec.rs2 == 2 && dec.rd == 3 && dec.rd_wen &&
            dec.uses_rs1 && dec.uses_rs2 && !dec.is_muldiv)
      else $fatal(1, "CRC16 fields");

    check_op(32'h0020_918b, UOP_STATE_STEP);
    assert (dec.rs1 == 1 && dec.rs2 == 2 && dec.rd == 3 && dec.rd_wen &&
            dec.uses_rs1 && dec.uses_rs2)
      else $fatal(1, "state-step fields");

    check_op(32'h0080_00ef, UOP_JAL);
    assert (dec.imm == 32'd8 && dec.is_jump) else $fatal(1, "JAL immediate");

    check_op(32'hfe20_8ee3, UOP_BEQ);
    assert (dec.imm == 32'hffff_fffc && dec.is_branch) else $fatal(1, "branch immediate");

    check_op(32'h3001_10f3, UOP_CSRRW);
    assert (dec.csr_addr == 12'h300 && dec.rs1 == 2 && dec.is_csr)
      else $fatal(1, "CSR fields");

    check_op(32'h0000_100f, UOP_FENCEI);
    check_op(32'h3020_0073, UOP_MRET);

    inst = 32'hfe10_9113;
    #1;
    assert (dec.illegal && dec.op == UOP_ILLEGAL && !dec.rd_wen)
      else $fatal(1, "illegal shift encoding accepted");

    inst = 32'hffff_ffff;
    #1;
    assert (dec.illegal) else $fatal(1, "illegal opcode accepted");
    $display("PASS tb_rv32_decode");
    $finish;
  end
endmodule
