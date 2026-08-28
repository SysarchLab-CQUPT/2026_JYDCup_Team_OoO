`timescale 1ns/1ps
module tb_mmio_decode;
  import mmio_pkg::*;

  mmio_req_t req;
  mmio_rsp_t rsp;
  mmio_req_t uart_req;
  mmio_req_t timer_req;
  mmio_req_t irq_req;
  mmio_rsp_t uart_rsp;
  mmio_rsp_t timer_rsp;
  mmio_rsp_t irq_rsp;

  mmio_decode dut (.*,
    .req_i(req), .rsp_o(rsp),
    .uart_req_o(uart_req), .uart_rsp_i(uart_rsp),
    .timer_req_o(timer_req), .timer_rsp_i(timer_rsp),
    .irq_req_o(irq_req), .irq_rsp_i(irq_rsp)
  );

  initial begin
    req = '0;
    uart_rsp = '{ready: 1'b1, rdata: 32'h1111_0000, error: 1'b0};
    timer_rsp = '{ready: 1'b1, rdata: 32'h2222_0000, error: 1'b0};
    irq_rsp = '{ready: 1'b1, rdata: 32'h3333_0000, error: 1'b0};

    req.valid = 1'b1;
    req.addr = 32'h1000_0008;
    #1;
    assert (uart_req.valid && !timer_req.valid && rsp.rdata == 32'h1111_0000);

    // Peripheral backpressure may change the selected response, but it must
    // never feed back into or suppress the decoded request channel.
    uart_rsp.ready = 1'b0;
    #1;
    assert (uart_req.valid && !timer_req.valid && !irq_req.valid);
    assert (!rsp.ready && rsp.rdata == 32'h1111_0000);
    uart_rsp.ready = 1'b1;

    req.addr = 32'h1000_1010;
    #1;
    assert (timer_req.valid && !uart_req.valid && rsp.rdata == 32'h2222_0000);

    req.addr = 32'h1000_2010;
    #1;
    assert (irq_req.valid && rsp.rdata == 32'h3333_0000);

    req.addr = 32'h1000_3004;
    #1;
    assert (rsp.ready && rsp.error && rsp.rdata == 0);

    req.addr = 32'h1000_4000;
    #1;
    assert (rsp.ready && rsp.error && rsp.rdata == 0);

    req.addr = 32'h1000_5000;
    #1;
    assert (rsp.ready && rsp.error && rsp.rdata == 0);
    assert (!(uart_req.valid || timer_req.valid || irq_req.valid));

    $display("PASS tb_mmio_decode");
    $finish;
  end
endmodule
