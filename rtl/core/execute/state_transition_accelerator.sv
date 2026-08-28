`timescale 1ns/1ps
module state_transition_accelerator (
  input  logic [2:0]  state_i,
  input  logic [7:0]  symbol_i,
  output logic [31:0] result_o
);
  localparam logic [2:0] CORE_START      = 3'd0;
  localparam logic [2:0] CORE_INVALID    = 3'd1;
  localparam logic [2:0] CORE_S1         = 3'd2;
  localparam logic [2:0] CORE_S2         = 3'd3;
  localparam logic [2:0] CORE_INT        = 3'd4;
  localparam logic [2:0] CORE_FLOAT      = 3'd5;
  localparam logic [2:0] CORE_EXPONENT   = 3'd6;
  localparam logic [2:0] CORE_SCIENTIFIC = 3'd7;

  logic digit;
  logic [2:0] next_state;
  logic [3:0] primary_count_index;
  logic secondary_invalid_count;

  always_comb begin
    digit = (symbol_i >= 8'h30) && (symbol_i <= 8'h39);
    next_state = state_i;
    primary_count_index = 4'hf;
    secondary_invalid_count = 1'b0;

    unique case (state_i)
      CORE_START: begin
        primary_count_index = {1'b0, CORE_START};
        if (digit)
          next_state = CORE_INT;
        else if ((symbol_i == 8'h2b) || (symbol_i == 8'h2d))
          next_state = CORE_S1;
        else if (symbol_i == 8'h2e)
          next_state = CORE_FLOAT;
        else begin
          next_state = CORE_INVALID;
          secondary_invalid_count = 1'b1;
        end
      end
      CORE_S1: begin
        primary_count_index = {1'b0, CORE_S1};
        if (digit)
          next_state = CORE_INT;
        else if (symbol_i == 8'h2e)
          next_state = CORE_FLOAT;
        else
          next_state = CORE_INVALID;
      end
      CORE_INT: begin
        if (symbol_i == 8'h2e) begin
          next_state = CORE_FLOAT;
          primary_count_index = {1'b0, CORE_INT};
        end else if (!digit) begin
          next_state = CORE_INVALID;
          primary_count_index = {1'b0, CORE_INT};
        end
      end
      CORE_FLOAT: begin
        if ((symbol_i == 8'h45) || (symbol_i == 8'h65)) begin
          next_state = CORE_S2;
          primary_count_index = {1'b0, CORE_FLOAT};
        end else if (!digit) begin
          next_state = CORE_INVALID;
          primary_count_index = {1'b0, CORE_FLOAT};
        end
      end
      CORE_S2: begin
        primary_count_index = {1'b0, CORE_S2};
        if ((symbol_i == 8'h2b) || (symbol_i == 8'h2d))
          next_state = CORE_EXPONENT;
        else
          next_state = CORE_INVALID;
      end
      CORE_EXPONENT: begin
        primary_count_index = {1'b0, CORE_EXPONENT};
        next_state = digit ? CORE_SCIENTIFIC : CORE_INVALID;
      end
      CORE_SCIENTIFIC: begin
        if (!digit) begin
          next_state = CORE_INVALID;
          secondary_invalid_count = 1'b1;
        end
      end
      default: next_state = CORE_INVALID;
    endcase

    result_o = '0;
    result_o[2:0] = next_state;
    // Keep the state in the low three bits for the loop-carried dependency,
    // but place the count index at the top of the word so software extracts
    // it with one SRLI instead of an SLLI/SRLI pair.  Bit 3 is otherwise
    // unused and carries the secondary invalid-state increment flag.
    result_o[31:28] = primary_count_index;
    result_o[3] = secondary_invalid_count;
  end
endmodule
