`timescale 1ns/1ps
module tick_timer (
  input  logic                clk_i,
  input  logic                rst_ni,
  output logic                irq_o,
  input  mmio_pkg::mmio_req_t bus_req_i,
  output mmio_pkg::mmio_rsp_t bus_rsp_o,
  output logic [31:0]         count_o
);
  import mmio_pkg::*;

  localparam logic [11:0] REG_COUNT   = 12'h000;
  localparam logic [11:0] REG_RELOAD  = 12'h004;
  localparam logic [11:0] REG_CTRL    = 12'h008;
  localparam logic [11:0] REG_PENDING = 12'h00c;
  localparam logic [11:0] REG_ACK     = 12'h010;

  logic [31:0] count_q;
  logic [31:0] reload_q;
  logic enable_q;
  logic irq_enable_q;
  logic pending_q;
  logic bus_fire;

  always_comb begin
    bus_rsp_o = '{ready: bus_req_i.valid, rdata: 32'b0, error: 1'b0};
    unique case (bus_req_i.addr[11:0])
      REG_COUNT:   bus_rsp_o.rdata = count_q;
      REG_RELOAD:  bus_rsp_o.rdata = reload_q;
      REG_CTRL:    bus_rsp_o.rdata = {30'b0, irq_enable_q, enable_q};
      REG_PENDING: bus_rsp_o.rdata = {31'b0, pending_q};
      default:     bus_rsp_o.rdata = 32'b0;
    endcase
  end

  assign bus_fire = bus_req_i.valid && bus_rsp_o.ready;
  assign irq_o = pending_q && irq_enable_q;
  assign count_o = count_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      count_q <= '0;
      reload_q <= '0;
      enable_q <= 1'b0;
      irq_enable_q <= 1'b0;
      pending_q <= 1'b0;
    end else begin
      if (enable_q) begin
        if (count_q == 0) begin
          count_q <= reload_q;
          pending_q <= 1'b1;
        end else begin
          count_q <= count_q - 1'b1;
        end
      end

      if (bus_fire && bus_req_i.write) begin
        unique case (bus_req_i.addr[11:0])
          REG_COUNT: begin
            if (|bus_req_i.wstrb) count_q <= bus_req_i.wdata;
          end
          REG_RELOAD: begin
            if (|bus_req_i.wstrb) reload_q <= bus_req_i.wdata;
          end
          REG_CTRL: begin
            if (bus_req_i.wstrb[0]) begin
              enable_q <= bus_req_i.wdata[0];
              irq_enable_q <= bus_req_i.wdata[1];
            end
          end
          REG_ACK: begin
            if (bus_req_i.wdata[0]) pending_q <= 1'b0;
          end
          default: begin end
        endcase
      end
    end
  end
endmodule

