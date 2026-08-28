`timescale 1ns/1ps
module tb_load_queue;
  import core_types_pkg::*;
  import rv32_pkg::*;

  logic clk, rst_n;
  logic [1:0] alloc_valid, alloc_accept;
  rob_ptr_t alloc_rob_ptr [2];
  uop_id_t alloc_uop_id [2];
  preg_t alloc_pdst [2];
  logic [3:0] alloc_older_sq_tail [2];
  logic [7:0] alloc_older_pending [2];
  logic [3:0] alloc_seq [2];
  logic [7:0] store_addr_done;
  logic [7:0] mem_dep_ready;
  logic [7:0] mem_dep_ready_set;
  logic execute_valid;
  logic [3:0] execute_seq;
  uop_id_t execute_uop_id;
  logic [31:0] execute_addr;
  mem_size_e execute_size;
  logic execute_unsigned;
  logic [3:0] execute_fwd_mask;
  logic [31:0] execute_fwd_data;
  logic request_valid, request_ready;
  logic [31:0] request_addr;
  logic [3:0] request_seq;
  uop_id_t request_uop_id;
  logic [3:0] request_older_sq_tail;
  logic request_fast;
  logic response_valid;
  logic [3:0] response_seq;
  uop_id_t response_uop_id;
  logic [31:0] response_data;
  logic response_error;
  logic wb_valid, wb_ready;
  uop_id_t wb_uop_id;
  preg_t wb_pdst;
  logic [31:0] wb_data, wb_fault_addr;
  logic wb_error;
  logic wakeup_valid;
  preg_t wakeup_pdst;
  logic [1:0] release_valid;
  logic [3:0] release_seq [2];
  logic recovery_valid;
  logic [3:0] recovery_tail;
  logic [3:0] head, alloc_tail, count;
  logic empty;

  load_queue dut (
    .clk_i(clk), .rst_ni(rst_n), .alloc_valid_i(alloc_valid),
    .alloc_uop_id_i(alloc_uop_id),
    .alloc_pdst_i(alloc_pdst), .alloc_older_sq_tail_i(alloc_older_sq_tail),
    .alloc_older_addr_pending_i(alloc_older_pending),
    .alloc_accept_o(alloc_accept), .alloc_seq_o(alloc_seq),
    .store_addr_done_onehot_i(store_addr_done),
    .mem_dep_ready_bitmap_o(mem_dep_ready), .mem_dep_ready_set_o(mem_dep_ready_set),
    .execute_valid_i(execute_valid),
    .execute_seq_i(execute_seq), .execute_uop_id_i(execute_uop_id),
    .execute_addr_i(execute_addr), .execute_size_i(execute_size),
    .execute_unsigned_i(execute_unsigned),
    .execute_older_sq_tail_i(4'b0),
    .execute_forward_mask_i(execute_fwd_mask),
    .execute_forward_data_i(execute_fwd_data), .request_valid_o(request_valid),
    .request_ready_i(request_ready), .request_addr_o(request_addr),
    .request_seq_o(request_seq), .request_uop_id_o(request_uop_id),
    .request_older_sq_tail_o(request_older_sq_tail),
    .request_fast_o(request_fast),
    .response_valid_i(response_valid), .response_seq_i(response_seq),
    .response_uop_id_i(response_uop_id), .response_data_i(response_data),
    .response_error_i(response_error), .wb_valid_o(wb_valid),
    .wb_ready_i(wb_ready), .wb_uop_id_o(wb_uop_id), .wb_pdst_o(wb_pdst),
    .wb_data_o(wb_data), .wb_error_o(wb_error),
    .wb_fault_addr_o(wb_fault_addr),
    .wakeup_valid_o(wakeup_valid), .wakeup_pdst_o(wakeup_pdst),
    .release_valid_i(release_valid),
    .release_seq_i(release_seq), .recovery_valid_i(recovery_valid),
    .recovery_alloc_tail_i(recovery_tail), .head_o(head),
    .alloc_tail_o(alloc_tail), .count_o(count), .empty_o(empty)
  );

  always #5 clk = ~clk;

  task automatic execute_load(
    input logic [3:0] seq,
    input uop_id_t id,
    input logic [31:0] addr,
    input mem_size_e size,
    input logic is_unsigned,
    input logic [3:0] fwd_mask,
    input logic [31:0] fwd_data
  );
    @(negedge clk);
    execute_valid = 1'b1;
    execute_seq = seq;
    execute_uop_id = id;
    execute_addr = addr;
    execute_size = size;
    execute_unsigned = is_unsigned;
    execute_fwd_mask = fwd_mask;
    execute_fwd_data = fwd_data;
    @(posedge clk);
    @(negedge clk);
    execute_valid = 1'b0;
  endtask

  task automatic consume_wb(
    input uop_id_t id,
    input logic [31:0] expected
  );
    while (!wb_valid) @(negedge clk);
    assert (wb_uop_id == id && wb_data == expected && !wb_error)
      else $fatal(1, "LQ WB expected id=%x data=%x got id=%x data=%x err=%0b",
                  id, expected, wb_uop_id, wb_data, wb_error);
    assert (wakeup_valid && (wakeup_pdst == wb_pdst))
      else $fatal(1, "LQ narrow wakeup diverged from selected WB pdst=%0d wake=%0b/%0d",
                  wb_pdst, wakeup_valid, wakeup_pdst);
    wb_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    wb_ready = 1'b0;
  endtask

  initial begin
    #5000 $fatal(1, "LQ test timeout");
  end

  initial begin
    clk = 0; rst_n = 0; alloc_valid = 0; store_addr_done = 0;
    execute_valid = 0; request_ready = 0; response_valid = 0;
    response_seq = 0; response_uop_id = 0; response_data = 0;
    response_error = 0; wb_ready = 0; release_valid = 0;
    release_seq[0] = 0; release_seq[1] = 0;
    recovery_valid = 0; recovery_tail = 0;
    execute_seq = 0; execute_uop_id = 0; execute_addr = 0;
    execute_size = MEM_SIZE_W; execute_unsigned = 0;
    execute_fwd_mask = 0; execute_fwd_data = 0;
    for (int lane = 0; lane < 2; lane++) begin
      alloc_rob_ptr[lane] = lane;
      alloc_uop_id[lane] = 8'h40 + lane;
      alloc_pdst[lane] = 6'd40 + lane;
      alloc_older_sq_tail[lane] = 4'd2;
      alloc_older_pending[lane] = (lane == 0) ? 8'b0000_1000 : 8'b0;
    end
    repeat (3) @(posedge clk);
    rst_n = 1;

    @(negedge clk); alloc_valid = 2'b11; #1;
    assert (alloc_accept == 2'b11 && alloc_seq[0] == 0 && alloc_seq[1] == 1)
      else $fatal(1, "LQ dual allocation sequence incorrect");
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    assert (!mem_dep_ready[0] && mem_dep_ready[1])
      else $fatal(1, "LQ registered store-address dependency incorrect");
    store_addr_done = 8'b0000_1000;
    #1;
    assert (!mem_dep_ready[0])
      else $fatal(1, "LQ exposed same-cycle store-address wakeup");
    assert (mem_dep_ready_set[0])
      else $fatal(1, "LQ did not emit final store-address completion event");
    @(posedge clk); @(negedge clk); store_addr_done = 0;
    #1;
    assert (mem_dep_ready[0])
      else $fatal(1, "LQ did not publish registered store-address wakeup");
    assert (!mem_dep_ready_set[0])
      else $fatal(1, "LQ mem-ready event was not a single transition pulse");

    // Younger load is fully forwarded and may write back first.
    request_ready = 1'b1;
    execute_load(1, 8'h41, 32'h102, MEM_SIZE_B, 1'b1,
                 4'b0100, 32'h00bb_0000);
    request_ready = 1'b0;
    consume_wb(8'h41, 32'h0000_00bb);

    // Older load merges byte 1 from SQ with the cache word.
    execute_load(0, 8'h40, 32'h100, MEM_SIZE_W, 1'b0,
                 4'b0010, 32'h0000_aa00);
    assert (request_valid && request_seq == 0 && request_uop_id == 8'h40 &&
            request_addr == 32'h100)
      else $fatal(1, "LQ request selection incorrect valid=%0b seq=%x id=%x addr=%x qvalid=%0b direct=%0b capture=%0b",
                  request_valid, request_seq, request_uop_id, request_addr,
                  dut.request_q_valid, dut.request_from_execute,
                  dut.request_q_capture_execute);
    request_ready = 1'b1;
    @(posedge clk); @(negedge clk); request_ready = 1'b0;

    // A late response with the reused sequence but wrong generation is ignored.
    response_valid = 1'b1; response_seq = 0; response_uop_id = 8'hc0;
    response_data = 32'hdead_beef;
    @(posedge clk); @(negedge clk); response_valid = 1'b0;
    assert (!wb_valid) else $fatal(1,
      "LQ accepted stale response identity: wb_id=%x rsp_match=%0b wb_bitmap=%b rr0=%0b rr1=%0b done0=%0b done1=%0b re_valid=%0b re_seq=%x re_id=%x re_issued=%0b re_done=%0b",
      wb_uop_id, dut.response_match, dut.wb_bitmap,
      dut.response_ready_q[0], dut.response_ready_q[1],
      dut.done_q[0], dut.done_q[1], dut.response_entry.valid,
      dut.response_entry.seq, dut.response_entry.uop_id,
      dut.response_entry.issued, dut.response_entry.done);
    assert (!wakeup_valid)
      else $fatal(1, "LQ stale response emitted a wakeup for pdst=%0d", wakeup_pdst);

    response_valid = 1'b1; response_seq = 0; response_uop_id = 8'h40;
    response_data = 32'h1122_3344;
    @(posedge clk); @(negedge clk); response_valid = 1'b0;
    consume_wb(8'h40, 32'h1122_aa44);

    release_valid = 2'b11; release_seq[0] = 0; release_seq[1] = 1;
    @(posedge clk); @(negedge clk); release_valid = 0;
    assert (empty && count == 0 && head == 2)
      else $fatal(1, "LQ commit release did not retain entries until commit");

    // Recovery keeps the older completed load and removes only the younger one.
    alloc_uop_id[0] = 8'h52; alloc_uop_id[1] = 8'h53;
    alloc_pdst[0] = 6'd42; alloc_pdst[1] = 6'd43;
    alloc_older_pending[0] = 0; alloc_older_pending[1] = 0;
    @(negedge clk); alloc_valid = 2'b11;
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    request_ready = 1'b1;
    execute_load(2, 8'h52, 32'h104, MEM_SIZE_B, 1'b1,
                 4'b0001, 32'h0000_007f);
    request_ready = 1'b0;
    consume_wb(8'h52, 32'h0000_007f);
    recovery_valid = 1'b1; recovery_tail = 4'd3;
    @(posedge clk); @(negedge clk); recovery_valid = 1'b0;
    assert (alloc_tail == 3 && count == 1)
      else $fatal(1, "LQ recovery tail rollback incorrect");
    release_valid = 2'b01; release_seq[0] = 2;
    @(posedge clk); @(negedge clk); release_valid = 0;
    assert (empty && head == 3) else $fatal(1, "LQ recovery survivor release failed");

    // Advance the logical head to slot 7, then make slots 7 and 0 ready.
    // Old physical-slot priority selected the younger seq 8 in slot 0 and
    // deadlocked head-only MMIO ordering.  Selection must begin at head.
    alloc_uop_id[0] = 8'h63; alloc_uop_id[1] = 8'h64;
    alloc_pdst[0] = 6'd44; alloc_pdst[1] = 6'd45;
    @(negedge clk); alloc_valid = 2'b11;
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    request_ready = 1'b1;
    execute_load(3, 8'h63, 32'h10c, MEM_SIZE_W, 1'b0,
                 4'b1111, 32'h3333_3333);
    request_ready = 1'b0;
    consume_wb(8'h63, 32'h3333_3333);
    request_ready = 1'b1;
    execute_load(4, 8'h64, 32'h110, MEM_SIZE_W, 1'b0,
                 4'b1111, 32'h4444_4444);
    request_ready = 1'b0;
    consume_wb(8'h64, 32'h4444_4444);
    release_valid = 2'b11; release_seq[0] = 3; release_seq[1] = 4;
    @(posedge clk); @(negedge clk); release_valid = 0;

    alloc_uop_id[0] = 8'h65; alloc_uop_id[1] = 8'h66;
    alloc_pdst[0] = 6'd46; alloc_pdst[1] = 6'd47;
    @(negedge clk); alloc_valid = 2'b11;
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    request_ready = 1'b1;
    execute_load(5, 8'h65, 32'h114, MEM_SIZE_W, 1'b0,
                 4'b1111, 32'h5555_5555);
    request_ready = 1'b0;
    consume_wb(8'h65, 32'h5555_5555);
    request_ready = 1'b1;
    execute_load(6, 8'h66, 32'h118, MEM_SIZE_W, 1'b0,
                 4'b1111, 32'h6666_6666);
    request_ready = 1'b0;
    consume_wb(8'h66, 32'h6666_6666);
    release_valid = 2'b11; release_seq[0] = 5; release_seq[1] = 6;
    @(posedge clk); @(negedge clk); release_valid = 0;
    assert (empty && head == 7)
      else $fatal(1, "LQ wraparound setup did not reach head 7");

    alloc_uop_id[0] = 8'h77; alloc_uop_id[1] = 8'h78;
    alloc_pdst[0] = 6'd48; alloc_pdst[1] = 6'd49;
    @(negedge clk); alloc_valid = 2'b11;
    @(posedge clk); @(negedge clk); alloc_valid = 0;
    execute_load(7, 8'h77, 32'h1000_0008, MEM_SIZE_W, 1'b1,
                 4'b0000, 32'b0);
    execute_load(8, 8'h78, 32'h1000_0008, MEM_SIZE_W, 1'b1,
                 4'b0000, 32'b0);
    #1;
    assert (request_valid && request_seq == 7 && request_uop_id == 8'h77)
      else $fatal(1, "LQ wraparound request did not select logical head");

    $display("PASS tb_load_queue");
    $finish;
  end
endmodule
