`timescale 1ns/1ps
module tb_csr_execute;
  import rv32_pkg::*;

  uop_op_e op;
  logic csr_valid;
  logic [4:0] rs1_field;
  logic [11:0] csr_addr;
  logic [31:0] source, read_data, write_data;
  logic read_illegal, write_intent, illegal;

  csr_execute dut (
    .csr_valid_i(csr_valid), .op_i(op), .rs1_field_i(rs1_field),
    .csr_addr_i(csr_addr),
    .source_i(source), .read_data_i(read_data),
    .read_illegal_i(read_illegal), .write_o(write_intent),
    .write_data_o(write_data), .illegal_o(illegal)
  );

  task automatic check(
    input uop_op_e test_op,
    input logic [4:0] test_rs1,
    input logic [11:0] test_addr,
    input logic [31:0] test_source,
    input logic expected_write,
    input logic expected_illegal,
    input logic [31:0] expected_data
  );
    op = test_op;
    rs1_field = test_rs1;
    csr_addr = test_addr;
    source = test_source;
    #1;
    assert (write_intent == expected_write)
      else $fatal(1, "CSR write intent op=%0d rs1=%0d source=%x got=%0b expected=%0b",
                  test_op, test_rs1, test_source, write_intent, expected_write);
    assert (illegal == expected_illegal)
      else $fatal(1, "CSR legality op=%0d rs1=%0d addr=%x got=%0b expected=%0b",
                  test_op, test_rs1, test_addr, illegal, expected_illegal);
    assert (write_data == expected_data)
      else $fatal(1, "CSR write data got=%x expected=%x", write_data, expected_data);
  endtask

  initial begin
    op = UOP_ILLEGAL;
    csr_valid = 1'b1;
    rs1_field = 0;
    csr_addr = 0;
    source = 0;
    read_data = 32'h00ff_0f0f;
    read_illegal = 1'b0;

    check(UOP_CSRRS, 5'd0, 12'hc00, 32'h1234_5678,
          1'b0, 1'b0, 32'h12ff_5f7f);
    check(UOP_CSRRS, 5'd2, 12'hc00, 32'h0000_0000,
          1'b1, 1'b1, 32'h00ff_0f0f);
    check(UOP_CSRRC, 5'd3, 12'h300, 32'h0000_0000,
          1'b1, 1'b0, 32'h00ff_0f0f);
    check(UOP_CSRRSI, 5'd0, 12'hc00, 32'h0000_0000,
          1'b0, 1'b0, 32'h00ff_0f0f);
    check(UOP_CSRRCI, 5'd1, 12'hc00, 32'h0000_0001,
          1'b1, 1'b1, 32'h00ff_0f0e);
    check(UOP_CSRRW, 5'd0, 12'h300, 32'ha5a5_5a5a,
          1'b1, 1'b0, 32'ha5a5_5a5a);

    read_illegal = 1'b1;
    check(UOP_CSRRS, 5'd0, 12'h123, 32'h0000_0000,
          1'b0, 1'b1, 32'h00ff_0f0f);

    // Non-CSR EX1 traffic may carry an arbitrary/illegal CSR address but must
    // never be converted into an illegal-instruction exception by this unit.
    csr_valid = 1'b0;
    op = UOP_ADD;
    rs1_field = 5'd7;
    csr_addr = 12'h123;
    source = 32'hdead_beef;
    read_illegal = 1'b1;
    #1;
    assert (!illegal) else $fatal(1, "non-CSR operation was flagged illegal");
    $display("PASS tb_csr_execute");
    $finish;
  end
endmodule
