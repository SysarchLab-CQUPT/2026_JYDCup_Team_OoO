`timescale 1ns/1ps
module soc_smoke_system #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned UART_BAUD = 115_200,
  parameter logic [31:0] BUILD_ID = 32'h2025_2301
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        uart_rx_i,
  output logic        uart_tx_o,
  output logic        timer_irq_o,
  output logic        ext_irq_o,
  output logic        smoke_done_o,
  output logic [31:0] timer_count_o,
  output logic [3:0]  irq_pending_o
);
  import mmio_pkg::*;

  mmio_req_t bus_req;
  mmio_rsp_t bus_rsp;

  soc_smoke_master #(.CLK_HZ(CLK_HZ), .UART_BAUD(UART_BAUD)) u_master (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .bus_req_o(bus_req), .bus_rsp_i(bus_rsp), .done_o(smoke_done_o)
  );

  soc_peripherals #(
    .CLK_HZ(CLK_HZ), .UART_BAUD(UART_BAUD), .BUILD_ID(BUILD_ID)
  ) u_peripherals (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .mtip_o(timer_irq_o), .meip_o(ext_irq_o),
    .bus_req_i(bus_req), .bus_rsp_o(bus_rsp),
    .timer_count_o(timer_count_o), .irq_pending_o(irq_pending_o)
  );
endmodule

