`timescale 1ns/1ps
module tb_rob;
  import soc_cfg_pkg::*;
  import core_types_pkg::*;

  logic clk;
  logic rst_n;
  logic [1:0] alloc_valid;
  logic [31:0] alloc_pc [2];
  logic [31:0] alloc_inst [2];
  logic [1:0] alloc_rd_wen;
  logic [4:0] alloc_rd_addr [2];
  preg_t alloc_pdst [2];
  preg_t alloc_stale_pdst [2];
  logic [1:0] alloc_accept;
  rob_ptr_t alloc_rob_ptr [2];
  uop_id_t alloc_uop_id [2];
  logic [1:0] complete_valid;
  uop_id_t complete_uop_id [2];
  logic [31:0] complete_result [2];
  logic [1:0] complete_exception;
  logic [31:0] complete_cause [2];
  logic [31:0] complete_tval [2];
  logic [1:0] retire_count;
  logic recovery_valid;
  rob_ptr_t recovery_tail;
  rob_entry_t head_entry [2];
  rob_ptr_t head_ptr;
  rob_ptr_t tail_ptr;
  logic [5:0] count;
  uop_id_t id0;
  uop_id_t id1;

  rob dut (
    .clk_i(clk), .rst_ni(rst_n),
    .alloc_valid_i(alloc_valid), .alloc_pc_i(alloc_pc),
    .alloc_inst_i(alloc_inst), .alloc_rd_wen_i(alloc_rd_wen),
    .alloc_rd_addr_i(alloc_rd_addr), .alloc_pdst_i(alloc_pdst),
    .alloc_stale_pdst_i(alloc_stale_pdst),
    .alloc_accept_o(alloc_accept), .alloc_rob_ptr_o(alloc_rob_ptr),
    .alloc_uop_id_o(alloc_uop_id),
    .complete_valid_i(complete_valid), .complete_uop_id_i(complete_uop_id),
    .complete_result_i(complete_result),
    .complete_exception_i(complete_exception),
    .complete_cause_i(complete_cause), .complete_tval_i(complete_tval),
    .retire_count_i(retire_count), .recovery_valid_i(recovery_valid),
    .recovery_tail_i(recovery_tail), .head_entry_o(head_entry),
    .head_ptr_o(head_ptr), .tail_ptr_o(tail_ptr), .count_o(count)
  );

  always #5 clk = ~clk;

  task automatic step;
    @(posedge clk);
    #1;
  endtask

  task automatic clear_inputs;
    alloc_valid = 0;
    complete_valid = 0;
    complete_exception = 0;
    retire_count = 0;
    recovery_valid = 0;
  endtask

  initial begin
    clk = 0;
    rst_n = 0;
    clear_inputs();
    recovery_tail = 0;
    for (int lane = 0; lane < 2; lane++) begin
      alloc_pc[lane] = 0;
      alloc_inst[lane] = 32'h0000_0013;
      alloc_rd_wen[lane] = 0;
      alloc_rd_addr[lane] = 0;
      alloc_pdst[lane] = 0;
      alloc_stale_pdst[lane] = 0;
      complete_uop_id[lane] = 0;
      complete_result[lane] = 0;
      complete_cause[lane] = 0;
      complete_tval[lane] = 0;
    end
    step();
    rst_n = 1;
    step();

    // Dual allocation, dual indexed completion, then dual retirement.
    alloc_valid = 2'b11;
    alloc_pc[0] = 32'h0;
    alloc_pc[1] = 32'h4;
    alloc_rd_wen = 2'b11;
    alloc_rd_addr[0] = 5'd1;
    alloc_rd_addr[1] = 5'd2;
    alloc_pdst[0] = 6'd32;
    alloc_pdst[1] = 6'd33;
    #1;
    assert (alloc_accept == 2'b11);
    id0 = alloc_uop_id[0];
    id1 = alloc_uop_id[1];
    assert (alloc_rob_ptr[0] == 0 && alloc_rob_ptr[1] == 1);
    step();
    alloc_valid = 0;
    assert (count == 2);
    assert (head_entry[0].pc == 0 && head_entry[1].pc == 4);

    complete_valid = 2'b11;
    complete_uop_id[0] = id0;
    complete_uop_id[1] = id1;
    complete_result[0] = 32'h1111_1111;
    complete_result[1] = 32'h2222_2222;
    step();
    complete_valid = 0;
    assert (head_entry[0].done && head_entry[1].done);
    assert (head_entry[0].result == 32'h1111_1111);
    assert (head_entry[1].result == 32'h2222_2222);

    retire_count = 2;
    step();
    retire_count = 0;
    assert (count == 0);

    // Allocate branch + younger lane, then another younger uop. Recovery tail
    // is after the branch, so both younger uops must be discarded.
    alloc_valid = 2'b11;
    alloc_pc[0] = 32'h100;
    alloc_pc[1] = 32'h104;
    #1;
    id0 = alloc_uop_id[0];
    recovery_tail = rob_ptr_add(alloc_rob_ptr[0], 2'd1);
    step();
    alloc_valid = 2'b01;
    alloc_pc[0] = 32'h108;
    step();
    alloc_valid = 0;
    assert (count == 3);
    recovery_valid = 1;
    step();
    recovery_valid = 0;
    assert (count == 1);
    assert (head_entry[0].valid && head_entry[0].pc == 32'h100);
    assert (!head_entry[1].valid);

    complete_valid[0] = 1;
    complete_uop_id[0] = id0;
    complete_result[0] = 32'h1234_5678;
    step();
    complete_valid = 0;
    retire_count = 1;
    step();
    retire_count = 0;
    assert (count == 0);

    // Exercise pointer wrap with one allocate/complete/retire transaction per
    // cycle group. Raw pointer order is intentionally allowed to wrap.
    for (int n = 0; n < 34; n++) begin
      alloc_valid = 2'b01;
      alloc_pc[0] = 32'h200 + n*4;
      #1;
      id0 = alloc_uop_id[0];
      step();
      alloc_valid = 0;
      complete_valid[0] = 1;
      complete_uop_id[0] = id0;
      complete_result[0] = n;
      step();
      complete_valid = 0;
      assert (head_entry[0].done);
      retire_count = 1;
      step();
      retire_count = 0;
      assert (count == 0);
    end
    assert (head_ptr == tail_ptr);
    assert (head_ptr[ROB_INDEX_W-1:0] == 5'd5);

    // Fill the ROB, then retire and request allocation in the same cycle.
    // The retiring slot is deliberately visible to allocation only after the
    // edge, which cuts the commit-to-dispatch credit path.
    for (int n = 0; n < 16; n++) begin
      alloc_valid = 2'b11;
      alloc_pc[0] = 32'h400 + n*8;
      alloc_pc[1] = 32'h404 + n*8;
      #1;
      assert (alloc_accept == 2'b11);
      step();
    end
    alloc_valid = 0;
    assert (count == 32);
    alloc_valid = 2'b01;
    retire_count = 1;
    #1;
    assert (alloc_accept == 2'b00)
      else $fatal(1, "ROB reused a retiring slot combinationally");
    step();
    retire_count = 0;
    #1;
    assert (count == 31 && alloc_accept == 2'b01)
      else $fatal(1, "ROB slot unavailable after registered retirement boundary");
    step();
    alloc_valid = 0;
    assert (count == 32);

    $display("PASS tb_rob");
    $finish;
  end
endmodule
