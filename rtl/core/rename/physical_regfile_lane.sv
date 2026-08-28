`timescale 1ns/1ps
// Two asynchronous PRF read ports local to one execution lane.  Each write
// bank is replicated once per read port, while the live-bank selector is
// duplicated per lane.  This prevents IQ0/IQ1 read addresses from pulling one
// shared selector and eight LUTRAM replicas into a single physical cluster.
(* keep_hierarchy = "yes" *)
module physical_regfile_lane (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  core_types_pkg::preg_t         read_addr0_i,
  input  core_types_pkg::preg_t         read_addr1_i,
  output logic [31:0]                   read_data0_o,
  output logic [31:0]                   read_data1_o,
  input  logic [1:0]                    wb_valid_i,
  input  core_types_pkg::preg_t         wb_preg_i [2],
  input  logic [31:0]                   wb_data_i [2]
);
  import soc_cfg_pkg::*;

  (* ram_style = "distributed" *) logic [31:0] bank0_r0_q [PHYS_REGS];
  (* ram_style = "distributed" *) logic [31:0] bank0_r1_q [PHYS_REGS];
  (* ram_style = "distributed" *) logic [31:0] bank1_r0_q [PHYS_REGS];
  (* ram_style = "distributed" *) logic [31:0] bank1_r1_q [PHYS_REGS];

  // Keep a lane-local selector copy.  Sixty-four extra flops are cheaper than
  // routing every selector bit between both scheduler/EX regions.
  (* keep = "true", max_fanout = 8 *) logic [PHYS_REGS-1:0] latest_bank_q;
  logic [31:0] bank0_read0, bank0_read1;
  logic [31:0] bank1_read0, bank1_read1;

  always_comb begin
    bank0_read0 = bank0_r0_q[read_addr0_i];
    bank0_read1 = bank0_r1_q[read_addr1_i];
    bank1_read0 = bank1_r0_q[read_addr0_i];
    bank1_read1 = bank1_r1_q[read_addr1_i];

    read_data0_o = (read_addr0_i == '0) ? 32'b0 :
      (latest_bank_q[read_addr0_i] ? bank1_read0 : bank0_read0);
    read_data1_o = (read_addr1_i == '0) ? 32'b0 :
      (latest_bank_q[read_addr1_i] ? bank1_read1 : bank0_read1);

    // Pending WB data is merged with EX forwarding once, at the owning EX
    // lane.  Keeping that mux out of every LUTRAM read removes two serial
    // write-through levels from the wakeup -> select -> PRF critical cone.
  end

  // The two physical write banks each have one write port.  Their two local
  // read copies infer distributed RAM without reset.
  always_ff @(posedge clk_i) begin
    if (rst_ni && wb_valid_i[0] && (wb_preg_i[0] != '0)) begin
      bank0_r0_q[wb_preg_i[0]] <= wb_data_i[0];
      bank0_r1_q[wb_preg_i[0]] <= wb_data_i[0];
    end
    if (rst_ni && wb_valid_i[1] && (wb_preg_i[1] != '0)) begin
      bank1_r0_q[wb_preg_i[1]] <= wb_data_i[1];
      bank1_r1_q[wb_preg_i[1]] <= wb_data_i[1];
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      latest_bank_q <= '0;
    end else begin
      if (wb_valid_i[0] && (wb_preg_i[0] != '0))
        latest_bank_q[wb_preg_i[0]] <= 1'b0;
      if (wb_valid_i[1] && (wb_preg_i[1] != '0))
        latest_bank_q[wb_preg_i[1]] <= 1'b1;
    end
  end
endmodule
