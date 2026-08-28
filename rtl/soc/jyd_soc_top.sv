`timescale 1ns/1ps
module jyd_soc_top #(
  parameter string MEM_INIT_FILE = "",
  parameter int unsigned CLK_HZ = 50_000_000
) (
  input  wire        i_sys_clk_p,
  input  wire        i_sys_clk_n,
  input  wire        i_uart_rx,
  output wire        o_uart_tx,
  inout  wire        ds18b20_dq_io,
  output wire [31:0] virtual_led,
  output wire [39:0] virtual_seg
);
  import soc_cfg_pkg::*;

  wire clk_board_50m;
  wire clk_soc;
  wire pll_locked;
  logic rst_n;
  // The ASYNC_REG chains below are the only flops with asynchronous control.
  // Functional logic consumes ordinary INIT=0 registers so no BRAM address,
  // enable, or payload cone has an asynchronous-reset ancestor.
  (* keep = "true" *) logic soc_run_q = 1'b0;
  (* keep = "true" *) logic board_run_q = 1'b0;
  logic timer_irq;
  logic ext_irq;
  logic [31:0] core_pc;
  logic [5:0] rob_count;
  logic [31:0] timer_count;
  logic [3:0] irq_pending;
  logic coremark_led;
  logic board_rst_n;
  logic ds18b20_drive_low;
  wire ds18b20_dq_in;

  // The only reused IP block is the official active Clocking Wizard XCI.
  pll u_pll (
    .clk_in1_p(i_sys_clk_p),
    .clk_in1_n(i_sys_clk_n),
    .clk_out1(clk_board_50m),
    .clk_out2(clk_soc),
    .locked(pll_locked)
  );

  // PLL lock loss asserts reset asynchronously. Each used clock domain owns
  // its own two-flop synchronous deassertion chain.
  reset_sync u_soc_reset (
    .clk_i(clk_soc), .arst_ni(pll_locked), .rst_no(rst_n)
  );

  reset_sync u_board_reset (
    .clk_i(clk_board_50m), .arst_ni(pll_locked), .rst_no(board_rst_n)
  );

  always_ff @(posedge clk_soc)
    soc_run_q <= rst_n;

  always_ff @(posedge clk_board_50m)
    board_run_q <= board_rst_n;

  ooo_soc_system #(
    .CLK_HZ(CLK_HZ),
    .UART_BAUD(UART_BAUD),
    .BUILD_ID(32'h2025_2301),
    .MEM_INIT_FILE(MEM_INIT_FILE)
  ) u_soc (
    .clk_i(clk_soc), .rst_ni(soc_run_q),
    .uart_rx_i(i_uart_rx), .uart_tx_o(o_uart_tx),
    .timer_irq_o(timer_irq), .ext_irq_o(ext_irq),
    .debug_pc_o(core_pc), .debug_rob_count_o(rob_count), .timer_count_o(timer_count),
    .irq_pending_o(irq_pending), .coremark_led_o(coremark_led)
  );

  // virtual_led[0] is the board-visible CoreMark activity indicator.  All
  // other LEDs stay dark instead of continuously displaying PC/debug state.
  assign virtual_led = {31'b0, coremark_led};

  // DS18B20 DQ is open drain.  The sensor module's 10 kohm resistor supplies
  // the high level; the FPGA either pulls low or disconnects its output.
  assign ds18b20_dq_io = ds18b20_drive_low ? 1'b0 : 1'bz;
  assign ds18b20_dq_in = ds18b20_dq_io;

  // The temperature/display island owns clk_out1 (fixed 50 MHz), its own reset
  // synchronizer, the sensor pin, and all SEG pins.  No CPU bus, software state,
  // or clk_soc signal enters this island, so system load cannot stall sampling
  // or display refresh and there is no inter-domain data CDC to constrain.
  temperature_display_island #(
    .CLK_HZ(50_000_000)
  ) u_temperature_island (
    .clk_i(clk_board_50m),
    .rst_ni(board_run_q),
    .dq_i(ds18b20_dq_in),
    .dq_drive_low_o(ds18b20_drive_low),
    .seg_o(virtual_seg)
  );
endmodule
