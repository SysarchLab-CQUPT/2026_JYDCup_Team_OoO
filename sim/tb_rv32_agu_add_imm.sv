`timescale 1ns/1ps

module tb_rv32_agu_add_imm;
  logic [31:0] base;
  logic [31:0] imm;
  logic [31:0] addr;
  logic [31:0] expected;
  logic [31:0] random_base;
  logic [11:0] random_imm12;

  rv32_agu_add_imm dut (
    .base_i(base),
    .imm_i(imm),
    .addr_o(addr)
  );

  task automatic check_address(
    input logic [31:0] test_base,
    input logic [11:0] test_imm12
  );
    begin
      base = test_base;
      imm = {{20{test_imm12[11]}}, test_imm12};
      expected = test_base + {{20{test_imm12[11]}}, test_imm12};
      #1;
      assert (addr === expected)
        else $fatal(1,
          "AGU mismatch base=%08x imm=%08x got=%08x expected=%08x",
          base, imm, addr, expected);
    end
  endtask

  initial begin
    base = '0;
    imm = '0;
    expected = '0;

    check_address(32'h0000_0000, 12'h000);
    check_address(32'h0000_ffff, 12'h001);
    check_address(32'hffff_ffff, 12'h001);
    check_address(32'h0001_0000, 12'hfff);
    check_address(32'h1234_0000, 12'h800);
    check_address(32'h1234_ffff, 12'h7ff);

    for (int unsigned i = 0; i < 10000; i++) begin
      random_base = {$urandom, $urandom};
      random_imm12 = $urandom;
      check_address(random_base, random_imm12);
    end

    $display("PASS tb_rv32_agu_add_imm");
    $finish;
  end
endmodule
