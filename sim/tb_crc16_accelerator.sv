`timescale 1ns/1ps
module tb_crc16_accelerator;
  logic [15:0] data_i;
  logic [15:0] crc_i;
  logic [15:0] crc_o;

  crc16_accelerator dut (.*);

  function automatic logic [15:0] reference_crc16(
    input logic [15:0] data,
    input logic [15:0] crc
  );
    logic [15:0] data_work;
    logic [15:0] crc_work;
    logic feedback;
    data_work = data;
    crc_work = crc;
    for (int unsigned bit_index = 0; bit_index < 16; bit_index++) begin
      feedback = data_work[0] ^ crc_work[0];
      data_work >>= 1;
      if (feedback)
        crc_work ^= 16'h4002;
      crc_work >>= 1;
      crc_work[15] = feedback;
    end
    return crc_work;
  endfunction

  task automatic check(input logic [15:0] data, input logic [15:0] crc);
    data_i = data;
    crc_i = crc;
    #1;
    assert (crc_o == reference_crc16(data, crc))
      else $fatal(1, "CRC mismatch data=%04x crc=%04x got=%04x expected=%04x",
                  data, crc, crc_o, reference_crc16(data, crc));
  endtask

  initial begin
    check(16'h0000, 16'h0000);
    check(16'hffff, 16'h0000);
    check(16'h1234, 16'he9f5);
    check(16'he714, 16'h1fd7);
    for (int unsigned sample = 0; sample < 1000; sample++)
      check($urandom, $urandom);
    $display("PASS tb_crc16_accelerator");
    $finish;
  end
endmodule
