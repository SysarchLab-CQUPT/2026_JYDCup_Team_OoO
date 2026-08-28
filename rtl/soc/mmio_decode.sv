`timescale 1ns/1ps
module mmio_decode (
  input  mmio_pkg::mmio_req_t req_i,
  output mmio_pkg::mmio_rsp_t rsp_o,

  output mmio_pkg::mmio_req_t uart_req_o,
  input  mmio_pkg::mmio_rsp_t uart_rsp_i,
  output mmio_pkg::mmio_req_t timer_req_o,
  input  mmio_pkg::mmio_rsp_t timer_rsp_i,
  output mmio_pkg::mmio_req_t irq_req_o,
  input  mmio_pkg::mmio_rsp_t irq_rsp_i
);
  import mmio_pkg::*;

  logic uart_selected;
  logic timer_selected;
  logic irq_selected;

  assign uart_selected = req_i.valid &&
                         (req_i.addr[31:16] == 16'h1000) &&
                         (req_i.addr[15:12] == 4'h0);
  assign timer_selected = req_i.valid &&
                          (req_i.addr[31:16] == 16'h1000) &&
                          (req_i.addr[15:12] == 4'h1);
  assign irq_selected = req_i.valid &&
                        (req_i.addr[31:16] == 16'h1000) &&
                        (req_i.addr[15:12] == 4'h2);

  always_comb begin
    uart_req_o = req_i;
    timer_req_o = req_i;
    irq_req_o = req_i;
    uart_req_o.valid = uart_selected;
    timer_req_o.valid = timer_selected;
    irq_req_o.valid = irq_selected;
  end

  // Keep request decode independent of peripheral ready.  Combining both
  // directions in one always_comb block makes the ready-return path appear as
  // a combinational cycle through the UART request even though the address is
  // registered at the dmem FIFO head.
  always_comb begin
    rsp_o = '{ready: req_i.valid, rdata: 32'b0, error: req_i.valid};
    if (uart_selected)
      rsp_o = uart_rsp_i;
    else if (timer_selected)
      rsp_o = timer_rsp_i;
    else if (irq_selected)
      rsp_o = irq_rsp_i;
  end
endmodule
