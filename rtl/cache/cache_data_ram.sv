`timescale 1ns/1ps
module cache_data_ram #(
  parameter int unsigned DEPTH = 512,
  parameter int unsigned ADDR_W = $clog2(DEPTH)
) (
  input  logic              clk_i,
  input  logic              a_en_i,
  input  logic [7:0]        a_we_i,
  input  logic [ADDR_W-1:0] a_addr_i,
  input  logic [63:0]       a_wdata_i,
  output logic [63:0]       a_rdata_o,
  input  logic              b_en_i,
  input  logic [7:0]        b_we_i,
  input  logic [ADDR_W-1:0] b_addr_i,
  input  logic [63:0]       b_wdata_i,
  output logic [63:0]       b_rdata_o
);
  (* ram_style = "block" *) logic [63:0] mem_q [0:DEPTH-1];

  always_ff @(posedge clk_i) begin
    if (a_en_i) begin
      for (int unsigned byte_idx = 0; byte_idx < 8; byte_idx++)
        if (a_we_i[byte_idx])
          mem_q[a_addr_i][byte_idx*8 +: 8] <= a_wdata_i[byte_idx*8 +: 8];
      a_rdata_o <= mem_q[a_addr_i];
    end
  end

  always_ff @(posedge clk_i) begin
    if (b_en_i) begin
      for (int unsigned byte_idx = 0; byte_idx < 8; byte_idx++)
        if (b_we_i[byte_idx])
          mem_q[b_addr_i][byte_idx*8 +: 8] <= b_wdata_i[byte_idx*8 +: 8];
      b_rdata_o <= mem_q[b_addr_i];
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (a_en_i && b_en_i && (a_addr_i == b_addr_i) &&
        ((|a_we_i) || (|b_we_i)))
      $fatal(1, "cache data RAM cross-port read/write collision addr=%0h", a_addr_i);
  end
`endif
endmodule
