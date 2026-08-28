`timescale 1ns/1ps
module irq_debug #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter logic [31:0] BUILD_ID = 32'h2025_2301
) (
  input  logic                clk_i,
  input  logic                rst_ni,
  input  logic [3:0]          source_i,
  output logic                meip_o,
  input  mmio_pkg::mmio_req_t bus_req_i,
  output mmio_pkg::mmio_rsp_t bus_rsp_o,
  output logic [3:0]          pending_o,
  output logic                coremark_led_o
);
  import mmio_pkg::*;

  localparam logic [11:0] REG_PENDING = 12'h000;
  localparam logic [11:0] REG_ENABLE  = 12'h004;
  localparam logic [11:0] REG_ACK     = 12'h008;
  localparam logic [11:0] REG_BUILDID = 12'h00c;
  localparam logic [11:0] REG_CLK_HZ  = 12'h010;
  localparam logic [11:0] REG_LED     = 12'h014;

  logic [3:0] pending_q;
  logic [3:0] enable_q;
  logic coremark_led_q;
  logic [3:0] ack_mask;
  logic bus_fire;

  always_comb begin
    bus_rsp_o = '{ready: bus_req_i.valid, rdata: 32'b0, error: 1'b0};
    unique case (bus_req_i.addr[11:0])
      REG_PENDING: bus_rsp_o.rdata = {28'b0, pending_q};
      REG_ENABLE:  bus_rsp_o.rdata = {28'b0, enable_q};
      REG_BUILDID: bus_rsp_o.rdata = BUILD_ID;
      REG_CLK_HZ:  bus_rsp_o.rdata = CLK_HZ;
      REG_LED:     bus_rsp_o.rdata = {31'b0, coremark_led_q};
      default:     bus_rsp_o.rdata = 32'b0;
    endcase
  end

  assign bus_fire = bus_req_i.valid && bus_rsp_o.ready;
  assign ack_mask = (bus_fire && bus_req_i.write &&
                     (bus_req_i.addr[11:0] == REG_ACK)) ?
                    bus_req_i.wdata[3:0] : 4'b0;
  assign meip_o = |(pending_q & enable_q);
  assign pending_o = pending_q;
  assign coremark_led_o = coremark_led_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pending_q <= '0;
      enable_q <= '0;
      coremark_led_q <= 1'b0;
    end else begin
      pending_q <= (pending_q | source_i) & ~ack_mask;
      if (bus_fire && bus_req_i.write &&
          (bus_req_i.addr[11:0] == REG_ENABLE) && bus_req_i.wstrb[0]) begin
        enable_q <= bus_req_i.wdata[3:0];
      end
      if (bus_fire && bus_req_i.write &&
          (bus_req_i.addr[11:0] == REG_LED) && bus_req_i.wstrb[0]) begin
        coremark_led_q <= bus_req_i.wdata[0];
      end
    end
  end
endmodule
