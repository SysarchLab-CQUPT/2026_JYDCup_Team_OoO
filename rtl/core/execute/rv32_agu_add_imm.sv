`timescale 1ns/1ps

// RV32 load/store immediates are signed 12-bit values.  Split their address
// addition at bit 16 so the issue-side path never contains one 32-bit carry
// chain.  The upper-word +1, unchanged, and -1 candidates are calculated in
// parallel with the low half, then selected by the low carry and sign bit.
(* keep_hierarchy = "yes" *)
module rv32_agu_add_imm (
  input  logic [31:0] base_i,
  input  logic [31:0] imm_i,
  output logic [31:0] addr_o
);
  (* keep = "true", use_dsp = "no" *) logic [16:0] low_sum;
  (* keep = "true", use_dsp = "no" *) logic [15:0] high_plus_one;
  (* keep = "true", use_dsp = "no" *) logic [15:0] high_minus_one;
  logic [15:0] high_result;

  assign low_sum = {1'b0, base_i[15:0]} + {1'b0, imm_i[15:0]};
  assign high_plus_one = base_i[31:16] + 16'd1;
  assign high_minus_one = base_i[31:16] - 16'd1;

  always_comb begin
    if (imm_i[31])
      high_result = low_sum[16] ? base_i[31:16] : high_minus_one;
    else
      high_result = low_sum[16] ? high_plus_one : base_i[31:16];
  end

  assign addr_o = {high_result, low_sum[15:0]};
endmodule
