`timescale 1ns/1ps
module tb_crc32_word_accelerator;
  logic [31:0] data_i;
  logic [15:0] crc_i;
  logic [15:0] crc_o;

  crc32_word_accelerator dut (.*);

  function automatic logic [15:0] reference_crc32(
    input logic [31:0] data,
    input logic [15:0] crc
  );
    logic [31:0] work_data;
    logic [15:0] work_crc;
    logic feedback;
    work_data = data;
    work_crc = crc;
    for (int unsigned bit_index = 0; bit_index < 32; bit_index++) begin
      feedback = work_data[0] ^ work_crc[0];
      work_data = work_data >> 1;
      work_crc = work_crc >> 1;
      if (feedback) work_crc = work_crc ^ 16'ha001;
    end
    return work_crc;
  endfunction

  initial begin
    data_i = 32'h1234_5678;
    crc_i = 16'h9abc;
    #1;
    assert (crc_o == 16'hc26b)
      else $fatal(1, "known-vector mismatch: %04x", crc_o);

    for (int unsigned test_index = 0; test_index < 1024; test_index++) begin
      data_i = $urandom;
      crc_i = $urandom;
      #1;
      assert (crc_o == reference_crc32(data_i, crc_i))
        else $fatal(1, "random mismatch data=%08x crc=%04x got=%04x exp=%04x",
                    data_i, crc_i, crc_o, reference_crc32(data_i, crc_i));
    end

    $display("PASS tb_crc32_word_accelerator");
    $finish;
  end
endmodule
