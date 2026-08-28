`timescale 1ns/1ps
module fetch_bundle_queue #(
  parameter int unsigned DEPTH = 8
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,

  input  logic        enq_valid_i,
  output logic        enq_ready_o,
  input  logic [31:0] enq_pc_i,
  input  logic [63:0] enq_data_i,
  input  logic        enq_error_i,
  input  rv32_pkg::decoded_instr_t enq_dec_i [2],
  input  logic [1:0]  enq_pred_taken_i,
  input  logic [31:0] enq_pred_target_i [2],

  output logic        deq_valid_o,
  output logic [31:0] deq_pc_o,
  output logic [63:0] deq_data_o,
  output logic        deq_error_o,
  output rv32_pkg::decoded_instr_t deq_dec_o [2],
  output logic [1:0]  deq_pred_taken_o,
  output logic [31:0] deq_pred_target_o [2],
  input  logic        deq_pop_i,
  input  logic        deq_advance_i,

  output logic [$clog2(DEPTH+1)-1:0] count_o
);
  localparam int unsigned PTR_W = $clog2(DEPTH);
  localparam int unsigned COUNT_W = $clog2(DEPTH+1);
  localparam int unsigned DEC_W = $bits(rv32_pkg::decoded_instr_t);

  (* ram_style = "distributed" *) logic [31:0] pc_q [DEPTH];
  (* ram_style = "distributed" *) logic [63:0] data_q [DEPTH];
  (* ram_style = "distributed" *) logic error_q [DEPTH];
  // Vivado decomposes an unpacked array of packed structs into independently
  // enabled fields and implements this shallow queue as hundreds of flops.
  // Store the identical packed representation explicitly so each lane is one
  // single-write/asynchronous-read distributed RAM.  Casts are unnecessary:
  // decoded_instr_t is packed and has exactly DEC_W bits.
  (* ram_style = "distributed" *) logic [DEC_W-1:0] dec0_q [DEPTH];
  (* ram_style = "distributed" *) logic [DEC_W-1:0] dec1_q [DEPTH];
  (* ram_style = "distributed" *) logic [1:0] pred_taken_q [DEPTH];
  (* ram_style = "distributed" *) logic [31:0] pred_target0_q [DEPTH];
  (* ram_style = "distributed" *) logic [31:0] pred_target1_q [DEPTH];
  logic [PTR_W-1:0] head_q, tail_q;
  logic [COUNT_W-1:0] count_q;
  logic [31:0] head_pc_q;
  logic [63:0] head_data_q;
  logic head_error_q;
  rv32_pkg::decoded_instr_t head_dec0_q, head_dec1_q;
  logic [1:0] head_pred_taken_q;
  logic [31:0] head_pred_target0_q, head_pred_target1_q;
  logic push, pop, advance;

  assign deq_valid_o = (count_q != 0);
  assign deq_pc_o = head_pc_q;
  assign deq_data_o = head_data_q;
  assign deq_error_o = head_error_q;
  assign deq_dec_o[0] = head_dec0_q;
  assign deq_dec_o[1] = head_dec1_q;
  assign deq_pred_taken_o = head_pred_taken_q;
  assign deq_pred_target_o[0] = head_pred_target0_q;
  assign deq_pred_target_o[1] = head_pred_target1_q;
  assign count_o = count_q;

  // Advertise only registered capacity.  A same-cycle pop becomes visible on
  // the next edge instead of coupling the entire dispatch/resource decision
  // back through response ready into the I-cache request pipeline.
  assign enq_ready_o = (count_q != COUNT_W'(DEPTH));
  assign push = enq_valid_i && enq_ready_o;
  assign pop = deq_valid_o && deq_pop_i;
  assign advance = deq_valid_o && deq_advance_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      head_pc_q <= '0;
      head_data_q <= '0;
      head_error_q <= 1'b0;
      head_dec0_q <= '0;
      head_dec1_q <= '0;
      head_pred_taken_q <= '0;
      head_pred_target0_q <= '0;
      head_pred_target1_q <= '0;
    end else if (flush_i) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else begin
      if (push) begin
        pc_q[tail_q] <= enq_pc_i;
        data_q[tail_q] <= enq_data_i;
        error_q[tail_q] <= enq_error_i;
        dec0_q[tail_q] <= enq_dec_i[0];
        dec1_q[tail_q] <= enq_dec_i[1];
        pred_taken_q[tail_q] <= enq_pred_taken_i;
        pred_target0_q[tail_q] <= enq_pred_target_i[0];
        pred_target1_q[tail_q] <= enq_pred_target_i[1];
        tail_q <= tail_q + 1'b1;
      end
      // The architectural queue head is a dedicated dispatch register.  Load
      // it directly on an empty-queue push, or prefetch the following RAM row
      // while the current head retires.  This removes the asynchronous
      // head-pointer RAM mux from decode/rename without adding a frontend
      // cycle.  The count==1 pop+push case bypasses the same-edge RAM write.
      if (pop) begin
        if (count_q > 1) begin
          head_pc_q <= pc_q[head_q + 1'b1];
          head_data_q <= data_q[head_q + 1'b1];
          head_error_q <= error_q[head_q + 1'b1];
          head_dec0_q <= dec0_q[head_q + 1'b1];
          head_dec1_q <= dec1_q[head_q + 1'b1];
          head_pred_taken_q <= pred_taken_q[head_q + 1'b1];
          head_pred_target0_q <= pred_target0_q[head_q + 1'b1];
          head_pred_target1_q <= pred_target1_q[head_q + 1'b1];
        end else if (push) begin
          head_pc_q <= enq_pc_i;
          head_data_q <= enq_data_i;
          head_error_q <= enq_error_i;
          head_dec0_q <= enq_dec_i[0];
          head_dec1_q <= enq_dec_i[1];
          head_pred_taken_q <= enq_pred_taken_i;
          head_pred_target0_q <= enq_pred_target_i[0];
          head_pred_target1_q <= enq_pred_target_i[1];
        end
        head_q <= head_q + 1'b1;
      end else if (advance) begin
        head_pc_q <= head_pc_q + 32'd4;
        head_dec0_q <= head_dec1_q;
        head_dec1_q <= '0;
        head_pred_taken_q <= {1'b0, head_pred_taken_q[1]};
        head_pred_target0_q <= head_pred_target1_q;
        head_pred_target1_q <= '0;
      end else if (push && (count_q == 0)) begin
        head_pc_q <= enq_pc_i;
        head_data_q <= enq_data_i;
        head_error_q <= enq_error_i;
        head_dec0_q <= enq_dec_i[0];
        head_dec1_q <= enq_dec_i[1];
        head_pred_taken_q <= enq_pred_taken_i;
        head_pred_target0_q <= enq_pred_target_i[0];
        head_pred_target1_q <= enq_pred_target_i[1];
      end

      unique case ({push, pop})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (DEPTH >= 2 && ((DEPTH & (DEPTH-1)) == 0))
      else $fatal(1, "fetch queue depth must be a power of two >= 2");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i) begin
      assert (!(deq_pop_i && deq_advance_i))
        else $fatal(1, "fetch queue pop and half-advance requested together");
      assert (!deq_advance_i || (deq_valid_o && !deq_pc_o[2]))
        else $fatal(1, "fetch queue half-advance requires an aligned head");
      assert (count_q <= COUNT_W'(DEPTH))
        else $fatal(1, "fetch queue count overflowed");
    end
  end
`endif
endmodule
