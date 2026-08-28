`timescale 1ns/1ps
module tb_rv32_mul_partial_products;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic enable;
  logic [31:0] operand_a, operand_b;
  logic [31:0] product_ll, product_lh, product_hl, product_hh;

  always #5 clk = ~clk;

  rv32_mul_partial_products dut (
    .clk_i(clk), .rst_ni(rst_n), .enable_i(enable),
    .operand_a_i(operand_a), .operand_b_i(operand_b),
    .product_ll_o(product_ll), .product_lh_o(product_lh),
    .product_hl_o(product_hl), .product_hh_o(product_hh)
  );

  function automatic logic [63:0] rebuild_product;
    logic [32:0] cross_sum;
    logic [32:0] low_sum;
    logic [32:0] high_sum;
    cross_sum = {1'b0, product_lh} + {1'b0, product_hl};
    low_sum = {1'b0, product_ll} + {1'b0, cross_sum[15:0], 16'b0};
    high_sum = {1'b0, product_hh} + {16'b0, cross_sum[32:16]} +
               {32'b0, low_sum[32]};
    return {high_sum[31:0], low_sum[31:0]};
  endfunction

  task automatic check_product(input logic [31:0] a,
                               input logic [31:0] b);
    logic [63:0] expected;
    @(negedge clk);
    operand_a = a;
    operand_b = b;
    enable = 1'b1;
    @(posedge clk);
    #1;
    enable = 1'b0;
    expected = $unsigned({32'b0, a}) * $unsigned({32'b0, b});
    assert (rebuild_product() == expected)
      else $fatal(1, "partial product mismatch a=%08x b=%08x got=%016x expected=%016x",
                  a, b, rebuild_product(), expected);
  endtask

  initial begin
    enable = 1'b0;
    operand_a = '0;
    operand_b = '0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;

    check_product(32'h0000_0000, 32'hffff_ffff);
    check_product(32'hffff_ffff, 32'hffff_ffff);
    check_product(32'h8000_0000, 32'h8000_0000);
    check_product(32'h1234_5678, 32'h9abc_def0);
    check_product(32'h0001_0001, 32'hffff_0001);
    for (int unsigned i = 0; i < 100; i++)
      check_product($urandom, $urandom);

    $display("PASS tb_rv32_mul_partial_products");
    $finish;
  end
endmodule
