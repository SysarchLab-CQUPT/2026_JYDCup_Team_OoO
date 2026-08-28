`timescale 1ns/1ps
module tb_issue_queue;
  import rv32_pkg::*;
  import core_types_pkg::*;
  import backend_types_pkg::*;
  logic clk,rst_n;
  logic [1:0] dispatch_valid,dispatch_src1_ready,dispatch_src2_ready,dispatch_accept;
  issue_entry_t dispatch_entry[2],issue_entry;
  logic [2:0] wakeup_valid;
  logic [1:0] select_wakeup_valid;
  logic [7:0] load_mem_ready_bitmap;
  logic [1:0] dispatch_mem_ready;
  preg_t wakeup_preg[3];
  preg_t select_wakeup_preg[2];
  logic issue_valid,issue_ready,flush,recovery_valid;
  rob_ptr_t recovery_start,recovery_end;
  logic [3:0] count;
  logic [2:0] bank0_free,bank1_free;
  logic can_accept_one,can_accept_two;

  issue_queue #(.ENTRIES(4)) dut(
    .clk_i(clk),.rst_ni(rst_n),
    .dispatch_valid_i(dispatch_valid),.dispatch_entry_i(dispatch_entry),
    .dispatch_src1_ready_i(dispatch_src1_ready),.dispatch_src2_ready_i(dispatch_src2_ready),
    .dispatch_mem_ready_i(dispatch_mem_ready),
    .dispatch_accept_o(dispatch_accept),.wakeup_valid_i(wakeup_valid),
    .wakeup_preg_i(wakeup_preg),
    .select_wakeup_valid_i(select_wakeup_valid),
    .select_wakeup_preg_i(select_wakeup_preg),
    .load_mem_ready_bitmap_i(load_mem_ready_bitmap),
    .can_accept_one_o(can_accept_one),.can_accept_two_o(can_accept_two),
    .issue_valid_o(issue_valid),.issue_ready_i(issue_ready),
    .issue_entry_o(issue_entry),
    .issue_ps1_o(),.issue_ps2_o(),.issue_pdst_o(),.issue_fast_wakeup_o(),
    .issue_src1_select_hit_o(),.issue_src2_select_hit_o(),
    .flush_i(flush),
    .recovery_valid_i(recovery_valid),
    .recovery_start_i(recovery_start),.recovery_end_i(recovery_end),.count_o(count),
    .bank0_free_o(bank0_free),.bank1_free_o(bank1_free)
  );
  always #5 clk=~clk;

  initial begin
    clk=0;rst_n=0;dispatch_valid=0;dispatch_src1_ready=0;
    dispatch_src2_ready=0;wakeup_valid=0;select_wakeup_valid=0;
    wakeup_preg[0]=0;wakeup_preg[1]=0;wakeup_preg[2]=0;
    select_wakeup_preg[0]=0;select_wakeup_preg[1]=0;
    issue_ready=1;flush=0;recovery_valid=0;recovery_start='0;recovery_end='0;
    load_mem_ready_bitmap='0; dispatch_mem_ready='1;
    dispatch_entry[0]='0;dispatch_entry[1]='0;
    repeat(3)@(posedge clk);rst_n=1;

    @(negedge clk);
    dispatch_valid=2'b11;
    dispatch_entry[0]='0;dispatch_entry[0].valid=1;dispatch_entry[0].op=UOP_ADD;
    dispatch_entry[0].rob_ptr=6'd0;dispatch_entry[0].uop_id=8'h10;
    dispatch_entry[0].pc=32'h1000_0010;dispatch_entry[0].inst=32'h0101_0133;
    dispatch_entry[0].imm=32'h1234_5678;dispatch_entry[0].predicted_pc=32'h1000_0014;
    dispatch_entry[0].uses_ps1=1;dispatch_entry[0].ps1=6'd40;
    dispatch_entry[1]='0;dispatch_entry[1].valid=1;dispatch_entry[1].op=UOP_SUB;
    dispatch_entry[1].rob_ptr=6'd1;dispatch_entry[1].uop_id=8'h11;
    dispatch_entry[1].pc=32'h2000_0020;dispatch_entry[1].inst=32'h4020_81b3;
    dispatch_entry[1].imm=32'h8765_4321;dispatch_entry[1].predicted_pc=32'h2000_0024;
    dispatch_src1_ready=2'b10;dispatch_src2_ready=2'b11;
    #1;assert(dispatch_accept==2'b11) else $fatal(1,"dual dispatch rejected");
    @(posedge clk);@(negedge clk);dispatch_valid=0;
    #1;assert(issue_valid && issue_entry.uop_id==8'h11 &&
              issue_entry.pc==32'h2000_0020 &&
              issue_entry.inst==32'h4020_81b3 &&
              issue_entry.imm==32'h8765_4321 &&
              issue_entry.predicted_pc==32'h2000_0024)
      else $fatal(1,"younger ready uop did not bypass blocked older uop");
    @(posedge clk);@(negedge clk);
    #1;assert(!issue_valid) else $fatal(1,"blocked uop issued before wakeup");

    wakeup_valid=1;wakeup_preg[0]=40;
    #1;assert(!issue_valid)
      else $fatal(1,"wakeup leaked combinationally into selection");
    @(posedge clk);@(negedge clk);wakeup_valid=0; #1;
    assert(issue_valid && issue_entry.uop_id==8'h10 &&
           issue_entry.pc==32'h1000_0010 &&
           issue_entry.inst==32'h0101_0133 &&
           issue_entry.imm==32'h1234_5678 &&
           issue_entry.predicted_pc==32'h1000_0014)
      else $fatal(1,"registered wakeup did not feed next-cycle selection");
    @(posedge clk);@(negedge clk); #1;
    assert(count==0) else $fatal(1,"issue queue did not drain");
    assert(can_accept_one && can_accept_two)
      else $fatal(1,"empty queue did not export both registered credits");

    // A tag sourced by a registered EX stage may bypass persistent readiness
    // into selection.  The same tag is also presented on the normal wakeup
    // ports so a non-selected consumer would retain readiness at the edge.
    @(negedge clk); dispatch_entry[0]='0; dispatch_entry[0].valid=1;
    dispatch_entry[0].op=UOP_ADD; dispatch_entry[0].rob_ptr=6'd2;
    dispatch_entry[0].uop_id=8'h22; dispatch_entry[0].uses_ps1=1;
    dispatch_entry[0].ps1=6'd42; dispatch_valid=2'b01;
    dispatch_src1_ready=2'b00; dispatch_src2_ready=2'b01;
    @(posedge clk); @(negedge clk); dispatch_valid=0; #1;
    assert(!issue_valid) else $fatal(1,"blocked EX-bypass consumer issued early");
    select_wakeup_valid=2'b01; select_wakeup_preg[0]=6'd42;
    wakeup_valid=3'b001; wakeup_preg[0]=6'd42; #1;
    assert(issue_valid && issue_entry.uop_id==8'h22)
      else $fatal(1,"registered EX tag did not bypass into selection");
    @(posedge clk); @(negedge clk);
    select_wakeup_valid=0; wakeup_valid=0; #1;
    assert(count==0) else $fatal(1,"EX-bypass consumer did not drain");

    // A load's registered LQ dependency bitmap may enter selection in the
    // cycle it becomes visible.  If backpressured, the ordinary IQ ready state
    // must retain it after the bitmap pulse is removed.
    issue_ready=1; load_mem_ready_bitmap='0; dispatch_mem_ready='0;
    dispatch_entry[0]='0; dispatch_entry[0].valid=1;
    dispatch_entry[0].op=UOP_LW; dispatch_entry[0].is_load=1;
    dispatch_entry[0].lq_seq=4'd3;
    dispatch_entry[0].rob_ptr=6'd3; dispatch_entry[0].uop_id=8'h23;
    dispatch_valid=2'b01; dispatch_src1_ready=2'b01; dispatch_src2_ready=2'b01;
    @(posedge clk); @(negedge clk); dispatch_valid=0; #1;
    assert(!issue_valid) else $fatal(1,"load issued before registered mem dependency cleared");
    load_mem_ready_bitmap[3]=1'b1; #1;
    assert(issue_valid && issue_entry.uop_id==8'h23)
      else $fatal(1,"registered LQ mem dependency missed selection bypass");
    issue_ready=0;
    @(posedge clk); @(negedge clk);
    load_mem_ready_bitmap='0; dispatch_mem_ready='1; issue_ready=1; #1;
    assert(issue_valid && issue_entry.uop_id==8'h23)
      else $fatal(1,"LQ mem dependency did not persist under backpressure");
    @(posedge clk); @(negedge clk);

    // Memory readiness must join the age tree, not a younger-priority bypass.
    // Keep a younger ready ALU entry resident while the older load is blocked;
    // once the registered LQ bit appears the older load must win immediately.
    issue_ready=0; dispatch_mem_ready=2'b10; dispatch_valid=2'b11;
    dispatch_src1_ready=2'b11; dispatch_src2_ready=2'b11;
    dispatch_entry[0]='0; dispatch_entry[0].valid=1;
    dispatch_entry[0].op=UOP_LW; dispatch_entry[0].is_load=1;
    dispatch_entry[0].lq_seq=4'd4; dispatch_entry[0].rob_ptr=6'd4;
    dispatch_entry[0].uop_id=8'h24;
    dispatch_entry[1]='0; dispatch_entry[1].valid=1;
    dispatch_entry[1].op=UOP_ADD; dispatch_entry[1].rob_ptr=6'd5;
    dispatch_entry[1].uop_id=8'h25;
    @(posedge clk); @(negedge clk); dispatch_valid=0; #1;
    assert(issue_valid && issue_entry.uop_id==8'h25)
      else $fatal(1,"younger ready entry did not bypass blocked older load");
    load_mem_ready_bitmap[4]=1'b1; #1;
    assert(issue_valid && issue_entry.uop_id==8'h24)
      else $fatal(1,"registered LQ readiness lost IQ age priority");
    issue_ready=1;
    @(posedge clk); @(negedge clk); load_mem_ready_bitmap='0; #1;
    assert(issue_valid && issue_entry.uop_id==8'h25)
      else $fatal(1,"younger entry missing after older load issue");
    @(posedge clk); @(negedge clk); dispatch_mem_ready='1;

    flush=1;@(posedge clk);@(negedge clk);flush=0;
    assert(count==0) else $fatal(1,"flush failed");
    // Same-cycle dispatch + producer wakeup must not lose the wakeup edge.
    @(negedge clk); dispatch_entry[0]='0; dispatch_entry[0].valid=1;
    dispatch_entry[0].op=UOP_ADD;
    dispatch_entry[0].rob_ptr=6'd5; dispatch_entry[0].uses_ps1=1;
    dispatch_entry[0].ps1=6'd40; dispatch_valid=2'b01;
    dispatch_src1_ready=2'b00; dispatch_src2_ready=2'b01;
    wakeup_valid=2'b01; wakeup_preg[0]=6'd40;
    @(posedge clk); @(negedge clk); dispatch_valid=0; wakeup_valid=0; #1;
    assert(issue_valid && issue_entry.rob_ptr==6'd5)
      else $fatal(1,"dispatch+wakeup bypass lost");
    @(posedge clk); @(negedge clk);

    // Recovery kills only younger entries and an older survivor must consume
    // a coincident writeback wakeup.
    issue_ready=0; dispatch_valid=2'b11;
    dispatch_entry[0]='0; dispatch_entry[0].valid=1; dispatch_entry[0].rob_ptr=6'd4;
    dispatch_entry[0].op=UOP_ADD;
    dispatch_entry[0].uses_ps1=1; dispatch_entry[0].ps1=6'd41;
    dispatch_entry[1]='0; dispatch_entry[1].valid=1; dispatch_entry[1].rob_ptr=6'd8;
    dispatch_entry[1].op=UOP_ADD;
    dispatch_entry[1].uses_ps1=1; dispatch_entry[1].ps1=6'd41;
    dispatch_src1_ready=0; dispatch_src2_ready=2'b11;
    @(posedge clk); @(negedge clk); dispatch_valid=0;
    recovery_start=6'd8; recovery_end=6'd9; recovery_valid=1;
    wakeup_valid=2'b01; wakeup_preg[0]=6'd41;
    @(posedge clk); @(negedge clk); recovery_valid=0; wakeup_valid=0; #1;
    assert(count==1 && issue_valid && issue_entry.rob_ptr==6'd4)
      else $fatal(1,"selective recovery or coincident wakeup failed");
    issue_ready=1; @(posedge clk); @(negedge clk);

    // If the row selected for issue is itself inside the recovery range, the
    // valid bitmap and the registered occupancy must delete it exactly once.
    issue_ready=0; dispatch_valid=2'b01;
    dispatch_entry[0]='0; dispatch_entry[0].valid=1;
    dispatch_entry[0].rob_ptr=6'd12; dispatch_entry[0].op=UOP_ADD;
    dispatch_src1_ready=2'b01; dispatch_src2_ready=2'b01;
    @(posedge clk); @(negedge clk); dispatch_valid=0; issue_ready=1;
    recovery_start=6'd12; recovery_end=6'd13; recovery_valid=1; #1;
    assert(issue_valid && issue_entry.rob_ptr==6'd12)
      else $fatal(1,"recovery victim was not presented to narrow EX kill path");
    @(posedge clk); @(negedge clk); recovery_valid=0; #1;
    assert(count==0 && !issue_valid)
      else $fatal(1,"recovery victim was double-counted during coincident issue");

    // Half-open recovery intervals must remain exact across ROB wrap.
    issue_ready=0; dispatch_valid=2'b11;
    dispatch_entry[0]='0; dispatch_entry[0].valid=1;
    dispatch_entry[0].rob_ptr=6'd62; dispatch_entry[0].op=UOP_ADD;
    dispatch_entry[1]='0; dispatch_entry[1].valid=1;
    dispatch_entry[1].rob_ptr=6'd1; dispatch_entry[1].op=UOP_ADD;
    dispatch_src1_ready=2'b11; dispatch_src2_ready=2'b11;
    @(posedge clk); @(negedge clk); dispatch_valid=0;
    recovery_start=6'd63; recovery_end=6'd2; recovery_valid=1;
    @(posedge clk); @(negedge clk); recovery_valid=0; #1;
    assert(count==1 && issue_valid && issue_entry.rob_ptr==6'd62)
      else $fatal(1,"wrapped half-open recovery interval was not exact");
    issue_ready=1; @(posedge clk); @(negedge clk);
    $display("PASS tb_issue_queue");$finish;
  end
endmodule
