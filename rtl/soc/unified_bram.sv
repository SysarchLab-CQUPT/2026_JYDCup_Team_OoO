`timescale 1ns/1ps
module unified_bram #(
  parameter int unsigned BYTES = 64 * 1024,
  parameter string INIT_FILE = ""
) (
  input  logic                         clk_i,
  input  logic                         a_en_i,
  input  logic [$clog2(BYTES/8)-1:0]   a_addr_i,
  output logic [63:0]                  a_rdata_o,
  input  logic                         b_en_i,
  input  logic [7:0]                   b_we_i,
  input  logic [$clog2(BYTES/8)-1:0]   b_addr_i,
  input  logic [63:0]                  b_wdata_i,
  output logic [63:0]                  b_rdata_o
);
  localparam int unsigned DEPTH = BYTES / 8;
  (* ram_style = "block" *) logic [63:0] mem [0:DEPTH-1];

  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  always_ff @(posedge clk_i) begin
    if (a_en_i) begin
      a_rdata_o <= mem[a_addr_i];
    end
    if (b_en_i) begin
      b_rdata_o <= mem[b_addr_i];
      for (int unsigned byte_idx = 0; byte_idx < 8; byte_idx++) begin
        if (b_we_i[byte_idx]) begin
          mem[b_addr_i][byte_idx*8 +: 8] <= b_wdata_i[byte_idx*8 +: 8];
        end
      end
    end
  end
endmodule
