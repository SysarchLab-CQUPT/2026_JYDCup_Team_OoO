`timescale 1ns/1ps
module rename_map (
  input  logic                      clk_i,
  input  logic                      rst_ni,

  input  logic [1:0]                rename_valid_i,
  input  logic [1:0]                rename_probe_valid_i,
  input  logic [4:0]                rename_rs1_i [2],
  input  logic [4:0]                rename_rs2_i [2],
  input  logic [4:0]                rename_rd_i [2],
  input  logic [1:0]                rename_rd_wen_i,
  input  core_types_pkg::preg_t     rename_pdst_i [2],
  output core_types_pkg::preg_t     rename_ps1_o [2],
  output core_types_pkg::preg_t     rename_ps2_o [2],
  output core_types_pkg::preg_t     rename_stale_pdst_o [2],

  input  logic [1:0]                commit_valid_i,
  input  logic [4:0]                commit_rd_i [2],
  input  core_types_pkg::preg_t     commit_pdst_i [2],

  input  logic                      restore_valid_i,
  input  core_types_pkg::preg_t     restore_map_i [32],
  input  logic                      rebuild_from_commit_i,

  output core_types_pkg::preg_t     speculative_map_o [32],
  output core_types_pkg::preg_t     committed_map_o [32]
);
  import core_types_pkg::*;

  preg_t rat_q [32];
  preg_t rrat_q [32];

  always_comb begin
    rename_ps1_o[0] = rat_q[rename_rs1_i[0]];
    rename_ps2_o[0] = rat_q[rename_rs2_i[0]];
    rename_stale_pdst_o[0] = rat_q[rename_rd_i[0]];

    rename_ps1_o[1] = rat_q[rename_rs1_i[1]];
    rename_ps2_o[1] = rat_q[rename_rs2_i[1]];
    rename_stale_pdst_o[1] = rat_q[rename_rd_i[1]];
    if (rename_probe_valid_i[0] && rename_rd_wen_i[0] && (rename_rd_i[0] != 0)) begin
      if (rename_rs1_i[1] == rename_rd_i[0]) rename_ps1_o[1] = rename_pdst_i[0];
      if (rename_rs2_i[1] == rename_rd_i[0]) rename_ps2_o[1] = rename_pdst_i[0];
      if (rename_rd_i[1] == rename_rd_i[0]) rename_stale_pdst_o[1] = rename_pdst_i[0];
    end

    for (int unsigned i = 0; i < 32; i++) begin
      speculative_map_o[i] = rat_q[i];
      committed_map_o[i] = rrat_q[i];
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < 32; i++) begin
        rat_q[i] <= preg_t'(i);
        rrat_q[i] <= preg_t'(i);
      end
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (commit_valid_i[lane] && (commit_rd_i[lane] != 0)) begin
          rrat_q[commit_rd_i[lane]] <= commit_pdst_i[lane];
        end
      end

      if (rebuild_from_commit_i) begin
        for (int unsigned i = 0; i < 32; i++) rat_q[i] <= rrat_q[i];
        // Same-cycle commits are architecturally older than the rebuild.
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (commit_valid_i[lane] && (commit_rd_i[lane] != 0))
            rat_q[commit_rd_i[lane]] <= commit_pdst_i[lane];
        end
      end else if (restore_valid_i) begin
        for (int unsigned i = 0; i < 32; i++) rat_q[i] <= restore_map_i[i];
      end else begin
        if (rename_valid_i[0] && rename_rd_wen_i[0] && (rename_rd_i[0] != 0))
          rat_q[rename_rd_i[0]] <= rename_pdst_i[0];
        if (rename_valid_i[1] && rename_rd_wen_i[1] && (rename_rd_i[1] != 0))
          rat_q[rename_rd_i[1]] <= rename_pdst_i[1];
      end
      rat_q[0] <= '0;
      rrat_q[0] <= '0;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (rat_q[0] == 0 && rrat_q[0] == 0)
        else $fatal(1, "architectural x0 mapping changed");
    end
  end
`endif
endmodule
