`timescale 1ns/1ps
module tb_csr_file;
  logic clk,rst_n;
  logic [11:0] read_addr,write_addr;
  logic [31:0] read_data,write_data;
  logic read_illegal,write_valid,write_illegal;
  logic [1:0] retire_count;
  logic timer_irq,external_irq,software_irq,interrupt_pending;
  logic [31:0] interrupt_cause;
  logic trap_valid,mret;
  logic [31:0] trap_pc,trap_cause,trap_tval,trap_vector,mret_pc;

  csr_file dut(
    .clk_i(clk),.rst_ni(rst_n),.read_addr_i(read_addr),.read_data_o(read_data),
    .read_illegal_o(read_illegal),.write_valid_i(write_valid),.write_addr_i(write_addr),
    .write_data_i(write_data),.write_illegal_o(write_illegal),.retire_count_i(retire_count),
    .timer_irq_i(timer_irq),.external_irq_i(external_irq),.software_irq_i(software_irq),
    .interrupt_pending_o(interrupt_pending),.interrupt_cause_o(interrupt_cause),
    .trap_valid_i(trap_valid),.trap_pc_i(trap_pc),.trap_cause_i(trap_cause),
    .trap_tval_i(trap_tval),.mret_i(mret),.trap_vector_o(trap_vector),.mret_pc_o(mret_pc)
  );
  always #5 clk=~clk;
  task automatic write_csr(input logic[11:0] addr,input logic[31:0] data);
    @(negedge clk);write_addr=addr;write_data=data;write_valid=1;#1;
    assert(!write_illegal)else $fatal(1,"legal CSR write rejected");
    @(posedge clk);@(negedge clk);write_valid=0;
  endtask

  initial begin
    clk=0;rst_n=0;read_addr=0;write_addr=0;write_data=0;write_valid=0;
    retire_count=0;timer_irq=0;external_irq=0;software_irq=0;trap_valid=0;
    trap_pc=0;trap_cause=0;trap_tval=0;mret=0;
    repeat(3)@(posedge clk);rst_n=1;
    read_addr=12'h301;#1;assert(read_data==32'h4000_1100&&!read_illegal)
      else $fatal(1,"misa value");
    write_csr(12'h305,32'h0000_0101);assert(trap_vector==32'h100)else $fatal(1,"mtvec mask");
    write_csr(12'h304,32'h0000_0080);
    write_csr(12'h300,32'h0000_0008);
    timer_irq=1;#1;assert(interrupt_pending&&interrupt_cause==32'h8000_0007)
      else $fatal(1,"timer interrupt priority/enable");

    @(negedge clk);trap_valid=1;trap_pc=32'h1237;trap_cause=32'h8000_0007;trap_tval=0;
    @(posedge clk);@(negedge clk);trap_valid=0;#1;
    assert(!interrupt_pending&&mret_pc==32'h1234)else $fatal(1,"trap entry state");
    read_addr=12'h342;#1;assert(read_data==32'h8000_0007)else $fatal(1,"mcause");
    mret=1;@(posedge clk);@(negedge clk);mret=0;#1;
    assert(interrupt_pending)else $fatal(1,"mret did not restore MIE");

    write_csr(12'h341,32'h0000_567b);#1;
    assert(mret_pc==32'h0000_5678)else $fatal(1,"mepc software write did not enforce IALIGN=32");

    write_addr=12'hc00;write_valid=1;#1;assert(write_illegal)
      else $fatal(1,"read-only CSR write accepted");
    write_valid=0;read_addr=12'h123;#1;assert(read_illegal)
      else $fatal(1,"unknown CSR read accepted");
    $display("PASS tb_csr_file");$finish;
  end
endmodule
