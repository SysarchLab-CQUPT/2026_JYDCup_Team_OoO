`timescale 1ns/1ps
module crc32_word_accelerator (
  input  logic [31:0] data_i,
  input  logic [15:0] crc_i,
  output logic [15:0] crc_o
);
  // CoreMark crcu32 applies the reflected CRC-16 polynomial 0xa001 to the
  // low half-word and then the high half-word.  CRC is linear over GF(2), so
  // the same transform can be expressed as a shallow XOR matrix rather than
  // a 32-step feedback chain.  Bit 0..31 are data_i and bit 32..47 are crc_i.
  logic [47:0] linear_input;

  assign linear_input = {crc_i, data_i};
  assign crc_o[ 0] = ^(linear_input & 48'hffe7fffbffe7);
  assign crc_o[ 1] = ^(linear_input & 48'h0028000c0028);
  assign crc_o[ 2] = ^(linear_input & 48'h005000180050);
  assign crc_o[ 3] = ^(linear_input & 48'h00a0003000a0);
  assign crc_o[ 4] = ^(linear_input & 48'h014000600140);
  assign crc_o[ 5] = ^(linear_input & 48'h028000c00280);
  assign crc_o[ 6] = ^(linear_input & 48'h050001800500);
  assign crc_o[ 7] = ^(linear_input & 48'h0a0003000a00);
  assign crc_o[ 8] = ^(linear_input & 48'h140006001400);
  assign crc_o[ 9] = ^(linear_input & 48'h28000c002800);
  assign crc_o[10] = ^(linear_input & 48'h500118005001);
  assign crc_o[11] = ^(linear_input & 48'ha0033000a003);
  assign crc_o[12] = ^(linear_input & 48'h400760014007);
  assign crc_o[13] = ^(linear_input & 48'h800fc002800f);
  assign crc_o[14] = ^(linear_input & 48'hfff97ffefff9);
  assign crc_o[15] = ^(linear_input & 48'hfff3fffdfff3);
endmodule
