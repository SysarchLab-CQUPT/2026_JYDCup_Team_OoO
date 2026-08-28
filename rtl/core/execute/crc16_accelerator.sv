`timescale 1ns/1ps
module crc16_accelerator (
  input  logic [15:0] data_i,
  input  logic [15:0] crc_i,
  output logic [15:0] crc_o
);
  // CoreMark's crcu16() applies its reflected 0x4002 recurrence once per
  // source bit.  The fixed-count combinational loop synthesizes as a constant
  // XOR network; there is no hidden state or latency contract to flush.
  always_comb begin : crc16_transform
    logic [15:0] data_work;
    logic [15:0] crc_work;
    logic feedback;

    data_work = data_i;
    crc_work = crc_i;
    for (int unsigned bit_index = 0; bit_index < 16; bit_index++) begin
      feedback = data_work[0] ^ crc_work[0];
      data_work = {1'b0, data_work[15:1]};
      if (feedback) begin
        crc_work = crc_work ^ 16'h4002;
        crc_work = {1'b1, crc_work[15:1]};
      end else begin
        crc_work = {1'b0, crc_work[15:1]};
      end
    end
    crc_o = crc_work;
  end
endmodule
