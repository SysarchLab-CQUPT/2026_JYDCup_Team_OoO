`timescale 1ns/1ps
module tb_tick_timer;
  import mmio_pkg::*;

  logic clk;
  logic rst_n;
  logic irq;
  logic [31:0] count;
  mmio_req_t bus_req;
  mmio_rsp_t bus_rsp;

  tick_timer dut (
    .clk_i(clk), .rst_ni(rst_n), .irq_o(irq),
    .bus_req_i(bus_req), .bus_rsp_o(bus_rsp), .count_o(count)
  );

  always #5 clk = ~clk;

  task automatic write_reg(input logic [31:0] addr, input logic [31:0] data);
    @(negedge clk);
    bus_req.valid = 1'b1;
    bus_req.write = 1'b1;
    bus_req.addr = addr;
    bus_req.wdata = data;
    bus_req.wstrb = 4'hf;
    #1;
    assert (bus_rsp.ready) else $fatal(1, "timer write was not ready before the accepting edge");
    @(posedge clk);
    @(negedge clk);
    bus_req = '0;
  endtask

  initial begin : watchdog
    repeat (40) @(posedge clk);
    $fatal(1, "tb_tick_timer exceeded 40 cycles");
  end

  initial begin
    clk = 0;
    rst_n = 0;
    bus_req = '0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    write_reg(32'h1000_1004, 32'd3);
    write_reg(32'h1000_1000, 32'd3);
    write_reg(32'h1000_1008, 32'd3);
    repeat (4) @(posedge clk);
    #1;
    assert (irq) else $fatal(1, "timer IRQ did not assert at the exact boundary");
    assert (count == 3) else $fatal(1, "timer did not reload");

    write_reg(32'h1000_1010, 32'd1);
    #1;
    assert (!irq) else $fatal(1, "timer ACK did not clear IRQ");
    $display("PASS tb_tick_timer");
    $finish;
  end
endmodule
