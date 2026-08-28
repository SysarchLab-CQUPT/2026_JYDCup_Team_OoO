`timescale 1ns/1ps
module muldiv_unit #(
  parameter bit SUPPORT_MUL = 1'b1
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,
  input  logic                       req_valid_i,
  output logic                       req_ready_o,
  input  rv32_pkg::uop_op_e          req_op_i,
  input  logic [31:0]                req_a_i,
  input  logic [31:0]                req_b_i,
  input  core_types_pkg::uop_id_t    req_uop_id_i,
  output logic                       rsp_valid_o,
  input  logic                       rsp_ready_i,
  output logic [31:0]                rsp_result_o,
  output core_types_pkg::uop_id_t    rsp_uop_id_o
);
  import rv32_pkg::*;
  import core_types_pkg::*;

  typedef enum logic [1:0] {MD_IDLE, MD_DIV, MD_RESP} md_state_e;
  md_state_e state_q;
  uop_op_e op_q;
  uop_id_t uop_id_q;
  logic [31:0] result_q;
  logic [31:0] divisor_q;
  logic [31:0] quotient_q;
  logic [32:0] remainder_q;
  logic [5:0] iter_q;
  logic quotient_neg_q;
  logic remainder_neg_q;

  logic [63:0] product_uu;
  logic [31:0] mul_high_ss;
  logic [31:0] mul_high_su;
  logic [32:0] remainder_shift;
  logic [31:0] quotient_shift;
  logic [32:0] remainder_next;
  logic [31:0] quotient_next;

  always_comb begin
    product_uu = req_a_i * req_b_i;
    mul_high_ss = product_uu[63:32]
                - (req_a_i[31] ? req_b_i : 32'b0)
                - (req_b_i[31] ? req_a_i : 32'b0);
    mul_high_su = product_uu[63:32]
                - (req_a_i[31] ? req_b_i : 32'b0);

    remainder_shift = {remainder_q[31:0], quotient_q[31]};
    quotient_shift = {quotient_q[30:0], 1'b0};
    remainder_next = remainder_shift;
    quotient_next = quotient_shift;
    if (remainder_shift >= {1'b0, divisor_q}) begin
      remainder_next = remainder_shift - {1'b0, divisor_q};
      quotient_next[0] = 1'b1;
    end
  end

  assign req_ready_o = (state_q == MD_IDLE);
  assign rsp_valid_o = (state_q == MD_RESP);
  assign rsp_result_o = result_q;
  assign rsp_uop_id_o = uop_id_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= MD_IDLE;
      op_q <= UOP_ILLEGAL;
      uop_id_q <= '0;
      result_q <= '0;
      divisor_q <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      iter_q <= '0;
      quotient_neg_q <= 1'b0;
      remainder_neg_q <= 1'b0;
    end else begin
      unique case (state_q)
        MD_IDLE: begin
          if (req_valid_i) begin
            op_q <= req_op_i;
            uop_id_q <= req_uop_id_i;
            if (SUPPORT_MUL && is_mul_op(req_op_i)) begin
              unique case (req_op_i)
                UOP_MUL:    result_q <= product_uu[31:0];
                UOP_MULH:   result_q <= mul_high_ss;
                UOP_MULHSU: result_q <= mul_high_su;
                default:    result_q <= product_uu[63:32];
              endcase
              state_q <= MD_RESP;
            end else if (is_div_op(req_op_i)) begin
              if (req_b_i == 0) begin
                result_q <= (req_op_i inside {UOP_DIV, UOP_DIVU})
                          ? 32'hffff_ffff : req_a_i;
                state_q <= MD_RESP;
              end else if ((req_op_i inside {UOP_DIV, UOP_REM}) &&
                           (req_a_i == 32'h8000_0000) &&
                           (req_b_i == 32'hffff_ffff)) begin
                result_q <= (req_op_i == UOP_DIV) ? 32'h8000_0000 : 32'b0;
                state_q <= MD_RESP;
              end else begin
                quotient_q <= ((req_op_i inside {UOP_DIV, UOP_REM}) && req_a_i[31])
                            ? (~req_a_i + 1'b1) : req_a_i;
                divisor_q <= ((req_op_i inside {UOP_DIV, UOP_REM}) && req_b_i[31])
                           ? (~req_b_i + 1'b1) : req_b_i;
                remainder_q <= '0;
                iter_q <= '0;
                quotient_neg_q <= (req_op_i == UOP_DIV) && (req_a_i[31] ^ req_b_i[31]);
                remainder_neg_q <= (req_op_i == UOP_REM) && req_a_i[31];
                state_q <= MD_DIV;
              end
            end else begin
              result_q <= '0;
              state_q <= MD_RESP;
            end
          end
        end
        MD_DIV: begin
          quotient_q <= quotient_next;
          remainder_q <= remainder_next;
          if (iter_q == 6'd31) begin
            if (op_q inside {UOP_DIV, UOP_DIVU}) begin
              result_q <= quotient_neg_q ? (~quotient_next + 1'b1) : quotient_next;
            end else begin
              result_q <= remainder_neg_q ? (~remainder_next[31:0] + 1'b1)
                                           : remainder_next[31:0];
            end
            state_q <= MD_RESP;
          end else begin
            iter_q <= iter_q + 1'b1;
          end
        end
        MD_RESP: begin
          if (rsp_ready_i) state_q <= MD_IDLE;
        end
        default: state_q <= MD_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  logic req_stalled_q;
  uop_op_e stalled_op_q;
  logic [31:0] stalled_a_q, stalled_b_q;
  uop_id_t stalled_uop_id_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      req_stalled_q <= 1'b0;
      stalled_op_q <= UOP_ILLEGAL;
      stalled_a_q <= '0;
      stalled_b_q <= '0;
      stalled_uop_id_q <= '0;
    end else begin
      if (req_valid_i)
        assert ((SUPPORT_MUL && is_mul_op(req_op_i)) ||
                is_div_op(req_op_i))
          else $fatal(1, "muldiv observed a non-M operation");
      if (req_stalled_q) begin
        assert (req_valid_i &&
                (req_op_i == stalled_op_q) &&
                (req_a_i == stalled_a_q) &&
                (req_b_i == stalled_b_q) &&
                (req_uop_id_i == stalled_uop_id_q))
          else $fatal(1, "muldiv request changed while stalled");
      end
      req_stalled_q <= req_valid_i && !req_ready_o;
      if (req_valid_i && !req_ready_o && !req_stalled_q) begin
        stalled_op_q <= req_op_i;
        stalled_a_q <= req_a_i;
        stalled_b_q <= req_b_i;
        stalled_uop_id_q <= req_uop_id_i;
      end
    end
  end
`endif
endmodule
