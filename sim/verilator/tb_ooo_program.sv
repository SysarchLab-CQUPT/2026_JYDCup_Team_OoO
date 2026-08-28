`timescale 1ns/1ps
module tb_ooo_program;
  import core_types_pkg::*;
  logic clk,rst_n;
  logic imem_req_valid,imem_req_ready;
  logic[31:0]imem_req_addr;
  logic[3:0]imem_req_epoch;
  logic imem_rsp_valid,imem_rsp_ready,imem_rsp_error;
  logic[31:0]imem_rsp_addr;
  logic[3:0]imem_rsp_epoch;
  logic[63:0]imem_rsp_data;
  logic icache_flush;
  logic dcache_clean_req;
  logic dmem_req_valid,dmem_req_ready,dmem_req_write;
  logic[31:0]dmem_req_addr,dmem_req_wdata,dmem_rsp_data;
  logic[3:0]dmem_req_wstrb;
  logic[3:0]dmem_req_seq,dmem_rsp_seq;
  uop_id_t dmem_req_uop_id,dmem_rsp_uop_id;
  logic dmem_rsp_valid,dmem_rsp_error;
  commit_trace_t trace[2];
  logic[31:0]debug_pc;
  logic[5:0]debug_rob_count;
  logic[31:0]mem[0:65535];
  int unsigned cycles;

  ooo_core dut(
    .clk_i(clk),.rst_ni(rst_n),.imem_req_valid_o(imem_req_valid),
    .imem_req_ready_i(imem_req_ready),.imem_req_addr_o(imem_req_addr),
    .imem_req_epoch_o(imem_req_epoch),.imem_rsp_valid_i(imem_rsp_valid),
    .imem_rsp_ready_o(imem_rsp_ready),.imem_rsp_addr_i(imem_rsp_addr),
    .imem_rsp_epoch_i(imem_rsp_epoch),.imem_rsp_data_i(imem_rsp_data),
    .imem_rsp_error_i(imem_rsp_error),.icache_flush_o(icache_flush),
    .dcache_idle_i(1'b1),.dcache_clean_req_o(dcache_clean_req),
    .dcache_clean_done_i(1'b1),
    .dmem_req_valid_o(dmem_req_valid),
    .dmem_req_ready_i(dmem_req_ready),.dmem_req_write_o(dmem_req_write),
    .dmem_req_addr_o(dmem_req_addr),.dmem_req_wdata_o(dmem_req_wdata),
    .dmem_req_wstrb_o(dmem_req_wstrb),.dmem_req_seq_o(dmem_req_seq),
    .dmem_req_uop_id_o(dmem_req_uop_id),.dmem_rsp_valid_i(dmem_rsp_valid),
    .dmem_rsp_data_i(dmem_rsp_data),.dmem_rsp_error_i(dmem_rsp_error),
    .dmem_rsp_seq_i(dmem_rsp_seq),.dmem_rsp_uop_id_i(dmem_rsp_uop_id),
    .timer_irq_i(1'b0),.external_irq_i(1'b0),.commit_trace_o(trace),
    .debug_pc_o(debug_pc),.debug_rob_count_o(debug_rob_count)
  );

  always #5 clk=~clk;
  assign imem_req_ready=1'b1;
  assign dmem_req_ready=1'b1;

  function automatic logic[31:0] enc_i(
    input logic[11:0]imm,input logic[4:0]rs1,input logic[2:0]f3,
    input logic[4:0]rd,input logic[6:0]opc);
    return {imm,rs1,f3,rd,opc};
  endfunction
  function automatic logic[31:0] enc_r(
    input logic[6:0]f7,input logic[4:0]rs2,input logic[4:0]rs1,
    input logic[2:0]f3,input logic[4:0]rd);
    return {f7,rs2,rs1,f3,rd,7'b0110011};
  endfunction
  function automatic logic[31:0] enc_s(
    input logic[11:0]imm,input logic[4:0]rs2,input logic[4:0]rs1,input logic[2:0]f3);
    return {imm[11:5],rs2,rs1,f3,imm[4:0],7'b0100011};
  endfunction
  function automatic logic[31:0] enc_b(
    input logic[12:0]imm,input logic[4:0]rs2,input logic[4:0]rs1,input logic[2:0]f3);
    return {imm[12],imm[10:5],rs2,rs1,f3,imm[4:1],imm[11],7'b1100011};
  endfunction

  always_ff @(posedge clk) begin
    imem_rsp_valid<=1'b0;
    if(imem_req_valid&&imem_req_ready)begin
      imem_rsp_valid<=1'b1;
      imem_rsp_addr<=imem_req_addr;
      imem_rsp_epoch<=imem_req_epoch;
      imem_rsp_data<={mem[((imem_req_addr>>2)&32'hffff_fffe)+1],
                       mem[(imem_req_addr>>2)&32'hffff_fffe]};
      imem_rsp_error<=1'b0;
    end
    dmem_rsp_valid<=1'b0;
    if(dmem_req_valid&&dmem_req_ready)begin
      if(dmem_req_write)begin
        for(int byte_idx=0;byte_idx<4;byte_idx++)
          if(dmem_req_wstrb[byte_idx])
            mem[dmem_req_addr>>2][byte_idx*8+:8]<=dmem_req_wdata[byte_idx*8+:8];
      end else begin
        dmem_rsp_valid<=1'b1;
        dmem_rsp_data<=mem[dmem_req_addr>>2];
        dmem_rsp_error<=1'b0;
        dmem_rsp_seq<=dmem_req_seq;
        dmem_rsp_uop_id<=dmem_req_uop_id;
      end
    end
    if(rst_n)begin
      cycles<=cycles+1;
      for(int lane=0;lane<2;lane++)if(trace[lane].valid)
        $display("COMMIT lane=%0d pc=%08x inst=%08x rd=%0d data=%08x",
                 lane,trace[lane].pc,trace[lane].inst,trace[lane].rd_addr,trace[lane].rd_data);
      if(mem[32'h200>>2]==32'd60&&mem[32'h204>>2]==32'd2)begin
        $display("PASS tb_ooo_program cycles=%0d",cycles);
        $finish;
      end
      if(cycles>5000)$fatal(1,"program timeout pc=%08x rob=%0d sig0=%08x sig1=%08x",
                            debug_pc,debug_rob_count,mem[32'h200>>2],mem[32'h204>>2]);
    end
  end

  initial begin
    clk=0;rst_n=0;imem_rsp_valid=0;imem_rsp_addr=0;imem_rsp_epoch=0;
    imem_rsp_data=0;imem_rsp_error=0;
    dmem_rsp_valid=0;dmem_rsp_data=0;dmem_rsp_error=0;
    dmem_rsp_seq=0;dmem_rsp_uop_id=0;cycles=0;
    for(int i=0;i<65536;i++)mem[i]=32'h0000_0013;
    mem[0]=enc_i(12'd5,0,3'b000,1,7'b0010011);
    mem[1]=enc_i(12'd7,0,3'b000,2,7'b0010011);
    mem[2]=enc_r(7'b0000000,2,1,3'b000,3);
    mem[3]=enc_r(7'b0000001,1,3,3'b000,4);
    mem[4]=enc_s(12'h200,4,0,3'b010);
    mem[5]=enc_i(12'h200,0,3'b010,5,7'b0000011);
    mem[6]=enc_b(13'd8,4,5,3'b000);
    mem[7]=enc_i(12'd1,0,3'b000,6,7'b0010011);
    mem[8]=enc_i(12'd2,0,3'b000,6,7'b0010011);
    mem[9]=enc_s(12'h204,6,0,3'b010);
    mem[10]=32'h0000_006f;
    repeat(5)@(posedge clk);@(negedge clk);rst_n=1;
  end
endmodule
