`timescale 1ns/1ps

// Autonomous, externally-powered DS18B20 controller.  The 1-Wire output is
// open drain: dq_drive_low_o may pull DQ low, but a logic high is always made
// by releasing the pin to the sensor module's external pull-up.
module ds18b20_master #(
  parameter int unsigned CLK_HZ             = 50_000_000,
  parameter int unsigned BOOT_WAIT_US       = 10_000,
  parameter int unsigned CONVERSION_WAIT_US = 800_000,
  parameter int unsigned RETRY_WAIT_US      = 100_000
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic               dq_i,
  output logic               dq_drive_low_o,
  output logic signed [15:0] temperature_raw_o,
  output logic               sample_valid_o,
  output logic               sensor_present_o,
  output logic               fault_o,
  output logic [2:0]         fault_code_o
);
  localparam int unsigned US_DIV = CLK_HZ / 1_000_000;
  localparam int unsigned US_DIV_W = (US_DIV <= 1) ? 1 : $clog2(US_DIV);

  typedef enum logic [3:0] {
    ST_BOOT_WAIT,
    ST_IDLE_CHECK,
    ST_RESET_LOW,
    ST_RESET_RELEASE,
    ST_WRITE_SLOT,
    ST_CONVERSION_WAIT,
    ST_READ_SLOT,
    ST_VALIDATE,
    ST_RETRY_WAIT
  } state_t;

  typedef enum logic [1:0] {
    CMD_CONVERT_SKIP,
    CMD_CONVERT_T,
    CMD_READ_SKIP,
    CMD_READ_SCRATCHPAD
  } command_step_t;

  localparam logic [2:0] FAULT_NONE        = 3'd0;
  localparam logic [2:0] FAULT_BUS_LOW     = 3'd1;
  localparam logic [2:0] FAULT_NO_PRESENCE = 3'd2;
  localparam logic [2:0] FAULT_CRC         = 3'd3;
  localparam logic [2:0] FAULT_ALL_ZERO    = 3'd4;
  localparam int unsigned IDLE_HIGH_US      = 8;

  state_t state_q;
  command_step_t command_step_q;

  logic [US_DIV_W-1:0] us_div_q;
  logic [31:0] us_count_q;
  logic [7:0] tx_byte_q;
  logic [7:0] rx_byte_q;
  logic [2:0] bit_index_q;
  logic [3:0] byte_index_q;
  logic [7:0] scratchpad_q [0:7];
  logic [7:0] crc_q;
  logic reset_for_read_q;
  logic presence_seen_q;

  // DQ is asynchronous at the pad even though every transaction is initiated
  // here.  Synchronization makes the presence/read sampling boundary explicit.
  (* ASYNC_REG = "TRUE" *) logic [1:0] dq_sync_q;

  wire us_tick = (us_div_q == US_DIV - 1);
  wire tx_bit = tx_byte_q[bit_index_q];
  wire scratchpad_all_zero = ~(|{
    scratchpad_q[7], scratchpad_q[6], scratchpad_q[5], scratchpad_q[4],
    scratchpad_q[3], scratchpad_q[2], scratchpad_q[1], scratchpad_q[0],
    rx_byte_q
  });

  function automatic logic [7:0] crc8_byte(
    input logic [7:0] crc_in,
    input logic [7:0] data_in
  );
    logic [7:0] crc;
    integer i;
    begin
      crc = crc_in;
      for (i = 0; i < 8; i = i + 1) begin
        if (crc[0] ^ data_in[i]) begin
          crc = (crc >> 1) ^ 8'h8c;
        end else begin
          crc = crc >> 1;
        end
      end
      crc8_byte = crc;
    end
  endfunction

  always_comb begin
    dq_drive_low_o = 1'b0;
    unique case (state_q)
      ST_RESET_LOW: dq_drive_low_o = 1'b1;
      ST_WRITE_SLOT: begin
        // 70 us slot: write-1 is low for 6 us, write-0 for 60 us.
        dq_drive_low_o = tx_bit ? (us_count_q < 6) : (us_count_q < 60);
      end
      ST_READ_SLOT: begin
        // Initiate a read slot for 3 us, then release for the slave response.
        dq_drive_low_o = (us_count_q < 3);
      end
      default: dq_drive_low_o = 1'b0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      dq_sync_q <= 2'b11;
    end else begin
      dq_sync_q <= {dq_sync_q[0], dq_i};
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      us_div_q <= '0;
    end else if (us_tick) begin
      us_div_q <= '0;
    end else begin
      us_div_q <= us_div_q + 1'b1;
    end
  end

  integer k;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= ST_BOOT_WAIT;
      command_step_q <= CMD_CONVERT_SKIP;
      us_count_q <= 32'b0;
      tx_byte_q <= 8'b0;
      rx_byte_q <= 8'b0;
      bit_index_q <= 3'b0;
      byte_index_q <= 4'b0;
      crc_q <= 8'b0;
      reset_for_read_q <= 1'b0;
      presence_seen_q <= 1'b0;
      temperature_raw_o <= 16'sd0;
      sample_valid_o <= 1'b0;
      sensor_present_o <= 1'b0;
      fault_o <= 1'b0;
      fault_code_o <= FAULT_NONE;
      for (k = 0; k < 8; k = k + 1) begin
        scratchpad_q[k] <= 8'b0;
      end
    end else begin
      sample_valid_o <= 1'b0;

      if (us_tick) begin
        unique case (state_q)
          ST_BOOT_WAIT: begin
            if (us_count_q + 1 >= BOOT_WAIT_US) begin
              us_count_q <= 32'b0;
              state_q <= ST_IDLE_CHECK;
              reset_for_read_q <= 1'b0;
              presence_seen_q <= 1'b0;
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_IDLE_CHECK: begin
            // A released 1-Wire bus must return high before a reset starts.
            // Without this check an electrically-low DQ produces nine zero
            // bytes, whose Dallas CRC is also zero, and masquerades as 0 C.
            if (!dq_sync_q[1]) begin
              us_count_q <= 32'b0;
              sensor_present_o <= 1'b0;
              fault_o <= 1'b1;
              fault_code_o <= FAULT_BUS_LOW;
              state_q <= ST_RETRY_WAIT;
            end else if (us_count_q + 1 >= IDLE_HIGH_US) begin
              us_count_q <= 32'b0;
              presence_seen_q <= 1'b0;
              state_q <= ST_RESET_LOW;
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_RESET_LOW: begin
            // A 500 us reset comfortably exceeds the 480 us minimum.
            if (us_count_q == 499) begin
              us_count_q <= 32'b0;
              state_q <= ST_RESET_RELEASE;
              presence_seen_q <= 1'b0;
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_RESET_RELEASE: begin
            // Sample 70 us after release, in the specified presence window.
            if (us_count_q == 69) begin
              presence_seen_q <= !dq_sync_q[1];
            end

            // Leave a full 500 us recovery interval before the first slot.
            if (us_count_q == 499) begin
              us_count_q <= 32'b0;
              if (presence_seen_q) begin
                sensor_present_o <= 1'b1;
                tx_byte_q <= 8'hcc; // Skip ROM: exactly one attached sensor.
                bit_index_q <= 3'b0;
                command_step_q <= reset_for_read_q ? CMD_READ_SKIP
                                                   : CMD_CONVERT_SKIP;
                state_q <= ST_WRITE_SLOT;
              end else begin
                sensor_present_o <= 1'b0;
                fault_o <= 1'b1;
                fault_code_o <= FAULT_NO_PRESENCE;
                state_q <= ST_RETRY_WAIT;
              end
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_WRITE_SLOT: begin
            if (us_count_q == 69) begin
              us_count_q <= 32'b0;
              if (bit_index_q == 3'd7) begin
                bit_index_q <= 3'b0;
                unique case (command_step_q)
                  CMD_CONVERT_SKIP: begin
                    tx_byte_q <= 8'h44; // Convert T
                    command_step_q <= CMD_CONVERT_T;
                  end
                  CMD_CONVERT_T: begin
                    state_q <= ST_CONVERSION_WAIT;
                  end
                  CMD_READ_SKIP: begin
                    tx_byte_q <= 8'hbe; // Read Scratchpad
                    command_step_q <= CMD_READ_SCRATCHPAD;
                  end
                  default: begin
                    byte_index_q <= 4'b0;
                    rx_byte_q <= 8'b0;
                    crc_q <= 8'b0;
                    state_q <= ST_READ_SLOT;
                  end
                endcase
              end else begin
                bit_index_q <= bit_index_q + 1'b1;
              end
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_CONVERSION_WAIT: begin
            // External VDD is used, so DQ remains released during conversion.
            if (us_count_q + 1 >= CONVERSION_WAIT_US) begin
              us_count_q <= 32'b0;
              reset_for_read_q <= 1'b1;
              presence_seen_q <= 1'b0;
              state_q <= ST_IDLE_CHECK;
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_READ_SLOT: begin
            // Sample 15 us from the start of the slot, before the 1-Wire limit.
            if (us_count_q == 14) begin
              rx_byte_q[bit_index_q] <= dq_sync_q[1];
            end

            if (us_count_q == 69) begin
              us_count_q <= 32'b0;
              if (bit_index_q == 3'd7) begin
                bit_index_q <= 3'b0;
                if (byte_index_q < 4'd8) begin
                  scratchpad_q[byte_index_q] <= rx_byte_q;
                  crc_q <= crc8_byte(crc_q, rx_byte_q);
                  byte_index_q <= byte_index_q + 1'b1;
                  rx_byte_q <= 8'b0;
                end else begin
                  state_q <= ST_VALIDATE;
                end
              end else begin
                bit_index_q <= bit_index_q + 1'b1;
              end
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end

          ST_VALIDATE: begin
            // The ninth byte is the transmitted Dallas CRC of bytes 0..7.
            // A nine-byte all-zero frame also has a zero CRC, but is not a
            // legal powered DS18B20 scratchpad.  Reject it explicitly so an
            // electrical-low bus can never be published as 0.00 C.
            if ((crc_q == rx_byte_q) && !scratchpad_all_zero) begin
              temperature_raw_o <= $signed({scratchpad_q[1], scratchpad_q[0]});
              sample_valid_o <= 1'b1;
              sensor_present_o <= 1'b1;
              fault_o <= 1'b0;
              fault_code_o <= FAULT_NONE;
              us_count_q <= 32'b0;
              reset_for_read_q <= 1'b0;
              presence_seen_q <= 1'b0;
              state_q <= ST_IDLE_CHECK;
            end else begin
              fault_o <= 1'b1;
              fault_code_o <= scratchpad_all_zero ? FAULT_ALL_ZERO : FAULT_CRC;
              us_count_q <= 32'b0;
              state_q <= ST_RETRY_WAIT;
            end
          end

          default: begin // ST_RETRY_WAIT
            if (us_count_q + 1 >= RETRY_WAIT_US) begin
              us_count_q <= 32'b0;
              reset_for_read_q <= 1'b0;
              presence_seen_q <= 1'b0;
              state_q <= ST_IDLE_CHECK;
            end else begin
              us_count_q <= us_count_q + 1'b1;
            end
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if ((CLK_HZ < 1_000_000) || ((CLK_HZ % 1_000_000) != 0)) begin
      $fatal(1, "ds18b20_master CLK_HZ must be an integer multiple of 1 MHz");
    end
    if ((BOOT_WAIT_US == 0) || (CONVERSION_WAIT_US == 0) ||
        (RETRY_WAIT_US == 0)) begin
      $fatal(1, "ds18b20_master wait parameters must be non-zero");
    end
  end
`endif
endmodule
