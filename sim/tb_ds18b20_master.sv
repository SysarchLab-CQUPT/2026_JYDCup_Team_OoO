`timescale 1ns/1ps

module tb_ds18b20_master;
  localparam int CLK_HZ = 1_000_000;

  logic clk;
  logic rst_n;
  logic master_drive_low;
  logic sensor_drive_low;
  logic signed [15:0] temperature_raw;
  logic sample_valid;
  logic sensor_present;
  logic fault;
  logic [2:0] fault_code;
  logic model_present;
  logic model_bad_crc;
  logic model_all_zero;
  logic model_force_low;
  logic signed [15:0] model_temperature_raw;
  tri1 dq;

  logic [7:0] model_scratchpad [0:8];
  logic [7:0] command_byte;
  integer command_bit_index;
  integer read_bit_index;
  logic reading_scratchpad;
  integer valid_count;

  assign dq = master_drive_low ? 1'b0 : 1'bz;
  assign dq = sensor_drive_low ? 1'b0 : 1'bz;
  assign dq = model_force_low ? 1'b0 : 1'bz;

  always #500 clk = !clk;

  ds18b20_master #(
    .CLK_HZ(CLK_HZ),
    .BOOT_WAIT_US(20),
    .CONVERSION_WAIT_US(100),
    .RETRY_WAIT_US(100)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .dq_i(dq),
    .dq_drive_low_o(master_drive_low),
    .temperature_raw_o(temperature_raw),
    .sample_valid_o(sample_valid),
    .sensor_present_o(sensor_present),
    .fault_o(fault),
    .fault_code_o(fault_code)
  );

  function automatic logic [7:0] crc8_byte(
    input logic [7:0] crc_in,
    input logic [7:0] data_in
  );
    logic [7:0] crc;
    integer i;
    begin
      crc = crc_in;
      for (i = 0; i < 8; i = i + 1) begin
        if (crc[0] ^ data_in[i]) crc = (crc >> 1) ^ 8'h8c;
        else crc = crc >> 1;
      end
      crc8_byte = crc;
    end
  endfunction

  task automatic prepare_scratchpad;
    logic [7:0] crc;
    integer i;
    begin
      if (model_all_zero) begin
        for (i = 0; i < 9; i = i + 1) model_scratchpad[i] = 8'h00;
      end else begin
      model_scratchpad[0] = model_temperature_raw[7:0];
      model_scratchpad[1] = model_temperature_raw[15:8];
      model_scratchpad[2] = 8'h4b;
      model_scratchpad[3] = 8'h46;
      model_scratchpad[4] = 8'h7f;
      model_scratchpad[5] = 8'hff;
      model_scratchpad[6] = 8'h0c;
      model_scratchpad[7] = 8'h10;
      crc = 8'h00;
      for (i = 0; i < 8; i = i + 1) crc = crc8_byte(crc, model_scratchpad[i]);
      model_scratchpad[8] = model_bad_crc ? (crc ^ 8'h5a) : crc;
      end
    end
  endtask

  // Timing-aware single-sensor model.  Reset, write slots, and read slots are
  // distinguished by the master's low pulse width.  Scratchpad bits are sent
  // LSB first with a response low from 5 us through 45 us in each read slot.
  initial begin : sensor_model
    time low_start;
    time low_width;
    logic sampled_bit;
    logic response_bit;
    sensor_drive_low = 1'b0;
    command_byte = 8'b0;
    command_bit_index = 0;
    read_bit_index = 0;
    reading_scratchpad = 1'b0;

    forever begin
      @(negedge dq);
      if (!sensor_drive_low) begin
        low_start = $time;
        @(posedge dq);
        low_width = $time - low_start;

        if (low_width >= 400_000) begin
          command_byte = 8'b0;
          command_bit_index = 0;
          read_bit_index = 0;
          reading_scratchpad = 1'b0;
          if (model_present) begin
            #20_000;
            sensor_drive_low = 1'b1;
            #120_000;
            sensor_drive_low = 1'b0;
          end
        end else if (reading_scratchpad) begin
          response_bit = model_scratchpad[read_bit_index / 8][read_bit_index % 8];
          read_bit_index = read_bit_index + 1;
          if (!response_bit) begin
            #2_000;
            sensor_drive_low = 1'b1;
            #40_000;
            sensor_drive_low = 1'b0;
          end
          if (read_bit_index == 72) reading_scratchpad = 1'b0;
        end else begin
          sampled_bit = (low_width < 20_000);
          command_byte[command_bit_index] = sampled_bit;
          if (command_bit_index == 7) begin
            unique case (command_byte)
              8'hcc: begin end // Skip ROM
              8'h44: begin end // Convert T
              8'hbe: begin
                prepare_scratchpad();
                read_bit_index = 0;
                reading_scratchpad = 1'b1;
              end
              default: $fatal(1, "unexpected 1-Wire command %02x", command_byte);
            endcase
            command_byte = 8'b0;
            command_bit_index = 0;
          end else begin
            command_bit_index = command_bit_index + 1;
          end
        end
      end
    end
  end

  always @(posedge clk) begin
    if (sample_valid) valid_count <= valid_count + 1;
  end

  task automatic wait_for_valid(input logic signed [15:0] expected);
    begin
      @(posedge sample_valid);
      #1;
      if (temperature_raw !== expected) begin
        $fatal(1, "temperature mismatch: got %04x expected %04x",
               temperature_raw, expected);
      end
      if (!sensor_present || fault) begin
        $fatal(1, "valid sample did not clear presence/fault status");
      end
    end
  endtask

  initial begin : timeout
    #100_000_000;
    $fatal(1, "tb_ds18b20_master timeout");
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    model_present = 1'b1;
    model_bad_crc = 1'b0;
    model_all_zero = 1'b0;
    model_force_low = 1'b0;
    model_temperature_raw = 16'sh0191; // +25.0625 C
    valid_count = 0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;

    wait_for_valid(16'sh0191);
    model_temperature_raw = -16'sd162; // -10.125 C
    wait_for_valid(-16'sd162);
    model_temperature_raw = 16'sh0550; // +85.0 C
    wait_for_valid(16'sh0550);

    // A bad CRC must never publish a new temperature and must retain the last
    // valid sample while making the display-side fault explicit.
    model_bad_crc = 1'b1;
    model_temperature_raw = 16'sh00a0;
    wait (fault && fault_code == 3'd3);
    repeat (4) @(posedge clk);
    if (temperature_raw !== 16'sh0550) $fatal(1, "bad CRC changed temperature");
    if (valid_count != 3) $fatal(1, "bad CRC emitted sample_valid");

    model_bad_crc = 1'b0;
    wait_for_valid(16'sh00a0);

    // All-zero data plus an all-zero CRC used to be accepted as a valid
    // 0.00 C sample.  It must now be classified without changing temperature.
    model_all_zero = 1'b1;
    wait (fault && fault_code == 3'd4);
    repeat (4) @(posedge clk);
    if (temperature_raw !== 16'sh00a0) $fatal(1, "all-zero frame changed temperature");
    if (valid_count != 4) $fatal(1, "all-zero frame emitted sample_valid");
    model_all_zero = 1'b0;
    model_temperature_raw = 16'sh0000; // Genuine 0 C has nonzero metadata.
    wait_for_valid(16'sh0000);

    // Removing the slave must be detected at the next reset without hanging.
    model_present = 1'b0;
    wait (!sensor_present && fault && fault_code == 3'd2);
    repeat (10) @(posedge clk);
    if (master_drive_low !== 1'b0 && dq !== 1'b0) begin
      $fatal(1, "invalid 1-Wire drive state after sensor removal");
    end


    // A physically-low DQ must be distinguished from a missing sensor and
    // must never enter the reset/read sequence as a false presence pulse.
    model_force_low = 1'b1;
    wait (fault && fault_code == 3'd1);
    repeat (10) @(posedge clk);
    if (sample_valid) $fatal(1, "stuck-low DQ emitted sample_valid");

    $display("PASS tb_ds18b20_master");
    $finish;
  end
endmodule
