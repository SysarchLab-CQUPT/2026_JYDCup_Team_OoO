`timescale 1ns/1ps
module tb_dmem_response_collision;
  logic clk, rst_n;
  logic uart_tx, timer_irq, ext_irq;
  logic [31:0] debug_pc, timer_count;
  logic [5:0] debug_rob_count;
  logic [3:0] irq_pending;

  ooo_soc_system dut (
    .clk_i(clk), .rst_ni(rst_n), .uart_rx_i(1'b1), .uart_tx_o(uart_tx),
    .timer_irq_o(timer_irq), .ext_irq_o(ext_irq), .debug_pc_o(debug_pc),
    .debug_rob_count_o(debug_rob_count), .timer_count_o(timer_count),
    .irq_pending_o(irq_pending)
  );

  always #5 clk = ~clk;

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);

    force dut.core_dmem_req_valid = 1'b1;
    force dut.core_dmem_req_write = 1'b0;
    force dut.core_dmem_req_addr = 32'h1000_2000;
    force dut.core_dmem_req_wdata = 32'b0;
    force dut.core_dmem_req_wstrb = 4'b0;
    force dut.core_dmem_req_seq = 4'h5;
    force dut.core_dmem_req_uop_id = 8'ha5;
    force dut.core_dmem_load_valid = 1'b1;
    force dut.core_dmem_load_addr = 32'h1000_2000;
    force dut.core_dmem_store_valid = 1'b0;
    force dut.core_dmem_store_addr = 32'h1000_2000;

    // The core-facing ready is the registered FIFO occupancy, not D-cache or
    // MMIO ready.  Accept the request, then prove that the fabric head remains
    // blocked until every possible D-cache response has drained.
    force dut.dcache_idle = 1'b0;
    #1;
    assert (dut.core_dmem_req_ready)
      else $fatal(1, "empty request FIFO did not decouple core ready");
    @(posedge clk); @(negedge clk);
    force dut.core_dmem_req_valid = 1'b0;
    force dut.core_dmem_load_valid = 1'b0;
    #1;
    assert (dut.fabric_dmem_req_valid && !dut.fabric_dmem_req_ready)
      else $fatal(1, "MMIO load wait mismatch valid=%0b ready=%0b count=%0d buffered=%0b write=%0b addr=%08x",
                  dut.fabric_dmem_req_valid, dut.fabric_dmem_req_ready,
                  dut.u_dmem_request_fifo.count_q, dut.buffered_dmem_valid,
                  dut.buffered_dmem_write, dut.buffered_dmem_addr);
    assert (!dut.bypass_rsp_valid_q)
      else $fatal(1, "blocked MMIO load generated an early bypass response");

    force dut.dcache_idle = 1'b1;
    #1;
    assert (dut.fabric_dmem_req_ready)
      else $fatal(1, "MMIO load remained blocked after D-cache became idle");
    @(posedge clk); @(negedge clk);
    assert (dut.bypass_rsp_valid_q && dut.bypass_rsp_seq_q == 4'h5 &&
            dut.bypass_rsp_uop_id_q == 8'ha5)
      else $fatal(1, "deferred MMIO response identity was not preserved");
    @(posedge clk); @(negedge clk);

    // Stores produce no bypass response; once queued, the fabric may consume
    // them without waiting for D-cache response quiescence.
    force dut.core_dmem_req_valid = 1'b1;
    force dut.core_dmem_req_write = 1'b1;
    force dut.core_dmem_store_valid = 1'b1;
    force dut.dcache_idle = 1'b0;
    #1;
    assert (dut.core_dmem_req_ready)
      else $fatal(1, "MMIO store could not enter empty request FIFO");
    assert (!dut.fabric_dmem_req_valid)
      else $fatal(1, "MMIO store bypassed its registered fabric boundary");
    @(posedge clk); @(negedge clk);
    force dut.core_dmem_req_valid = 1'b0;
    force dut.core_dmem_store_valid = 1'b0;
    #1;
    assert (dut.fabric_dmem_req_valid && dut.fabric_dmem_req_ready)
      else $fatal(1, "registered MMIO store did not reach the idle fabric");
    @(posedge clk); @(negedge clk);
    assert (!dut.fabric_dmem_req_valid && !dut.bypass_rsp_valid_q)
      else $fatal(1, "registered MMIO store was duplicated or generated a response");

    release dut.core_dmem_req_valid;
    release dut.core_dmem_req_write;
    release dut.core_dmem_req_addr;
    release dut.core_dmem_req_wdata;
    release dut.core_dmem_req_wstrb;
    release dut.core_dmem_req_seq;
    release dut.core_dmem_req_uop_id;
    release dut.core_dmem_load_valid;
    release dut.core_dmem_load_addr;
    release dut.core_dmem_store_valid;
    release dut.core_dmem_store_addr;
    release dut.dcache_idle;
    $display("PASS tb_dmem_response_collision");
    $finish;
  end
endmodule
