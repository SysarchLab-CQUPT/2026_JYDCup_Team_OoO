`timescale 1ns/1ps

// Formats a signed DS18B20 1/16-degree sample and scans the board's horizontal
// row of four two-digit common-cathode displays.  Two independent board photos
// establish the left-to-right signal-group order as LED3, LED4, LED2, LED1.
module temperature_seg_display #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned SCAN_PHASE_HZ = 1_000
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic signed [15:0] temperature_raw_i,
  input  logic               sample_valid_i,
  input  logic               fault_i,
  input  logic [2:0]         fault_code_i,
  output logic [39:0]        seg_o
);
  localparam int unsigned SCAN_DIV = CLK_HZ / SCAN_PHASE_HZ;
  localparam int unsigned SCAN_DIV_W = (SCAN_DIV <= 1) ? 1 : $clog2(SCAN_DIV);

  localparam logic [4:0] GLYPH_MINUS = 5'd10;
  localparam logic [4:0] GLYPH_E     = 5'd11;
  localparam logic [4:0] GLYPH_R     = 5'd12;
  localparam logic [4:0] GLYPH_BLANK = 5'd13;
  localparam logic [4:0] GLYPH_C     = 5'd14;
  localparam logic [4:0] GLYPH_N     = 5'd15;
  localparam logic [4:0] GLYPH_O     = 5'd16;
  localparam logic [4:0] GLYPH_P     = 5'd17;
  localparam logic [4:0] GLYPH_L     = 5'd18;
  localparam logic [4:0] GLYPH_D     = 5'd19;

  localparam logic [2:0] FAULT_BUS_LOW     = 3'd1;
  localparam logic [2:0] FAULT_NO_PRESENCE = 3'd2;
  localparam logic [2:0] FAULT_CRC         = 3'd3;
  localparam logic [2:0] FAULT_ALL_ZERO    = 3'd4;

  logic [4:0] digit0_q;
  logic [4:0] digit1_q;
  logic [4:0] digit2_q;
  logic [4:0] digit3_q;
  logic [3:0] decimal_point_q;
  logic valid_sample_q;

  // 5 BCD digits plus the 14-bit binary centi-degree magnitude.
  logic [33:0] bcd_shift_q;
  logic [33:0] bcd_shift_adjusted;
  logic [33:0] bcd_shift_next;
  logic [3:0] bcd_step_q;
  logic format_busy_q;
  logic negative_q;

  logic [15:0] magnitude_comb;
  (* use_dsp = "no" *) logic [19:0] centi_scaled_comb;

  logic [SCAN_DIV_W-1:0] scan_count_q;
  logic scan_phase_q;
  logic scan_blank_q;

  logic [7:0] display_digit0_segments;
  logic [7:0] display_digit1_segments;
  logic [7:0] display_digit2_segments;
  logic [7:0] display_digit3_segments;
  logic [7:0] display_digit4_segments;
  logic [7:0] display_digit5_segments;
  logic [7:0] display_digit6_segments;
  logic [7:0] display_digit7_segments;

  always_comb begin
    magnitude_comb = temperature_raw_i[15]
                   ? (~temperature_raw_i + 1'b1) : temperature_raw_i;
    // magnitude * 25 + 2, expressed structurally to keep the display island
    // out of the CPU's DSP pool.  The final >>2 performs rounded /4.
    centi_scaled_comb = ({4'b0, magnitude_comb} << 4)
                      + ({4'b0, magnitude_comb} << 3)
                      + {4'b0, magnitude_comb} + 2;
  end

  function automatic logic [6:0] encode_glyph(input logic [4:0] glyph);
    begin
      // Bit order is {G,F,E,D,C,B,A}; segment outputs are active high.
      unique case (glyph)
        4'd0: encode_glyph = 7'b0111111;
        4'd1: encode_glyph = 7'b0000110;
        4'd2: encode_glyph = 7'b1011011;
        4'd3: encode_glyph = 7'b1001111;
        4'd4: encode_glyph = 7'b1100110;
        4'd5: encode_glyph = 7'b1101101;
        4'd6: encode_glyph = 7'b1111101;
        4'd7: encode_glyph = 7'b0000111;
        4'd8: encode_glyph = 7'b1111111;
        4'd9: encode_glyph = 7'b1101111;
        GLYPH_MINUS: encode_glyph = 7'b1000000;
        GLYPH_E:     encode_glyph = 7'b1111001;
        GLYPH_R:     encode_glyph = 7'b1010000;
        GLYPH_C:     encode_glyph = 7'b0111001;
        GLYPH_N:     encode_glyph = 7'b1010100;
        GLYPH_O:     encode_glyph = 7'b1011100;
        GLYPH_P:     encode_glyph = 7'b1110011;
        GLYPH_L:     encode_glyph = 7'b0111000;
        GLYPH_D:     encode_glyph = 7'b1011110;
        default:     encode_glyph = 7'b0000000;
      endcase
    end
  endfunction

  always_comb begin
    bcd_shift_adjusted = bcd_shift_q;
    if (bcd_shift_adjusted[17:14] >= 5) bcd_shift_adjusted[17:14] = bcd_shift_adjusted[17:14] + 3;
    if (bcd_shift_adjusted[21:18] >= 5) bcd_shift_adjusted[21:18] = bcd_shift_adjusted[21:18] + 3;
    if (bcd_shift_adjusted[25:22] >= 5) bcd_shift_adjusted[25:22] = bcd_shift_adjusted[25:22] + 3;
    if (bcd_shift_adjusted[29:26] >= 5) bcd_shift_adjusted[29:26] = bcd_shift_adjusted[29:26] + 3;
    if (bcd_shift_adjusted[33:30] >= 5) bcd_shift_adjusted[33:30] = bcd_shift_adjusted[33:30] + 3;
    bcd_shift_next = bcd_shift_adjusted << 1;
  end

  always_ff @(posedge clk_i) begin
    logic [3:0] bcd_hundredths;
    logic [3:0] bcd_tenths;
    logic [3:0] bcd_ones;
    logic [3:0] bcd_tens;
    logic [3:0] bcd_hundreds;

    if (!rst_ni) begin
      digit0_q <= GLYPH_MINUS;
      digit1_q <= GLYPH_MINUS;
      digit2_q <= GLYPH_MINUS;
      digit3_q <= GLYPH_MINUS;
      decimal_point_q <= 4'b0;
      valid_sample_q <= 1'b0;
      bcd_shift_q <= 34'b0;
      bcd_step_q <= 4'b0;
      format_busy_q <= 1'b0;
      negative_q <= 1'b0;
    end else begin
      if (sample_valid_i) begin
        // DS18B20 LSB is 0.0625 C.  Convert to centi-degrees with rounding:
        // magnitude * 6.25 = (magnitude * 25) / 4.
        bcd_shift_q <= {20'b0, centi_scaled_comb[15:2]};
        bcd_step_q <= 4'b0;
        format_busy_q <= 1'b1;
        negative_q <= temperature_raw_i[15];
      end else if (format_busy_q) begin
        bcd_shift_q <= bcd_shift_next;
        if (bcd_step_q == 4'd13) begin
          bcd_hundredths = bcd_shift_next[17:14];
          bcd_tenths = bcd_shift_next[21:18];
          bcd_ones = bcd_shift_next[25:22];
          bcd_tens = bcd_shift_next[29:26];
          bcd_hundreds = bcd_shift_next[33:30];

          if (negative_q) begin
            digit0_q <= GLYPH_MINUS;
            if (bcd_tens == 0) begin
              // -5.25 C -> "-5.25"
              digit1_q <= bcd_ones;
              digit2_q <= bcd_tenths;
              digit3_q <= bcd_hundredths;
              decimal_point_q <= 4'b0010;
            end else begin
              // -10.1 C -> "-10.1"
              digit1_q <= bcd_tens;
              digit2_q <= bcd_ones;
              digit3_q <= bcd_tenths;
              decimal_point_q <= 4'b0100;
            end
          end else if (bcd_hundreds != 0) begin
            // 125.0 C -> "125.0"
            digit0_q <= bcd_hundreds;
            digit1_q <= bcd_tens;
            digit2_q <= bcd_ones;
            digit3_q <= bcd_tenths;
            decimal_point_q <= 4'b0100;
          end else begin
            // 25.06 C -> "25.06"; suppress a leading zero below 10 C.
            digit0_q <= (bcd_tens == 0) ? GLYPH_BLANK : bcd_tens;
            digit1_q <= bcd_ones;
            digit2_q <= bcd_tenths;
            digit3_q <= bcd_hundredths;
            decimal_point_q <= 4'b0010;
          end
          valid_sample_q <= 1'b1;
          format_busy_q <= 1'b0;
        end else begin
          bcd_step_q <= bcd_step_q + 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      scan_count_q <= '0;
      scan_phase_q <= 1'b0;
      scan_blank_q <= 1'b1;
    end else begin
      if (scan_blank_q) begin
        scan_blank_q <= 1'b0;
      end
      if (scan_count_q == SCAN_DIV - 1) begin
        scan_count_q <= '0;
        scan_phase_q <= !scan_phase_q;
        scan_blank_q <= 1'b1;
      end else begin
        scan_count_q <= scan_count_q + 1'b1;
      end
    end
  end

  always_comb begin
    // Keep the four-character reading/diagnostic centered in the physical
    // eight-digit row.  Positions 0..7 are the actual left-to-right order.
    display_digit0_segments = 8'b0;
    display_digit1_segments = 8'b0;
    display_digit2_segments = 8'b0;
    display_digit3_segments = 8'b0;
    display_digit4_segments = 8'b0;
    display_digit5_segments = 8'b0;
    display_digit6_segments = 8'b0;
    display_digit7_segments = 8'b0;

    if (fault_i) begin
      unique case (fault_code_i)
        // dLo : DQ stayed low while the FPGA output was released.
        FAULT_BUS_LOW: begin
          display_digit2_segments = {1'b0, encode_glyph(GLYPH_D)};
          display_digit3_segments = {1'b0, encode_glyph(GLYPH_L)};
          display_digit4_segments = {1'b0, encode_glyph(GLYPH_O)};
        end
        // noPr : reset was sent but no DS18B20 presence pulse arrived.
        FAULT_NO_PRESENCE: begin
          display_digit2_segments = {1'b0, encode_glyph(GLYPH_N)};
          display_digit3_segments = {1'b0, encode_glyph(GLYPH_O)};
          display_digit4_segments = {1'b0, encode_glyph(GLYPH_P)};
          display_digit5_segments = {1'b0, encode_glyph(GLYPH_R)};
        end
        // CrC : presence and data were seen, but the CRC did not match.
        FAULT_CRC: begin
          display_digit2_segments = {1'b0, encode_glyph(GLYPH_C)};
          display_digit3_segments = {1'b0, encode_glyph(GLYPH_R)};
          display_digit4_segments = {1'b0, encode_glyph(GLYPH_C)};
        end
        // 0Err : the complete frame was zero (the old false-0.00 case).
        FAULT_ALL_ZERO: begin
          display_digit2_segments = {1'b0, encode_glyph(5'd0)};
          display_digit3_segments = {1'b0, encode_glyph(GLYPH_E)};
          display_digit4_segments = {1'b0, encode_glyph(GLYPH_R)};
          display_digit5_segments = {1'b0, encode_glyph(GLYPH_R)};
        end
        default: begin
          display_digit2_segments = {1'b0, encode_glyph(GLYPH_E)};
          display_digit3_segments = {1'b0, encode_glyph(GLYPH_R)};
          display_digit4_segments = {1'b0, encode_glyph(GLYPH_R)};
        end
      endcase
    end else if (!valid_sample_q) begin
      display_digit2_segments = {1'b0, encode_glyph(GLYPH_MINUS)};
      display_digit3_segments = {1'b0, encode_glyph(GLYPH_MINUS)};
      display_digit4_segments = {1'b0, encode_glyph(GLYPH_MINUS)};
      display_digit5_segments = {1'b0, encode_glyph(GLYPH_MINUS)};
    end else begin
      display_digit2_segments = {decimal_point_q[0], encode_glyph(digit0_q)};
      display_digit3_segments = {decimal_point_q[1], encode_glyph(digit1_q)};
      display_digit4_segments = {decimal_point_q[2], encode_glyph(digit2_q)};
      display_digit5_segments = {decimal_point_q[3], encode_glyph(digit3_q)};
    end

    // virtual_seg group layout from the board XDC:
    // [9:0]=LED1, [19:10]=LED2, [29:20]=LED4, [39:30]=LED3.
    // In each group [7:0]={DP,G,F,E,D,C,B,A}, [8]=CS1, [9]=CS2.
    // Physical left-to-right order measured on the board is:
    // LED3 (digits 0/1), LED4 (2/3), LED2 (4/5), LED1 (6/7).
    seg_o = 40'b0;
    seg_o[37:30] = scan_phase_q ? display_digit1_segments
                                      : display_digit0_segments;
    seg_o[27:20] = scan_phase_q ? display_digit3_segments
                                      : display_digit2_segments;
    seg_o[17:10] = scan_phase_q ? display_digit5_segments
                                      : display_digit4_segments;
    seg_o[7:0] = scan_phase_q ? display_digit7_segments
                                    : display_digit6_segments;

    // The board's common-cathode digit selects are active low.  Insert a
    // one-clock all-off interval whenever the selected digit changes.
    seg_o[9:8] = 2'b11;
    seg_o[19:18] = 2'b11;
    seg_o[29:28] = 2'b11;
    seg_o[39:38] = 2'b11;
    if (!scan_blank_q) begin
      if (!scan_phase_q) begin
        seg_o[8] = 1'b0;
        seg_o[18] = 1'b0;
        seg_o[28] = 1'b0;
        seg_o[38] = 1'b0;
      end else begin
        seg_o[9] = 1'b0;
        seg_o[19] = 1'b0;
        seg_o[29] = 1'b0;
        seg_o[39] = 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if ((SCAN_PHASE_HZ == 0) || (CLK_HZ < SCAN_PHASE_HZ) ||
        ((CLK_HZ % SCAN_PHASE_HZ) != 0)) begin
      $fatal(1, "temperature_seg_display requires an integer scan divider");
    end
  end
`endif
endmodule
