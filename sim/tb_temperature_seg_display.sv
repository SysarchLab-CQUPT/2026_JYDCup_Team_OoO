`timescale 1ns/1ps

module tb_temperature_seg_display;
  localparam int CLK_HZ = 1_000_000;
  logic clk;
  logic rst_n;
  logic signed [15:0] temperature_raw;
  logic sample_valid;
  logic fault;
  logic [2:0] fault_code;
  logic [39:0] seg;

  always #500 clk = !clk;

  temperature_seg_display #(
    .CLK_HZ(CLK_HZ),
    .SCAN_PHASE_HZ(100_000)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .temperature_raw_i(temperature_raw),
    .sample_valid_i(sample_valid),
    .fault_i(fault),
    .fault_code_i(fault_code),
    .seg_o(seg)
  );

  function automatic logic [7:0] glyph(
    input logic [4:0] value,
    input logic dp
  );
    logic [6:0] segments;
    begin
      case (value)
        4'd0: segments = 7'b0111111;
        4'd1: segments = 7'b0000110;
        4'd2: segments = 7'b1011011;
        4'd3: segments = 7'b1001111;
        4'd4: segments = 7'b1100110;
        4'd5: segments = 7'b1101101;
        4'd6: segments = 7'b1111101;
        4'd7: segments = 7'b0000111;
        4'd8: segments = 7'b1111111;
        4'd9: segments = 7'b1101111;
        4'ha: segments = 7'b1000000;
        4'hb: segments = 7'b1111001;
        4'hc: segments = 7'b1010000;
        5'd14: segments = 7'b0111001;
        5'd15: segments = 7'b1010100;
        5'd16: segments = 7'b1011100;
        5'd17: segments = 7'b1110011;
        5'd18: segments = 7'b0111000;
        5'd19: segments = 7'b1011110;
        default: segments = 7'b0000000;
      endcase
      glyph = {dp, segments};
    end
  endfunction

  task automatic publish(input logic signed [15:0] raw);
    begin
      @(negedge clk);
      temperature_raw = raw;
      sample_valid = 1'b1;
      @(negedge clk);
      sample_valid = 1'b0;
      wait (dut.format_busy_q);
      wait (!dut.format_busy_q && dut.valid_sample_q);
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic check_scan(
    input logic [7:0] d0,
    input logic [7:0] d1,
    input logic [7:0] d2,
    input logic [7:0] d3,
    input logic [7:0] d4,
    input logic [7:0] d5,
    input logic [7:0] d6,
    input logic [7:0] d7
  );
    begin
      wait (!dut.scan_blank_q && !dut.scan_phase_q);
      #1;
      // Physical left-to-right group order is LED3, LED4, LED2, LED1.
      if (seg[37:30] !== d0 || seg[27:20] !== d2 ||
          seg[17:10] !== d4 || seg[7:0] !== d6) begin
        $fatal(1, "phase-0 segment mismatch: %010x", seg);
      end
      if ({seg[38],seg[28],seg[18],seg[8]} !== 4'b0000 ||
          {seg[39],seg[29],seg[19],seg[9]} !== 4'b1111) begin
        $fatal(1, "phase-0 digit select mismatch: %010x", seg);
      end

      wait (!dut.scan_blank_q && dut.scan_phase_q);
      #1;
      if (seg[37:30] !== d1 || seg[27:20] !== d3 ||
          seg[17:10] !== d5 || seg[7:0] !== d7) begin
        $fatal(1, "phase-1 segment mismatch: %010x", seg);
      end
      if ({seg[38],seg[28],seg[18],seg[8]} !== 4'b1111 ||
          {seg[39],seg[29],seg[19],seg[9]} !== 4'b0000) begin
        $fatal(1, "phase-1 digit select mismatch: %010x", seg);
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    temperature_raw = 16'sd0;
    sample_valid = 1'b0;
    fault = 1'b0;
    fault_code = 3'd0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    // The exact on-board failure case: 27.6875 C must round to 27.69.
    // This asserts LED3=blank, LED4="27.", LED2="69", LED1=blank.
    publish(16'sh01bb);
    check_scan(8'b0, 8'b0, glyph(2,0), glyph(7,1),
               glyph(6,0), glyph(9,0), 8'b0, 8'b0);

    publish(-16'sd84); // -5.25 C -> -5.25
    check_scan(8'b0, 8'b0, glyph(4'ha,0), glyph(5,1),
               glyph(2,0), glyph(5,0), 8'b0, 8'b0);

    publish(-16'sd162); // -10.125 C -> -10.1
    check_scan(8'b0, 8'b0, glyph(4'ha,0), glyph(1,0),
               glyph(0,1), glyph(1,0), 8'b0, 8'b0);

    publish(16'sd2000); // 125.0 C -> 125.0
    check_scan(8'b0, 8'b0, glyph(1,0), glyph(2,0),
               glyph(5,1), glyph(0,0), 8'b0, 8'b0);

    publish(16'sd0); // A legal scratchpad may report exactly 0.00 C.
    check_scan(8'b0, 8'b0, glyph(5'd13,0), glyph(0,1),
               glyph(0,0), glyph(0,0), 8'b0, 8'b0);

    fault = 1'b1;
    fault_code = 3'd1;
    check_scan(8'b0, 8'b0, glyph(5'd19,0), glyph(5'd18,0),
               glyph(5'd16,0), 8'b0, 8'b0, 8'b0);
    fault_code = 3'd2;
    check_scan(8'b0, 8'b0, glyph(5'd15,0), glyph(5'd16,0),
               glyph(5'd17,0), glyph(4'hc,0), 8'b0, 8'b0);
    fault_code = 3'd3;
    check_scan(8'b0, 8'b0, glyph(5'd14,0), glyph(4'hc,0),
               glyph(5'd14,0), 8'b0, 8'b0, 8'b0);
    fault_code = 3'd4;
    check_scan(8'b0, 8'b0, glyph(0,0), glyph(4'hb,0),
               glyph(4'hc,0), glyph(4'hc,0), 8'b0, 8'b0);

    $display("PASS tb_temperature_seg_display");
    $finish;
  end
endmodule
