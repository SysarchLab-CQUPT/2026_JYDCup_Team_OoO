`timescale 1ns/1ps
module reset_sync (
  input  logic clk_i,
  input  logic arst_ni,
  output logic rst_no
);
  (* ASYNC_REG = "TRUE" *) logic [1:0] sync_q;

  always_ff @(posedge clk_i or negedge arst_ni) begin
    if (!arst_ni) begin
      sync_q <= 2'b00;
    end else begin
      sync_q <= {sync_q[0], 1'b1};
    end
  end

  assign rst_no = sync_q[1];
endmodule

