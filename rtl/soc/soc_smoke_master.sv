`timescale 1ns/1ps
module soc_smoke_master #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned UART_BAUD = 115_200
) (
  input  logic                clk_i,
  input  logic                rst_ni,
  output mmio_pkg::mmio_req_t bus_req_o,
  input  mmio_pkg::mmio_rsp_t bus_rsp_i,
  output logic                done_o
);
  import mmio_pkg::*;

  localparam logic [31:0] UART_DIV =
    (CLK_HZ + (UART_BAUD / 2)) / UART_BAUD;
  localparam logic [31:0] TICK_DIV = (CLK_HZ / 1000) - 1;

  typedef enum logic [3:0] {
    ST_WAIT,
    ST_UART_DIV,
    ST_TIMER_RELOAD,
    ST_TIMER_COUNT,
    ST_TIMER_CTRL,
    ST_BYTE_J,
    ST_BYTE_Y,
    ST_BYTE_D,
    ST_BYTE_NL,
    ST_DONE
  } state_t;
  state_t state_q;

  always_comb begin
    bus_req_o = '0;
    bus_req_o.write = 1'b1;
    bus_req_o.wstrb = 4'hf;
    done_o = 1'b0;
    unique case (state_q)
      ST_UART_DIV: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_0010;
        bus_req_o.wdata = UART_DIV;
      end
      ST_TIMER_RELOAD: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_1004;
        bus_req_o.wdata = TICK_DIV;
      end
      ST_TIMER_COUNT: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_1000;
        bus_req_o.wdata = TICK_DIV;
      end
      ST_TIMER_CTRL: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_1008;
        bus_req_o.wdata = 32'h3;
      end
      ST_BYTE_J: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_0000;
        bus_req_o.wdata = 32'h0000_004a;
      end
      ST_BYTE_Y: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_0000;
        bus_req_o.wdata = 32'h0000_0059;
      end
      ST_BYTE_D: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_0000;
        bus_req_o.wdata = 32'h0000_0044;
      end
      ST_BYTE_NL: begin
        bus_req_o.valid = 1'b1;
        bus_req_o.addr = 32'h1000_0000;
        bus_req_o.wdata = 32'h0000_000a;
      end
      ST_DONE: done_o = 1'b1;
      default: begin end
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= ST_WAIT;
    end else begin
      unique case (state_q)
        ST_WAIT: state_q <= ST_UART_DIV;
        ST_DONE: state_q <= ST_DONE;
        default: begin
          if (bus_req_o.valid && bus_rsp_i.ready) begin
            state_q <= state_t'(state_q + 1'b1);
          end
        end
      endcase
    end
  end
endmodule

