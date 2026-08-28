`timescale 1ns/1ps
module tb_rename_map;
  import core_types_pkg::*;
  logic clk, rst_n;
  logic [1:0] rename_valid;
  logic [4:0] rename_rs1 [2], rename_rs2 [2], rename_rd [2];
  logic [1:0] rename_rd_wen;
  preg_t rename_pdst [2], rename_ps1 [2], rename_ps2 [2], stale [2];
  logic [1:0] commit_valid;
  logic [4:0] commit_rd [2];
  preg_t commit_pdst [2];
  logic restore_valid, rebuild;
  preg_t restore_map [32], speculative_map [32], committed_map [32];

  rename_map dut (
    .clk_i(clk), .rst_ni(rst_n), .rename_valid_i(rename_valid),
    .rename_probe_valid_i(rename_valid),
    .rename_rs1_i(rename_rs1), .rename_rs2_i(rename_rs2),
    .rename_rd_i(rename_rd), .rename_rd_wen_i(rename_rd_wen),
    .rename_pdst_i(rename_pdst), .rename_ps1_o(rename_ps1),
    .rename_ps2_o(rename_ps2), .rename_stale_pdst_o(stale),
    .commit_valid_i(commit_valid), .commit_rd_i(commit_rd),
    .commit_pdst_i(commit_pdst), .restore_valid_i(restore_valid),
    .restore_map_i(restore_map), .rebuild_from_commit_i(rebuild),
    .speculative_map_o(speculative_map), .committed_map_o(committed_map)
  );
  always #5 clk = ~clk;

  initial begin
    clk=0; rst_n=0; rename_valid=0; rename_rd_wen=0; commit_valid=0;
    restore_valid=0; rebuild=0;
    for (int i=0;i<2;i++) begin
      rename_rs1[i]=0; rename_rs2[i]=0; rename_rd[i]=0; rename_pdst[i]=0;
      commit_rd[i]=0; commit_pdst[i]=0;
    end
    for (int i=0;i<32;i++) restore_map[i]=preg_t'(i);
    repeat(3) @(posedge clk); rst_n=1;

    @(negedge clk);
    rename_valid=2'b11; rename_rd_wen=2'b11;
    rename_rd[0]=5'd5; rename_pdst[0]=6'd32;
    rename_rs1[1]=5'd5; rename_rs2[1]=5'd2;
    rename_rd[1]=5'd6; rename_pdst[1]=6'd33;
    #1;
    assert (stale[0]==6'd5 && rename_ps1[1]==6'd32 && stale[1]==6'd6)
      else $fatal(1,"same-cycle rename dependency failed");
    @(posedge clk); @(negedge clk); rename_valid=0; rename_rd_wen=0;
    assert (speculative_map[5]==6'd32 && speculative_map[6]==6'd33)
      else $fatal(1,"RAT update failed");

    commit_valid=2'b11; commit_rd[0]=5; commit_pdst[0]=32;
    commit_rd[1]=6; commit_pdst[1]=33;
    @(posedge clk); @(negedge clk); commit_valid=0;
    assert (committed_map[5]==32 && committed_map[6]==33)
      else $fatal(1,"RRAT commit failed");

    rename_valid=1; rename_rd_wen=1; rename_rd[0]=5; rename_pdst[0]=34;
    @(posedge clk); @(negedge clk); rename_valid=0; rename_rd_wen=0; rebuild=1;
    @(posedge clk); @(negedge clk); rebuild=0;
    assert (speculative_map[5]==32) else $fatal(1,"RRAT rebuild failed");

    restore_map[7]=6'd40; restore_valid=1;
    @(posedge clk); @(negedge clk); restore_valid=0;
    assert (speculative_map[7]==40) else $fatal(1,"checkpoint restore failed");
    $display("PASS tb_rename_map"); $finish;
  end
endmodule
