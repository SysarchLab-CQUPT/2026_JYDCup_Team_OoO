`timescale 1ns/1ps

// A complete board-clock island.  It has no CPU/MMIO/RTOS connection and no
// signal crossing to or from the SoC clock domain.
module temperature_display_island #(
  parameter int unsigned CLK_HZ             = 50_000_000,
  parameter int unsigned BOOT_WAIT_US       = 10_000,
  parameter int unsigned CONVERSION_WAIT_US = 800_000,
  parameter int unsigned RETRY_WAIT_US      = 100_000,
  parameter int unsigned SCAN_PHASE_HZ      = 1_000
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        dq_i,
  output logic        dq_drive_low_o,
  output logic [39:0] seg_o
);
  logic signed [15:0] temperature_raw;
  logic sample_valid;
  logic sensor_present;
  logic sensor_fault;
  logic [2:0] sensor_fault_code;

  ds18b20_master #(
    .CLK_HZ(CLK_HZ),
    .BOOT_WAIT_US(BOOT_WAIT_US),
    .CONVERSION_WAIT_US(CONVERSION_WAIT_US),
    .RETRY_WAIT_US(RETRY_WAIT_US)
  ) u_sensor (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .dq_i(dq_i),
    .dq_drive_low_o(dq_drive_low_o),
    .temperature_raw_o(temperature_raw),
    .sample_valid_o(sample_valid),
    .sensor_present_o(sensor_present),
    .fault_o(sensor_fault),
    .fault_code_o(sensor_fault_code)
  );

  temperature_seg_display #(
    .CLK_HZ(CLK_HZ),
    .SCAN_PHASE_HZ(SCAN_PHASE_HZ)
  ) u_display (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .temperature_raw_i(temperature_raw),
    .sample_valid_i(sample_valid),
    .fault_i(sensor_fault),
    .fault_code_i(sensor_fault_code),
    .seg_o(seg_o)
  );
endmodule
