`timescale 1ns/1ps
module tb_state_transition_accelerator;
  logic [2:0] state_i;
  logic [7:0] symbol_i;
  logic [31:0] result_o;

  state_transition_accelerator dut (.*);

  function automatic logic is_digit(input logic [7:0] symbol);
    return (symbol >= 8'h30) && (symbol <= 8'h39);
  endfunction

  task automatic check(input logic [2:0] state, input logic [7:0] symbol);
    logic [2:0] next_state;
    logic [3:0] primary_index;
    logic secondary_invalid;
    state_i = state;
    symbol_i = symbol;
    next_state = state;
    primary_index = 4'hf;
    secondary_invalid = 1'b0;
    case (state)
      3'd0: begin
        primary_index = 0;
        if (is_digit(symbol)) next_state = 4;
        else if ((symbol == 8'h2b) || (symbol == 8'h2d)) next_state = 2;
        else if (symbol == 8'h2e) next_state = 5;
        else begin next_state = 1; secondary_invalid = 1'b1; end
      end
      3'd2: begin
        primary_index = 2;
        if (is_digit(symbol)) next_state = 4;
        else if (symbol == 8'h2e) next_state = 5;
        else next_state = 1;
      end
      3'd4: begin
        if (symbol == 8'h2e) begin next_state = 5; primary_index = 4; end
        else if (!is_digit(symbol)) begin next_state = 1; primary_index = 4; end
      end
      3'd5: begin
        if ((symbol == 8'h45) || (symbol == 8'h65)) begin
          next_state = 3; primary_index = 5;
        end else if (!is_digit(symbol)) begin next_state = 1; primary_index = 5; end
      end
      3'd3: begin
        primary_index = 3;
        if ((symbol == 8'h2b) || (symbol == 8'h2d)) next_state = 6;
        else next_state = 1;
      end
      3'd6: begin
        primary_index = 6;
        next_state = is_digit(symbol) ? 7 : 1;
      end
      3'd7: if (!is_digit(symbol)) begin
        next_state = 1; secondary_invalid = 1'b1;
      end
      default: next_state = 1;
    endcase
    #1;
    assert (result_o[2:0] == next_state &&
            result_o[31:28] == primary_index &&
            result_o[3] == secondary_invalid)
      else $fatal(1, "state step mismatch state=%0d symbol=%02x result=%08x",
                  state, symbol, result_o);
  endtask

  initial begin
    for (int unsigned state = 0; state < 8; state++)
      for (int unsigned symbol = 0; symbol < 256; symbol++)
        check(state[2:0], symbol[7:0]);
    $display("PASS tb_state_transition_accelerator");
    $finish;
  end
endmodule
