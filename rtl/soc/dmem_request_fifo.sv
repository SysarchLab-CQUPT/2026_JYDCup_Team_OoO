`timescale 1ns/1ps
module dmem_request_fifo #(
  parameter int unsigned DEPTH = 2,
  parameter int unsigned RAM_BYTES = soc_cfg_pkg::RAM_BYTES
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic                         enq_valid_i,
  output logic                         enq_ready_o,
  input  logic                         enq_write_i,
  input  logic [31:0]                  enq_addr_i,
  input  logic [31:0]                  enq_wdata_i,
  input  logic [3:0]                   enq_wstrb_i,
  input  logic [3:0]                   enq_seq_i,
  input  core_types_pkg::uop_id_t      enq_uop_id_i,
  input  logic                         enq_fast_load_i,

  output logic                         deq_valid_o,
  input  logic                         deq_ready_i,
  output logic                         deq_write_o,
  output logic [31:0]                  deq_addr_o,
  output logic [31:0]                  deq_wdata_o,
  output logic [3:0]                   deq_wstrb_o,
  output logic [3:0]                   deq_seq_o,
  output core_types_pkg::uop_id_t      deq_uop_id_o,
  // Registered-head view.  MMIO and fault handling consume only these
  // signals, so a RAM fall-through request can never appear in the
  // peripheral timing cone through the general dequeue mux.
  output logic                         buffered_valid_o,
  output logic                         buffered_write_o,
  output logic [31:0]                  buffered_addr_o,
  output logic [31:0]                  buffered_wdata_o,
  output logic [3:0]                   buffered_wstrb_o,
  output logic [3:0]                   buffered_seq_o,
  output core_types_pkg::uop_id_t      buffered_uop_id_o,

  output logic                         empty_o,
  output logic [$clog2(DEPTH+1)-1:0]   count_o
);
  import core_types_pkg::*;

  localparam int unsigned PTR_W = $clog2(DEPTH);
  localparam int unsigned COUNT_W = $clog2(DEPTH + 1);

  typedef struct packed {
    logic        write;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic [3:0]  seq;
    uop_id_t     uop_id;
  } request_t;

  request_t entries_q [DEPTH];
  logic [PTR_W-1:0] head_q, tail_q;
  logic [COUNT_W-1:0] count_q;
  logic enq_fire, deq_fire;
  logic fallthrough;

  // Preserve zero-added-latency hits when the queue is empty.  All selection
  // work upstream is separately refactored; a stalled request is still
  // captured locally on the accepting edge.
  assign enq_ready_o = count_q < COUNT_W'(DEPTH);
  // Cacheable stores and the EX-local load lane retain zero-added-latency
  // fall-through.  A replay/scanned load first enters the registered head;
  // this keeps its wide LQ selector out of the D-cache address/tag cone.
  // MMIO and unmapped requests first enter the FIFO, terminating their decode
  // and peripheral-ready path at this local boundary.
  assign fallthrough = (count_q == 0) &&
                       soc_cfg_pkg::addr_is_ram(enq_addr_i) &&
                       (enq_write_i || enq_fast_load_i);
  assign deq_valid_o = (count_q != 0) ||
                       (fallthrough && enq_valid_i && enq_ready_o);
  assign enq_fire = enq_valid_i && enq_ready_o;
  assign deq_fire = deq_valid_o && deq_ready_i;
  assign empty_o = count_q == 0;
  assign count_o = count_q;

  always_comb begin
    buffered_valid_o = count_q != 0;
    buffered_write_o = entries_q[head_q].write;
    buffered_addr_o = entries_q[head_q].addr;
    buffered_wdata_o = entries_q[head_q].wdata;
    buffered_wstrb_o = entries_q[head_q].wstrb;
    buffered_seq_o = entries_q[head_q].seq;
    buffered_uop_id_o = entries_q[head_q].uop_id;
  end

  always_comb begin
    deq_write_o = 1'b0;
    deq_addr_o = '0;
    deq_wdata_o = '0;
    deq_wstrb_o = '0;
    deq_seq_o = '0;
    deq_uop_id_o = '0;
    if (fallthrough) begin
      deq_write_o = enq_write_i;
      deq_addr_o = enq_addr_i;
      deq_wdata_o = enq_wdata_i;
      deq_wstrb_o = enq_wstrb_i;
      deq_seq_o = enq_seq_i;
      deq_uop_id_o = enq_uop_id_i;
    end else if (deq_valid_o) begin
      deq_write_o = entries_q[head_q].write;
      deq_addr_o = entries_q[head_q].addr;
      deq_wdata_o = entries_q[head_q].wdata;
      deq_wstrb_o = entries_q[head_q].wstrb;
      deq_seq_o = entries_q[head_q].seq;
      deq_uop_id_o = entries_q[head_q].uop_id;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      for (int unsigned i = 0; i < DEPTH; i++) entries_q[i] <= '0;
    end else begin
      // Rewriting the inactive tail is harmless.  Keeping payload writes
      // independent of enq_valid removes the upstream LQ arbitration cone
      // from every payload-register CE while tail/count still advance only on
      // a real transfer.
      if (enq_ready_o)
        entries_q[tail_q] <= '{
          write: enq_write_i,
          addr: enq_addr_i,
          wdata: enq_wdata_i,
          wstrb: enq_wstrb_i,
          seq: enq_seq_i,
          uop_id: enq_uop_id_i
        };
      if (enq_fire && !(fallthrough && deq_fire)) begin
        tail_q <= tail_q + 1'b1;
      end
      if (deq_fire && !fallthrough) head_q <= head_q + 1'b1;
      unique case ({enq_fire, deq_fire})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial assert (DEPTH == 2)
    else $fatal(1, "dmem_request_fifo currently requires DEPTH=2");
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (count_q <= COUNT_W'(DEPTH))
        else $fatal(1, "dmem request FIFO occupancy overflow");
      if (enq_fast_load_i)
        assert (enq_valid_i && !enq_write_i)
          else $fatal(1, "fast load sideband lacks a canonical load request");
    end
  end
`endif
endmodule
