`timescale 1ns/1ps
package soc_cfg_pkg;
  parameter int unsigned XLEN = 32;
  parameter int unsigned ROB_ENTRIES = 32;
  parameter int unsigned ROB_INDEX_W = 5;
  parameter int unsigned ROB_PTR_W = ROB_INDEX_W + 1;
  parameter int unsigned UOP_GEN_W = 2;
  parameter int unsigned UOP_ID_W = UOP_GEN_W + ROB_PTR_W;
  parameter int unsigned PHYS_REGS = 64;
  parameter int unsigned PREG_W = 6;

  parameter logic [31:0] RESET_VECTOR = 32'h0000_0000;
  parameter logic [31:0] RAM_BASE     = 32'h0000_0000;
  // The shipped RT-Thread/CoreMark image occupies under 48 KiB including BSS.
  // A 64 KiB power-of-two window is the smallest capacity that contains the
  // complete image and its reserved stacks.  It infers only 16 RAMB36 blocks,
  // avoiding the central BRAM-column pressure of the former oversized RAM.
  parameter logic [31:0] RAM_BYTES    = 32'h0001_0000;
  parameter logic [31:0] UART_BASE    = 32'h1000_0000;
  parameter logic [31:0] TIMER_BASE   = 32'h1000_1000;
  parameter logic [31:0] IRQ_BASE     = 32'h1000_2000;

  localparam int unsigned RAM_ADDR_BITS = $clog2(RAM_BYTES);

  // The implemented RAM is a power-of-two window at address zero.  Express
  // its decode as a high-bit reduction instead of a generic 32-bit unsigned
  // comparison, which otherwise becomes a carry chain on every LSU/cache
  // request path.
  function automatic logic addr_is_ram(input logic [31:0] addr);
    return !(|addr[31:RAM_ADDR_BITS]);
  endfunction

  // The three CPU-visible 4 KiB peripheral pages are contiguous from UART to
  // IRQ/debug.  DS18B20 and SEG belong to the independent 50 MHz display
  // island and deliberately do not add decode or response fanout here.
  function automatic logic addr_is_mmio(input logic [31:0] addr);
    return (addr[31:16] == UART_BASE[31:16]) &&
           (addr[15:12] >= UART_BASE[15:12]) &&
           (addr[15:12] <= IRQ_BASE[15:12]);
  endfunction

  parameter int unsigned BOARD_INPUT_CLK_HZ = 200_000_000;
  parameter int unsigned BOARD_REF_CLK_HZ = 50_000_000;
  parameter int unsigned DEFAULT_CLK_HZ = 50_000_000;
  parameter int unsigned UART_BAUD = 115_200;

  // Build-identification gates for implemented optional structures.
  parameter bit FEAT_BRANCH_PREDICTOR = 1'b1;
  parameter bit FEAT_FAST_WAKE_SHIFT  = 1'b0;
  parameter bit FEAT_NONBLOCKING_DCACHE = 1'b1;
endpackage
