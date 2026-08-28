`timescale 1ns/1ps
module tb_physical_regfile;
  import soc_cfg_pkg::*;
  import core_types_pkg::*;
  logic clk, rst_n;
  preg_t read_addr [4], alloc_preg [2], wb_preg [2];
  logic [31:0] read_data [4], wb_data [2];
  logic [1:0] alloc_valid, wb_valid;
  logic rebuild_valid;
  logic [PHYS_REGS-1:0] rebuild_mask, ready;

  physical_regfile dut (
    .clk_i(clk),.rst_ni(rst_n),.read_addr_i(read_addr),.read_data_o(read_data),
    .alloc_valid_i(alloc_valid),.alloc_preg_i(alloc_preg),.wb_valid_i(wb_valid),
    .wb_preg_i(wb_preg),.wb_data_i(wb_data),.rebuild_ready_valid_i(rebuild_valid),
    .rebuild_ready_mask_i(rebuild_mask),.ready_bits_o(ready)
  );
  always #5 clk=~clk;

  initial begin
    clk=0;rst_n=0;alloc_valid=0;wb_valid=0;rebuild_valid=0;rebuild_mask='0;
    for(int i=0;i<4;i++) read_addr[i]=0;
    for(int i=0;i<2;i++) begin alloc_preg[i]=0;wb_preg[i]=0;wb_data[i]=0;end
    repeat(3) @(posedge clk);rst_n=1;
    assert (&ready[31:0] && !(|ready[63:32])) else $fatal(1,"PRF reset ready mask");

    @(negedge clk);alloc_valid=1;alloc_preg[0]=32;
    @(posedge clk);@(negedge clk);alloc_valid=0;
    assert(!ready[32]) else $fatal(1,"allocated preg remained ready");
    wb_valid=1;wb_preg[0]=32;wb_data[0]=32'hcafe_babe;read_addr[0]=32;
    @(posedge clk);@(negedge clk);wb_valid=0;
    assert(ready[32] && read_data[0]==32'hcafe_babe) else $fatal(1,"WB state");
    read_addr[1]=0;assert(read_data[1]==0) else $fatal(1,"p0 read");

    // Exercise both physical write banks and a later live-value-bank switch.
    wb_valid=2'b11; wb_preg[0]=33; wb_data[0]=32'h1111_aaaa;
    wb_preg[1]=34; wb_data[1]=32'h2222_bbbb;
    read_addr[0]=33; read_addr[1]=34;
    @(posedge clk); @(negedge clk); wb_valid=0; #1;
    assert(read_data[0]==32'h1111_aaaa && read_data[1]==32'h2222_bbbb)
      else $fatal(1,"dual-bank WB state");
    wb_valid=2'b01; wb_preg[0]=34; wb_data[0]=32'h3333_cccc;
    @(posedge clk); @(negedge clk); wb_valid=0; #1;
    assert(read_data[1]==32'h3333_cccc)
      else $fatal(1,"live-value bank did not switch");

    // The storage primitive exposes the last clocked value while a new WB is
    // pending.  The owning EX lane performs the single shared write-through
    // merge together with its other forwarding sources.
    @(negedge clk);
    read_addr[2]=34; wb_valid=2'b01; wb_preg[0]=34;
    wb_data[0]=32'h4444_dddd; #1;
    assert(read_data[2]==32'h3333_cccc)
      else $fatal(1,"PRF storage changed before WB edge");
    assert(!ready[35])
      else $fatal(1,"persistent ready mask changed before WB edge");
    @(posedge clk); @(negedge clk); wb_valid=0; #1;
    assert(read_data[2]==32'h4444_dddd)
      else $fatal(1,"clocked WB storage update missing");
    $display("PASS tb_physical_regfile");$finish;
  end
endmodule
