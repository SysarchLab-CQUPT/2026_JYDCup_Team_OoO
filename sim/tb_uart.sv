`timescale 1ns/1ps
module tb_uart;
  import mmio_pkg::*;
  localparam int unsigned BIT_CYCLES = 4;

  logic clk;
  logic rst_n;
  logic rx;
  logic tx;
  logic irq;
  mmio_req_t bus_req;
  mmio_rsp_t bus_rsp;
  logic [7:0] received;

  uart #(.CLK_HZ(400), .RESET_BAUD(100)) dut (
    .clk_i(clk), .rst_ni(rst_n), .rx_i(rx), .tx_o(tx), .irq_o(irq),
    .bus_req_i(bus_req), .bus_rsp_o(bus_rsp)
  );

  always #5 clk = ~clk;

  task automatic receive_uart_byte(output logic [7:0] data);
    @(negedge tx);
    repeat (BIT_CYCLES/2) @(posedge clk);
    assert (!tx) else $fatal(1, "start bit center is not low");
    for (int bit_idx = 0; bit_idx < 8; bit_idx++) begin
      repeat (BIT_CYCLES) @(posedge clk);
      data[bit_idx] = tx;
    end
    repeat (BIT_CYCLES) @(posedge clk);
    assert (tx) else $fatal(1, "stop bit center is not high");
  endtask

  initial begin : watchdog
    repeat (80) @(posedge clk);
    $fatal(1, "tb_uart exceeded 80 cycles");
  end

  initial begin
    clk = 0;
    rst_n = 0;
    rx = 1;
    bus_req = '0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    fork
      receive_uart_byte(received);
      begin
        @(negedge clk);
        bus_req.valid = 1'b1;
        bus_req.write = 1'b1;
        bus_req.addr = 32'h1000_0000;
        bus_req.wdata = 32'h0000_00a5;
        bus_req.wstrb = 4'h1;
        #1;
        assert (bus_rsp.ready) else $fatal(1, "TXDATA was not ready before the accepting edge");
        @(posedge clk);
        @(negedge clk);
        bus_req = '0;
      end
    join

    assert (received == 8'ha5)
      else $fatal(1, "UART byte mismatch: got %02x", received);
    $display("PASS tb_uart");
    $finish;
  end
endmodule
