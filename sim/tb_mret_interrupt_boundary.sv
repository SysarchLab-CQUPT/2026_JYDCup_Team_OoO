`timescale 1ns/1ps
module tb_mret_interrupt_boundary;
  import core_types_pkg::*;

  logic clk, rst_n;
  logic imem_req_valid, imem_req_ready;
  logic [31:0] imem_req_addr;
  logic [3:0] imem_req_epoch;
  logic imem_rsp_valid, imem_rsp_ready, imem_rsp_error;
  logic [31:0] imem_rsp_addr;
  logic [3:0] imem_rsp_epoch;
  logic [63:0] imem_rsp_data;
  logic icache_flush;
  logic dcache_clean_req;
  logic dmem_req_valid, dmem_req_ready, dmem_req_write;
  logic [31:0] dmem_req_addr, dmem_req_wdata, dmem_rsp_data;
  logic [3:0] dmem_req_wstrb;
  logic [3:0] dmem_req_seq, dmem_rsp_seq;
  uop_id_t dmem_req_uop_id, dmem_rsp_uop_id;
  logic dmem_rsp_valid, dmem_rsp_error;
  commit_trace_t trace [2];
  logic [31:0] debug_pc;
  logic [5:0] debug_rob_count;
  logic [31:0] mem [0:255];
  int unsigned cycles;

  ooo_core dut (
    .clk_i(clk), .rst_ni(rst_n),
    .imem_req_valid_o(imem_req_valid),
    .imem_req_ready_i(imem_req_ready),
    .imem_req_addr_o(imem_req_addr),
    .imem_req_epoch_o(imem_req_epoch),
    .imem_rsp_valid_i(imem_rsp_valid),
    .imem_rsp_ready_o(imem_rsp_ready),
    .imem_rsp_addr_i(imem_rsp_addr),
    .imem_rsp_epoch_i(imem_rsp_epoch),
    .imem_rsp_data_i(imem_rsp_data),
    .imem_rsp_error_i(imem_rsp_error),
    .icache_flush_o(icache_flush),
    .dcache_idle_i(1'b1),
    .dcache_clean_req_o(dcache_clean_req),
    .dcache_clean_done_i(1'b1),
    .dmem_req_valid_o(dmem_req_valid),
    .dmem_req_ready_i(dmem_req_ready),
    .dmem_req_write_o(dmem_req_write),
    .dmem_req_addr_o(dmem_req_addr),
    .dmem_req_wdata_o(dmem_req_wdata),
    .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_req_seq_o(dmem_req_seq),
    .dmem_req_uop_id_o(dmem_req_uop_id),
    .dmem_rsp_valid_i(dmem_rsp_valid),
    .dmem_rsp_data_i(dmem_rsp_data),
    .dmem_rsp_error_i(dmem_rsp_error),
    .dmem_rsp_seq_i(dmem_rsp_seq),
    .dmem_rsp_uop_id_i(dmem_rsp_uop_id),
    .timer_irq_i(1'b1),
    .external_irq_i(1'b0),
    .commit_trace_o(trace),
    .debug_pc_o(debug_pc),
    .debug_rob_count_o(debug_rob_count)
  );

  always #5 clk = ~clk;
  assign imem_req_ready = 1'b1;
  assign dmem_req_ready = 1'b1;

  function automatic logic [31:0] enc_i(
    input logic [11:0] imm,
    input logic [4:0] rs1,
    input logic [2:0] funct3,
    input logic [4:0] rd,
    input logic [6:0] opcode
  );
    return {imm, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_s(
    input logic [11:0] imm,
    input logic [4:0] rs2,
    input logic [4:0] rs1,
    input logic [2:0] funct3
  );
    return {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'b0100011};
  endfunction

  function automatic logic [31:0] enc_csr(
    input logic [11:0] csr,
    input logic [4:0] rs1,
    input logic [2:0] funct3,
    input logic [4:0] rd
  );
    return {csr, rs1, funct3, rd, 7'b1110011};
  endfunction

  always @(posedge clk) begin
    imem_rsp_valid <= 1'b0;
    if (imem_req_valid && imem_req_ready) begin
      imem_rsp_valid <= 1'b1;
      imem_rsp_addr <= imem_req_addr;
      imem_rsp_epoch <= imem_req_epoch;
      imem_rsp_data <= {
        mem[((imem_req_addr >> 2) & 32'hffff_fffe) + 1],
        mem[(imem_req_addr >> 2) & 32'hffff_fffe]
      };
      imem_rsp_error <= 1'b0;
    end

    dmem_rsp_valid <= 1'b0;
    if (dmem_req_valid && dmem_req_ready) begin
      if (dmem_req_write) begin
        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (dmem_req_wstrb[byte_idx])
            mem[dmem_req_addr >> 2][byte_idx*8 +: 8] <=
              dmem_req_wdata[byte_idx*8 +: 8];
        end
      end else begin
        dmem_rsp_valid <= 1'b1;
        dmem_rsp_data <= mem[dmem_req_addr >> 2];
        dmem_rsp_error <= 1'b0;
        dmem_rsp_seq <= dmem_req_seq;
        dmem_rsp_uop_id <= dmem_req_uop_id;
      end
    end

    if (rst_n) begin
      cycles <= cycles + 1;
      if (mem[32'h200 >> 2] != 32'b0 &&
          mem[32'h204 >> 2] != 32'b0) begin
        assert (mem[32'h200 >> 2] == 32'h0000_0040)
          else $fatal(1,
            "interrupt after MRET saved wrong mepc: got %08x expected 00000040",
            mem[32'h200 >> 2]);
        assert (mem[32'h204 >> 2] == 32'h8000_0007)
          else $fatal(1,
            "interrupt after MRET saved wrong mcause: got %08x expected 80000007",
            mem[32'h204 >> 2]);
        $display("PASS tb_mret_interrupt_boundary cycles=%0d mepc=%08x mcause=%08x",
                 cycles, mem[32'h200 >> 2], mem[32'h204 >> 2]);
        $finish;
      end
      if (cycles > 5000)
        $fatal(1,
          "MRET interrupt boundary timeout pc=%08x rob=%0d mepc_sig=%08x cause_sig=%08x",
          debug_pc, debug_rob_count,
          mem[32'h200 >> 2], mem[32'h204 >> 2]);
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    imem_rsp_valid = 1'b0;
    imem_rsp_addr = '0;
    imem_rsp_epoch = '0;
    imem_rsp_data = 64'b0;
    imem_rsp_error = 1'b0;
    dmem_rsp_valid = 1'b0;
    dmem_rsp_data = 32'b0;
    dmem_rsp_error = 1'b0;
    dmem_rsp_seq = 4'b0;
    dmem_rsp_uop_id = '0;
    cycles = 0;
    for (int index = 0; index < 256; index++)
      mem[index] = 32'h0000_0013;
    mem[32'h200 >> 2] = 32'b0;
    mem[32'h204 >> 2] = 32'b0;

    // Prepare an MRET that restores MIE while MTIP is already asserted.
    // The interrupt must save the MRET target (0x40), not the sequential PC
    // after the MRET instruction (0x24).
    mem[0] = enc_i(12'h080, 5'd0, 3'b000, 5'd1, 7'b0010011);
    mem[1] = enc_csr(12'h305, 5'd1, 3'b001, 5'd0); // csrw mtvec, x1
    mem[2] = enc_i(12'h040, 5'd0, 3'b000, 5'd1, 7'b0010011);
    mem[3] = enc_csr(12'h341, 5'd1, 3'b001, 5'd0); // csrw mepc, x1
    mem[4] = enc_i(12'h080, 5'd0, 3'b000, 5'd1, 7'b0010011);
    mem[5] = enc_csr(12'h300, 5'd1, 3'b001, 5'd0); // MPIE=1, MIE=0
    mem[6] = enc_csr(12'h304, 5'd1, 3'b001, 5'd0); // MTIE=1
    mem[7] = 32'h0000_0013;
    mem[8] = 32'h3020_0073;                         // mret at 0x20
    mem[16] = 32'h0000_006f;                       // target 0x40

    // Timer interrupt handler at mtvec=0x80 records the architectural CSRs.
    mem[32] = enc_csr(12'h341, 5'd0, 3'b010, 5'd2); // csrr x2, mepc
    mem[33] = enc_csr(12'h342, 5'd0, 3'b010, 5'd3); // csrr x3, mcause
    mem[34] = enc_s(12'h200, 5'd2, 5'd0, 3'b010);
    mem[35] = enc_s(12'h204, 5'd3, 5'd0, 3'b010);
    mem[36] = 32'h0000_006f;

    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end
endmodule
