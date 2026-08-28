`timescale 1ns/1ps
module csr_file (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [11:0] read_addr_i,
  output logic [31:0] read_data_o,
  output logic        read_illegal_o,
  input  logic        write_valid_i,
  input  logic [11:0] write_addr_i,
  input  logic [31:0] write_data_i,
  output logic        write_illegal_o,
  input  logic [1:0]  retire_count_i,
  input  logic        timer_irq_i,
  input  logic        external_irq_i,
  input  logic        software_irq_i,
  output logic        interrupt_pending_o,
  output logic [31:0] interrupt_cause_o,
  input  logic        trap_valid_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_cause_i,
  input  logic [31:0] trap_tval_i,
  input  logic        mret_i,
  output logic [31:0] trap_vector_o,
  output logic [31:0] mret_pc_o
);
  logic [31:0] mstatus_q;
  logic [31:0] mie_q;
  logic [31:0] mtvec_q;
  logic [31:0] mscratch_q;
  logic [31:0] mepc_q;
  logic [31:0] mcause_q;
  logic [31:0] mtval_q;
  logic [63:0] mcycle_q;
  logic [63:0] minstret_q;
  logic [31:0] mip;
  logic write_addr_legal;

  always_comb begin
    mip = 32'b0;
    mip[3] = software_irq_i;
    mip[7] = timer_irq_i;
    mip[11] = external_irq_i;

    read_illegal_o = 1'b0;
    unique case (read_addr_i)
      12'h300: read_data_o = mstatus_q;
      12'h301: read_data_o = 32'h4000_1100;
      12'h304: read_data_o = mie_q;
      12'h305: read_data_o = mtvec_q;
      12'h340: read_data_o = mscratch_q;
      12'h341: read_data_o = mepc_q;
      12'h342: read_data_o = mcause_q;
      12'h343: read_data_o = mtval_q;
      12'h344: read_data_o = mip;
      12'hb00, 12'hc00: read_data_o = mcycle_q[31:0];
      12'hb80, 12'hc80: read_data_o = mcycle_q[63:32];
      12'hb02, 12'hc02: read_data_o = minstret_q[31:0];
      12'hb82, 12'hc82: read_data_o = minstret_q[63:32];
      12'hf11: read_data_o = 32'b0;
      12'hf12: read_data_o = 32'b0;
      12'hf13: read_data_o = 32'b0;
      12'hf14: read_data_o = 32'b0;
      default: begin read_data_o = 32'b0; read_illegal_o = 1'b1; end
    endcase

    write_addr_legal = write_addr_i inside {
      12'h300, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343,
      12'hb00, 12'hb80, 12'hb02, 12'hb82
    };
    write_illegal_o = write_valid_i &&
                      (!write_addr_legal || (write_addr_i[11:10] == 2'b11));

    interrupt_pending_o = 1'b0;
    interrupt_cause_o = 32'b0;
    if (mstatus_q[3]) begin
      if (mie_q[11] && mip[11]) begin
        interrupt_pending_o = 1'b1;
        interrupt_cause_o = 32'h8000_000b;
      end else if (mie_q[7] && mip[7]) begin
        interrupt_pending_o = 1'b1;
        interrupt_cause_o = 32'h8000_0007;
      end else if (mie_q[3] && mip[3]) begin
        interrupt_pending_o = 1'b1;
        interrupt_cause_o = 32'h8000_0003;
      end
    end
    trap_vector_o = {mtvec_q[31:2], 2'b00};
    mret_pc_o = mepc_q;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      mstatus_q <= 32'b0;
      mie_q <= 32'b0;
      mtvec_q <= '0;
      mscratch_q <= '0;
      mepc_q <= '0;
      mcause_q <= '0;
      mtval_q <= '0;
      mcycle_q <= '0;
      minstret_q <= '0;
    end else begin
      mcycle_q <= mcycle_q + 1'b1;
      minstret_q <= minstret_q + {{62{1'b0}}, retire_count_i};
      if (write_valid_i && !write_illegal_o) begin
        unique case (write_addr_i)
          12'h300: begin
            mstatus_q[3] <= write_data_i[3];
            mstatus_q[7] <= write_data_i[7];
            mstatus_q[12:11] <= write_data_i[12:11];
          end
          12'h304: mie_q <= write_data_i & 32'h0000_0888;
          12'h305: mtvec_q <= {write_data_i[31:2], 2'b00};
          12'h340: mscratch_q <= write_data_i;
          12'h341: mepc_q <= {write_data_i[31:2], 2'b00};
          12'h342: mcause_q <= write_data_i;
          12'h343: mtval_q <= write_data_i;
          12'hb00: mcycle_q[31:0] <= write_data_i;
          12'hb80: mcycle_q[63:32] <= write_data_i;
          12'hb02: minstret_q[31:0] <= write_data_i;
          12'hb82: minstret_q[63:32] <= write_data_i;
          default: begin end
        endcase
      end
      if (trap_valid_i) begin
        mepc_q <= {trap_pc_i[31:2], 2'b00};
        mcause_q <= trap_cause_i;
        mtval_q <= trap_tval_i;
        mstatus_q[7] <= mstatus_q[3];
        mstatus_q[3] <= 1'b0;
        mstatus_q[12:11] <= 2'b11;
      end else if (mret_i) begin
        mstatus_q[3] <= mstatus_q[7];
        mstatus_q[7] <= 1'b1;
        mstatus_q[12:11] <= 2'b00;
      end
    end
  end
endmodule
