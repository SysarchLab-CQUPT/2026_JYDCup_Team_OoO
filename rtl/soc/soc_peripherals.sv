`timescale 1ns/1ps
module soc_peripherals #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned UART_BAUD = 115_200,
  parameter logic [31:0] BUILD_ID = 32'h2025_2301
) (
  input  logic                clk_i,
  input  logic                rst_ni,
  input  logic                uart_rx_i,
  output logic                uart_tx_o,
  output logic                mtip_o,
  output logic                meip_o,
  input  mmio_pkg::mmio_req_t bus_req_i,
  output mmio_pkg::mmio_rsp_t bus_rsp_o,
  output logic [31:0]         timer_count_o,
  output logic [3:0]          irq_pending_o,
  output logic                coremark_led_o
);
  import mmio_pkg::*;

  mmio_req_t uart_req;
  mmio_req_t timer_req;
  mmio_req_t irq_req;
  mmio_rsp_t uart_rsp;
  mmio_rsp_t timer_rsp;
  mmio_rsp_t irq_rsp;
  logic uart_irq;

  mmio_decode u_decode (
    .req_i(bus_req_i),
    .rsp_o(bus_rsp_o),
    .uart_req_o(uart_req), .uart_rsp_i(uart_rsp),
    .timer_req_o(timer_req), .timer_rsp_i(timer_rsp),
    .irq_req_o(irq_req), .irq_rsp_i(irq_rsp)
  );

  uart #(.CLK_HZ(CLK_HZ), .RESET_BAUD(UART_BAUD)) u_uart (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .rx_i(uart_rx_i), .tx_o(uart_tx_o), .irq_o(uart_irq),
    .bus_req_i(uart_req), .bus_rsp_o(uart_rsp)
  );

  tick_timer u_timer (
    .clk_i(clk_i), .rst_ni(rst_ni), .irq_o(mtip_o),
    .bus_req_i(timer_req), .bus_rsp_o(timer_rsp),
    .count_o(timer_count_o)
  );

  irq_debug #(.CLK_HZ(CLK_HZ), .BUILD_ID(BUILD_ID)) u_irq (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .source_i({3'b0, uart_irq}), .meip_o(meip_o),
    .bus_req_i(irq_req), .bus_rsp_o(irq_rsp),
    .pending_o(irq_pending_o), .coremark_led_o(coremark_led_o)
  );
endmodule
