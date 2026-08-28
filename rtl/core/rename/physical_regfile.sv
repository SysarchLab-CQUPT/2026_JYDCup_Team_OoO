`timescale 1ns/1ps
module physical_regfile (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  core_types_pkg::preg_t         read_addr_i [4],
  output logic [31:0]                   read_data_o [4],
  input  logic [1:0]                    alloc_valid_i,
  input  core_types_pkg::preg_t         alloc_preg_i [2],
  input  logic [1:0]                    wb_valid_i,
  input  core_types_pkg::preg_t         wb_preg_i [2],
  input  logic [31:0]                   wb_data_i [2],
  input  logic                          rebuild_ready_valid_i,
  input  logic [soc_cfg_pkg::PHYS_REGS-1:0] rebuild_ready_mask_i,
  output logic [soc_cfg_pkg::PHYS_REGS-1:0] ready_bits_o
);
  import soc_cfg_pkg::*;
  import core_types_pkg::*;

  logic [PHYS_REGS-1:0] ready_q;

  // Keep each pair of read ports with its owning scheduler/EX lane.  The
  // payload copies and live-bank selector no longer form one eight-LUTRAM
  // placement island spanning both issue queues.
  physical_regfile_lane u_lane0 (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .read_addr0_i(read_addr_i[0]), .read_addr1_i(read_addr_i[1]),
    .read_data0_o(read_data_o[0]), .read_data1_o(read_data_o[1]),
    .wb_valid_i(wb_valid_i), .wb_preg_i(wb_preg_i), .wb_data_i(wb_data_i)
  );
  physical_regfile_lane u_lane1 (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .read_addr0_i(read_addr_i[2]), .read_addr1_i(read_addr_i[3]),
    .read_data0_o(read_data_o[2]), .read_data1_o(read_data_o[3]),
    .wb_valid_i(wb_valid_i), .wb_preg_i(wb_preg_i), .wb_data_i(wb_data_i)
  );

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      ready_q <= {{(PHYS_REGS-32){1'b0}}, 32'hffff_ffff};
    end else begin
      if (rebuild_ready_valid_i) ready_q <= rebuild_ready_mask_i;
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (alloc_valid_i[lane] && (alloc_preg_i[lane] != 0))
          ready_q[alloc_preg_i[lane]] <= 1'b0;
        if (wb_valid_i[lane] && (wb_preg_i[lane] != 0)) begin
          ready_q[wb_preg_i[lane]] <= 1'b1;
        end
      end
      ready_q[0] <= 1'b1;
    end
  end

  // Dispatch handles current WB tags locally at its two source operands.  The
  // exported map is persistent state only, avoiding a wide decoded-WB vector
  // followed by a variable-index read in the dispatch-to-IQ write path.
  assign ready_bits_o = ready_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (ready_q[0]) else $fatal(1, "physical p0 invariant failed");
      assert (!(wb_valid_i[0] && wb_valid_i[1] &&
                (wb_preg_i[0] != 0) && (wb_preg_i[0] == wb_preg_i[1])))
        else $fatal(1, "both PRF write ports targeted the same register");
    end
  end
`endif
endmodule
