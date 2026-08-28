`timescale 1ns/1ps
module tb_branch_checkpoints;
  import core_types_pkg::*;
  logic clk,rst_n,flush;
  rob_ptr_t alloc_rob_ptr[2];
  preg_t alloc_map[2][32],recovery_map[32];
  logic[1:0]alloc_valid,alloc_accept;
  logic alloc_two_ready;
  logic[3:0]alloc_id[2],release_id,recovery_id;
  logic[3:0]saved_alloc_id;
  logic[3:0]saved_bank1_id[4];
  logic release_valid,recovery_valid,recovery_found;
  logic[3:0]count;
  branch_checkpoints dut(
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),.rob_tail_i(6'd1),.alloc_valid_i(alloc_valid),
    .alloc_rob_ptr_i(alloc_rob_ptr),.alloc_map_i(alloc_map),.alloc_accept_o(alloc_accept),
    .alloc_id_o(alloc_id),.alloc_two_ready_o(alloc_two_ready),
    .release_valid_i(release_valid),.release_id_i(release_id),
    .recovery_valid_i(recovery_valid),.recovery_id_i(recovery_id),
    .recovery_found_o(recovery_found),.recovery_map_o(recovery_map),.count_o(count)
  );
  always #5 clk=~clk;
  initial begin
    clk=0;rst_n=0;flush=0;alloc_valid=0;release_valid=0;recovery_valid=0;
    release_id=0;recovery_id=0;alloc_rob_ptr[0]=6'd63;alloc_rob_ptr[1]=6'd0;
    for(int lane=0;lane<2;lane++)for(int r=0;r<32;r++)alloc_map[lane][r]=preg_t'(r);
    alloc_map[0][5]=40;alloc_map[1][5]=41;
    repeat(3)@(posedge clk);rst_n=1;
    @(negedge clk);alloc_valid=2'b11;#1;assert(alloc_accept==2'b11) else $fatal(1,"dual cp alloc");
    saved_alloc_id=alloc_id[0];
    @(posedge clk);@(negedge clk);alloc_valid=0;
    assert(count==2) else $fatal(1,"cp count");
    recovery_id=saved_alloc_id;#1;assert(recovery_found&&recovery_map[5]==40) else $fatal(1,"cp map read");
    recovery_valid=1;@(posedge clk);@(negedge clk);recovery_valid=0;
    assert(count==0) else $fatal(1,"recovery did not discard branch and younger cp");
    alloc_valid=2'b11;@(posedge clk);@(negedge clk);alloc_valid=0;
    assert(count==2) else $fatal(1,"cp refill before full flush");
    flush=1;#1;assert(alloc_accept==0) else $fatal(1,"flush accepted allocation");
    @(posedge clk);@(negedge clk);flush=0;
    assert(count==0) else $fatal(1,"full flush did not clear checkpoints");

    // Fill all eight entries.  Releasing a checkpoint must not make its row
    // available to a same-cycle allocation; reuse starts after the edge.
    for(int n=0;n<4;n++) begin
      alloc_rob_ptr[0]=rob_ptr_t'(n*2);
      alloc_rob_ptr[1]=rob_ptr_t'(n*2+1);
      alloc_valid=2'b11;
      #1;
      assert(alloc_accept==2'b11) else $fatal(1,"checkpoint fill rejected");
      if(n==0) saved_alloc_id=alloc_id[0];
      @(posedge clk);@(negedge clk);
    end
    alloc_valid=0;
    assert(count==8) else $fatal(1,"checkpoint bank did not fill");
    alloc_valid=2'b01;
    release_valid=1;
    release_id=saved_alloc_id;
    #1;
    assert(alloc_accept==0)
      else $fatal(1,"checkpoint row reused combinationally on release");
    @(posedge clk);@(negedge clk);
    release_valid=0;
    #1;
    assert(count==7 && alloc_accept==2'b01)
      else $fatal(1,"released checkpoint unavailable after registered boundary");
    @(posedge clk);@(negedge clk);
    alloc_valid=0;
    assert(count==8) else $fatal(1,"checkpoint refill count mismatch");

    // Releasing two entries from one bank creates a 4/2 skew at count six.
    // Seven physical rows per bank are the minimum depth that still guarantees
    // an atomic dual allocation for every legal eight-entry population.
    flush=1;@(posedge clk);@(negedge clk);flush=0;
    for(int n=0;n<4;n++) begin
      alloc_rob_ptr[0]=rob_ptr_t'(n*2);
      alloc_rob_ptr[1]=rob_ptr_t'(n*2+1);
      alloc_valid=2'b11;#1;
      assert(alloc_accept==2'b11 && alloc_two_ready)
        else $fatal(1,"balanced dual checkpoint fill rejected");
      saved_bank1_id[n]=alloc_id[1];
      @(posedge clk);@(negedge clk);
    end
    alloc_valid=0;
    release_valid=1;release_id=saved_bank1_id[0];
    @(posedge clk);@(negedge clk);
    release_id=saved_bank1_id[1];
    @(posedge clk);@(negedge clk);
    release_valid=0;alloc_valid=2'b11;#1;
    assert(count==6 && alloc_two_ready && alloc_accept==2'b11)
      else $fatal(1,"skewed banks rejected legal atomic dual allocation");
    @(posedge clk);@(negedge clk);alloc_valid=0;
    assert(count==8) else $fatal(1,"atomic checkpoint refill count mismatch");

    $display("PASS tb_branch_checkpoints");$finish;
  end
endmodule
