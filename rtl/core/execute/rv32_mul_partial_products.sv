`timescale 1ns/1ps
(* keep_hierarchy = "yes" *) module rv32_mul_partial_products (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        enable_i,
  input  logic [31:0] operand_a_i,
  input  logic [31:0] operand_b_i,
  output logic [31:0] product_ll_o,
  output logic [31:0] product_lh_o,
  output logic [31:0] product_hl_o,
  output logic [31:0] product_hh_o
);
  // Four independent 16x16 registered partial products map directly onto
  // four DSP48E1 blocks.  Keeping the products separate prevents Vivado from
  // rebuilding a monolithic 32x32 multiplier and spending excessive effort
  // retiming its DSP cascade.  The enclosing execute pipe reconstructs the
  // exact unsigned 64-bit product with two 32-bit carry-chain levels.
  // Preserve four independent registered products at this hierarchy boundary.
  // Otherwise Vivado may absorb the parent's reconstruction adders and chain
  // these DSPs through PCIN/PCOUT, which produced 48 internal setup violations
  // even though no RV32 operation requires a DSP cascade in this stage.
  (* use_dsp = "yes", keep = "true" *) logic [31:0] product_ll_q;
  (* use_dsp = "yes", keep = "true" *) logic [31:0] product_lh_q;
  (* use_dsp = "yes", keep = "true" *) logic [31:0] product_hl_q;
  (* use_dsp = "yes", keep = "true" *) logic [31:0] product_hh_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      product_ll_q <= '0;
      product_lh_q <= '0;
      product_hl_q <= '0;
      product_hh_q <= '0;
    end else if (enable_i) begin
      product_ll_q <= $unsigned(operand_a_i[15:0]) *
                      $unsigned(operand_b_i[15:0]);
      product_lh_q <= $unsigned(operand_a_i[15:0]) *
                      $unsigned(operand_b_i[31:16]);
      product_hl_q <= $unsigned(operand_a_i[31:16]) *
                      $unsigned(operand_b_i[15:0]);
      product_hh_q <= $unsigned(operand_a_i[31:16]) *
                      $unsigned(operand_b_i[31:16]);
    end
  end

  assign product_ll_o = product_ll_q;
  assign product_lh_o = product_lh_q;
  assign product_hl_o = product_hl_q;
  assign product_hh_o = product_hh_q;
endmodule
