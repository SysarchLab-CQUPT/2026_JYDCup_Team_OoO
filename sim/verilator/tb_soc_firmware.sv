`timescale 1ns/1ps
module tb_soc_firmware #(
  parameter int unsigned SOC_CLK_HZ = 50_000_000
);
  import backend_types_pkg::*;
  import rv32_pkg::*;
  import core_types_pkg::*;
  logic clk;
  logic rst_n;
  logic uart_rx;
  logic uart_tx;
  logic timer_irq;
  logic ext_irq;
  logic [31:0] debug_pc;
  logic [5:0] debug_rob_count;
  logic [31:0] timer_count;
  logic [3:0] irq_pending;
  logic coremark_led;
  int unsigned coremark_led_rises;
  int unsigned coremark_led_falls;
  logic coremark_led_q;
  int unsigned cycles;
  int unsigned max_cycles;
  logic [31:0] completion;
  string mem_file;
  logic trace_commits;
  logic trace_irq;
  logic trace_pipe;
  logic trace_mem;
  logic expect_coremark_led;
  logic uart_tx_previous_was_cr;
  int unsigned requested_coremark_runs;
  int unsigned coremark_gap_cycles;
  int unsigned command_wait_cycles;
  int unsigned interrupt_traps;
  int unsigned interrupt_returns;
  localparam int unsigned RAM_BYTES = soc_cfg_pkg::RAM_BYTES;
  localparam int unsigned RAM_ADDR_BITS = $clog2(RAM_BYTES);
  logic [7:0] shadow_data [0:RAM_BYTES-1];
  logic       shadow_valid [0:RAM_BYTES-1];
  logic [7:0] commit_shadow_data [0:RAM_BYTES-1];
  logic       commit_shadow_valid [0:RAM_BYTES-1];
  logic [31:0] load_expected_data [0:255];
  logic [3:0]  load_expected_mask [0:255];
  logic [31:0] load_expected_addr [0:255];
  logic        load_expected_valid [0:255];
  logic [31:0] interrupt_snapshot [0:31];
  logic [5:0]  interrupt_snapshot_map [0:31];
  logic        interrupt_snapshot_valid;
  logic        coremark_active;
  logic [63:0] perf_active_cycles;
  logic [63:0] perf_retired_insts;
  logic [63:0] perf_retire_cycles;
  logic [63:0] perf_dual_retire_cycles;
  logic [63:0] perf_dispatch_insts;
  logic [63:0] perf_fetch_requests;
  logic [63:0] perf_fetch_responses;
  logic [63:0] perf_frontend_empty_cycles;
  logic [63:0] perf_redirects;
  logic [63:0] perf_stale_responses;
  logic [63:0] perf_early_redirects;
  logic [63:0] perf_frontend_resource_stalls;
  logic [63:0] perf_lane1_stalls;
  logic [63:0] perf_head_empty_cycles;
  logic [63:0] perf_head_wait_cycles;
  logic [63:0] perf_head_done_block_cycles;
  logic [63:0] perf_rob_full_cycles;
  logic [63:0] perf_iq0_full_cycles;
  logic [63:0] perf_iq1_full_cycles;
  logic [63:0] perf_issue_both_cycles;
  logic [63:0] perf_head_wait_load;
  logic [63:0] perf_head_wait_store;
  logic [63:0] perf_head_wait_control;
  logic [63:0] perf_head_wait_other;
  logic [63:0] perf_iq1_backpressure;
  logic [63:0] perf_ex1_load_busy;
  logic [63:0] perf_issue0_count, perf_issue1_count;
  logic [63:0] perf_issue1_load, perf_issue1_store, perf_issue1_muldiv;
  logic [63:0] perf_dcache_load_accept, perf_dcache_hit;
  logic [63:0] perf_dcache_miss, perf_branch_resolve, perf_branch_mispredict;
  logic [63:0] perf_mispredict_cond, perf_mispredict_jalr;

  localparam longint unsigned COREMARK_BASELINE_WORK = 64'd2_976_237;
  localparam int unsigned UART_BIT_CYCLES =
    (SOC_CLK_HZ + 57_600) / 115_200;
  localparam int unsigned STARTUP_WAIT_CYCLES =
    (1_500_000 * (SOC_CLK_HZ / 1_000_000)) / 50;
  localparam int unsigned COMMAND_WAIT_CYCLES =
    (5_000_000 * (SOC_CLK_HZ / 1_000_000)) / 50;

  function automatic logic [31:0] committed_register_value(
    input int unsigned arch_reg
  );
    logic [5:0] preg;
    begin
      preg = dut.u_core.u_rename_map.rrat_q[arch_reg];
      if (preg == 0)
        committed_register_value = '0;
      else if (dut.u_core.u_prf.u_lane0.latest_bank_q[preg])
        committed_register_value = dut.u_core.u_prf.u_lane0.bank1_r0_q[preg];
      else
        committed_register_value = dut.u_core.u_prf.u_lane0.bank0_r0_q[preg];
    end
  endfunction

  function automatic logic issue_operand_available(input preg_t ps);
    return dut.u_core.prf_ready[ps] ||
      (dut.u_core.ex0_forward_valid && (dut.u_core.ex0_q.pdst == ps)) ||
      (dut.u_core.ex1_forward_valid && (dut.u_core.ex1_q.pdst == ps)) ||
      (dut.u_core.mul_pipe_forward_valid &&
       (dut.u_core.mul_result_pdst_q == ps)) ||
      (dut.u_core.prf_wb_valid[0] && (dut.u_core.prf_wb_preg[0] == ps)) ||
      (dut.u_core.prf_wb_valid[1] && (dut.u_core.prf_wb_preg[1] == ps));
  endfunction

  ooo_soc_system #(
    .CLK_HZ(SOC_CLK_HZ),
    .UART_BAUD(5_000_000),
    .MEM_INIT_FILE("")
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
    .timer_irq_o(timer_irq), .ext_irq_o(ext_irq), .debug_pc_o(debug_pc),
    .debug_rob_count_o(debug_rob_count), .timer_count_o(timer_count),
    .irq_pending_o(irq_pending), .coremark_led_o(coremark_led)
  );

  always #10 clk = ~clk;

  task automatic uart_send_byte(input byte value);
    int bit_index;
    begin
      uart_rx = 1'b0;
      repeat (UART_BIT_CYCLES) @(posedge clk);
      for (bit_index = 0; bit_index < 8; bit_index++) begin
        uart_rx = value[bit_index];
        repeat (UART_BIT_CYCLES) @(posedge clk);
      end
      uart_rx = 1'b1;
      repeat (UART_BIT_CYCLES) @(posedge clk);
    end
  endtask

  task automatic uart_send_string(input string value);
    int index;
    begin
      for (index = 0; index < value.len(); index++) begin
        uart_send_byte(value.getc(index));
      end
    end
  endtask

  initial begin
    uart_rx = 1'b1;
    requested_coremark_runs = 1;
    coremark_gap_cycles = 13_000_000;
    command_wait_cycles = COMMAND_WAIT_CYCLES;
    void'($value$plusargs("COREMARK_RUNS=%d", requested_coremark_runs));
    void'($value$plusargs("COREMARK_GAP_CYCLES=%d", coremark_gap_cycles));
    void'($value$plusargs("COMMAND_WAIT_CYCLES=%d", command_wait_cycles));
    wait (rst_n);
    if ($test$plusargs("UART_COMMANDS")) begin
      // Let the 115200-baud banner and prompt drain, then exercise the actual
      // synchronized UART RX pin rather than reaching into an MMIO register.
      repeat (STARTUP_WAIT_CYCLES) @(posedge clk);
      uart_send_string("help\r");
      repeat (command_wait_cycles) @(posedge clk);
      uart_send_string("ps\r");
      repeat (command_wait_cycles) @(posedge clk);
      uart_send_string("list_sem\r");
      repeat (command_wait_cycles) @(posedge clk);
      uart_send_string("simple_add\r");
      repeat (command_wait_cycles) @(posedge clk);
      uart_send_string("status\r");
      repeat (command_wait_cycles) @(posedge clk);
      for (int unsigned run = 0; run < requested_coremark_runs; run++) begin
        uart_send_string("coremark\r");
        repeat (command_wait_cycles) @(posedge clk);
        uart_send_string("JYD_SIM\r");
        if ((run + 1) < requested_coremark_runs) begin
          // Use a target-specific bounded interval long enough for the worker
          // and its UART report, then repeat the physical-board status/command
          // sequence without reaching into firmware state.
          repeat (coremark_gap_cycles) @(posedge clk);
          uart_send_string("status\r");
          repeat (command_wait_cycles) @(posedge clk);
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      completion <= '0;
      coremark_led_rises <= 0;
      coremark_led_falls <= 0;
      coremark_led_q <= 1'b0;
      interrupt_traps <= 0;
      interrupt_returns <= 0;
      interrupt_snapshot_valid <= 1'b0;
      coremark_active <= 1'b0;
      uart_tx_previous_was_cr <= 1'b0;
      perf_active_cycles <= '0;
      perf_retired_insts <= '0;
      perf_retire_cycles <= '0;
      perf_dual_retire_cycles <= '0;
      perf_dispatch_insts <= '0;
      perf_fetch_requests <= '0;
      perf_fetch_responses <= '0;
      perf_frontend_empty_cycles <= '0;
      perf_redirects <= '0;
      perf_stale_responses <= '0;
      perf_early_redirects <= '0;
      perf_frontend_resource_stalls <= '0;
      perf_lane1_stalls <= '0;
      perf_head_empty_cycles <= '0;
      perf_head_wait_cycles <= '0;
      perf_head_done_block_cycles <= '0;
      perf_rob_full_cycles <= '0;
      perf_iq0_full_cycles <= '0;
      perf_iq1_full_cycles <= '0;
      perf_issue_both_cycles <= '0;
      perf_head_wait_load <= '0;
      perf_head_wait_store <= '0;
      perf_head_wait_control <= '0;
      perf_head_wait_other <= '0;
      perf_iq1_backpressure <= '0;
      perf_ex1_load_busy <= '0;
      perf_issue0_count <= '0;
      perf_issue1_count <= '0;
      perf_issue1_load <= '0;
      perf_issue1_store <= '0;
      perf_issue1_muldiv <= '0;
      perf_dcache_load_accept <= '0;
      perf_dcache_hit <= '0;
      perf_dcache_miss <= '0;
      perf_branch_resolve <= '0;
      perf_branch_mispredict <= '0;
      perf_mispredict_cond <= '0;
      perf_mispredict_jalr <= '0;
    end else begin
      cycles <= cycles + 1;
      coremark_led_q <= coremark_led;
      if (coremark_led && !coremark_led_q) begin
        coremark_led_rises <= coremark_led_rises + 1;
        // Keep the architectural interrupt checker enabled through the report
        // and shell return as well as the timed loop.  Function PCs move when
        // a firmware target is rebuilt, whereas the LED protocol is stable.
        coremark_active <= 1'b1;
        perf_active_cycles <= '0;
        perf_retired_insts <= '0;
        perf_retire_cycles <= '0;
        perf_dual_retire_cycles <= '0;
        perf_dispatch_insts <= '0;
        perf_fetch_requests <= '0;
        perf_fetch_responses <= '0;
        perf_frontend_empty_cycles <= '0;
        perf_redirects <= '0;
        perf_stale_responses <= '0;
        perf_early_redirects <= '0;
        perf_frontend_resource_stalls <= '0;
        perf_lane1_stalls <= '0;
        perf_head_empty_cycles <= '0;
        perf_head_wait_cycles <= '0;
        perf_head_done_block_cycles <= '0;
        perf_rob_full_cycles <= '0;
        perf_iq0_full_cycles <= '0;
        perf_iq1_full_cycles <= '0;
        perf_issue_both_cycles <= '0;
        perf_head_wait_load <= '0;
        perf_head_wait_store <= '0;
        perf_head_wait_control <= '0;
        perf_head_wait_other <= '0;
        perf_iq1_backpressure <= '0;
        perf_ex1_load_busy <= '0;
        perf_issue0_count <= '0;
        perf_issue1_count <= '0;
        perf_issue1_load <= '0;
        perf_issue1_store <= '0;
        perf_issue1_muldiv <= '0;
        perf_dcache_load_accept <= '0;
        perf_dcache_hit <= '0;
        perf_dcache_miss <= '0;
        perf_branch_resolve <= '0;
        perf_branch_mispredict <= '0;
        perf_mispredict_cond <= '0;
        perf_mispredict_jalr <= '0;
      end else if (coremark_led) begin
        perf_active_cycles <= perf_active_cycles + 64'd1;
        perf_retired_insts <= perf_retired_insts +
                              {63'b0, dut.commit_trace[0].valid} +
                              {63'b0, dut.commit_trace[1].valid};
        if (dut.commit_trace[0].valid || dut.commit_trace[1].valid)
          perf_retire_cycles <= perf_retire_cycles + 64'd1;
        if (dut.commit_trace[0].valid && dut.commit_trace[1].valid)
          perf_dual_retire_cycles <= perf_dual_retire_cycles + 64'd1;
        perf_dispatch_insts <= perf_dispatch_insts +
                               {63'b0, dut.u_core.dispatch_take[0]} +
                               {63'b0, dut.u_core.dispatch_take[1]};
        if (dut.core_imem_req_valid && dut.core_imem_req_ready)
          perf_fetch_requests <= perf_fetch_requests + 64'd1;
        if (dut.core_imem_rsp_valid && dut.core_imem_rsp_ready)
          perf_fetch_responses <= perf_fetch_responses + 64'd1;
        if (!dut.u_core.fetch_buffer_valid_q)
          perf_frontend_empty_cycles <= perf_frontend_empty_cycles + 64'd1;
        if (dut.u_core.redirect_valid)
          perf_redirects <= perf_redirects + 64'd1;
        if (dut.u_core.fetch_response_redirect)
          perf_early_redirects <= perf_early_redirects + 64'd1;
        if (dut.u_core.fetch_buffer_valid_q && !dut.u_core.dispatch_take[0])
          perf_frontend_resource_stalls <= perf_frontend_resource_stalls + 64'd1;
        if (dut.u_core.dispatch_take[0] && dut.u_core.fetch_lane_valid[1] &&
            !dut.u_core.dispatch_take[1])
          perf_lane1_stalls <= perf_lane1_stalls + 64'd1;
        if (!dut.u_core.rob_head_entry[0].valid)
          perf_head_empty_cycles <= perf_head_empty_cycles + 64'd1;
        else if (!dut.u_core.rob_head_entry[0].done) begin
          perf_head_wait_cycles <= perf_head_wait_cycles + 64'd1;
          if (dut.u_core.head_meta[0].is_load)
            perf_head_wait_load <= perf_head_wait_load + 64'd1;
          else if (dut.u_core.head_meta[0].is_store)
            perf_head_wait_store <= perf_head_wait_store + 64'd1;
          else if (dut.u_core.head_meta[0].is_branch ||
                   (dut.u_core.head_meta[0].op inside {UOP_JAL,UOP_JALR}))
            perf_head_wait_control <= perf_head_wait_control + 64'd1;
          else
            perf_head_wait_other <= perf_head_wait_other + 64'd1;
        end
        else if (dut.u_core.retire_count == 0)
          perf_head_done_block_cycles <= perf_head_done_block_cycles + 64'd1;
        if (dut.u_core.rob_count == 32)
          perf_rob_full_cycles <= perf_rob_full_cycles + 64'd1;
        if (dut.u_core.iq0_count == 8)
          perf_iq0_full_cycles <= perf_iq0_full_cycles + 64'd1;
        if (dut.u_core.iq1_count == 8)
          perf_iq1_full_cycles <= perf_iq1_full_cycles + 64'd1;
        if (dut.u_core.iq0_issue_valid && dut.u_core.iq0_issue_ready &&
            dut.u_core.iq1_issue_valid && dut.u_core.iq1_issue_ready)
          perf_issue_both_cycles <= perf_issue_both_cycles + 64'd1;
        if (dut.u_core.iq1_issue_valid && !dut.u_core.iq1_issue_ready)
          perf_iq1_backpressure <= perf_iq1_backpressure + 64'd1;
        if (dut.u_core.ex1_valid_q && dut.u_core.ex1_q.is_load)
          perf_ex1_load_busy <= perf_ex1_load_busy + 64'd1;
        if (dut.u_core.iq0_issue_valid && dut.u_core.iq0_issue_ready)
          perf_issue0_count <= perf_issue0_count + 64'd1;
        if (dut.u_core.iq1_issue_valid && dut.u_core.iq1_issue_ready) begin
          perf_issue1_count <= perf_issue1_count + 64'd1;
          if (dut.u_core.iq1_issue_entry.is_load)
            perf_issue1_load <= perf_issue1_load + 64'd1;
          if (dut.u_core.iq1_issue_entry.is_store)
            perf_issue1_store <= perf_issue1_store + 64'd1;
          if (dut.u_core.iq1_issue_entry.is_muldiv)
            perf_issue1_muldiv <= perf_issue1_muldiv + 64'd1;
        end
        if (dut.dc_core_load_valid && dut.dc_core_load_ready)
          perf_dcache_load_accept <= perf_dcache_load_accept + 64'd1;
        if (dut.u_dcache.lookup_valid_q && dut.u_dcache.lookup_data_ready_q &&
            (dut.u_dcache.lookup_hit0 || dut.u_dcache.lookup_hit1))
          perf_dcache_hit <= perf_dcache_hit + 64'd1;
        if (dut.u_dcache.lookup_valid_q && dut.u_dcache.lookup_data_ready_q &&
            !dut.u_dcache.lookup_hit0 && !dut.u_dcache.lookup_hit1 &&
            !dut.u_dcache.lookup_match_found)
          perf_dcache_miss <= perf_dcache_miss + 64'd1;
        if (dut.u_core.branch_resolve_valid)
          perf_branch_resolve <= perf_branch_resolve + 64'd1;
        if (dut.u_core.branch_mispredict) begin
          perf_branch_mispredict <= perf_branch_mispredict + 64'd1;
          if (dut.u_core.ex0_q.is_branch)
            perf_mispredict_cond <= perf_mispredict_cond + 64'd1;
          if (dut.u_core.ex0_q.op == UOP_JALR)
            perf_mispredict_jalr <= perf_mispredict_jalr + 64'd1;
        end
        if (dut.core_imem_rsp_valid && dut.core_imem_rsp_ready &&
            (dut.core_imem_rsp_epoch != dut.u_core.fetch_epoch_q))
          perf_stale_responses <= perf_stale_responses + 64'd1;
      end
      if (!coremark_led && coremark_led_q) begin
        coremark_led_falls <= coremark_led_falls + 1;
        $display("PERF coremark_run=%0d active_cycles=%0d retired=%0d native_ipc_x1e6=%0d effective_ipc_x1e6=%0d retire_cycles=%0d dual_retire_cycles=%0d dispatch=%0d fetch_req=%0d fetch_rsp=%0d frontend_empty=%0d redirects=%0d stale_rsp=%0d",
                 coremark_led_falls + 1, perf_active_cycles,
                 perf_retired_insts,
                 (perf_retired_insts * 64'd1_000_000) / perf_active_cycles,
                 (COREMARK_BASELINE_WORK * 64'd1_000_000) / perf_active_cycles,
                 perf_retire_cycles, perf_dual_retire_cycles,
                 perf_dispatch_insts, perf_fetch_requests,
                 perf_fetch_responses, perf_frontend_empty_cycles,
                 perf_redirects, perf_stale_responses);
        $display("PERF_DETAIL early_redirect=%0d frontend_resource_stall=%0d lane1_stall=%0d head_empty=%0d head_wait=%0d head_done_block=%0d rob_full=%0d iq0_full=%0d iq1_full=%0d issue_both=%0d",
                 perf_early_redirects, perf_frontend_resource_stalls,
                 perf_lane1_stalls, perf_head_empty_cycles,
                 perf_head_wait_cycles, perf_head_done_block_cycles,
                 perf_rob_full_cycles, perf_iq0_full_cycles,
                 perf_iq1_full_cycles, perf_issue_both_cycles);
        $display("PERF_WAIT head_load=%0d head_store=%0d head_control=%0d head_other=%0d iq1_backpressure=%0d ex1_load_busy=%0d",
                 perf_head_wait_load, perf_head_wait_store,
                 perf_head_wait_control, perf_head_wait_other,
                 perf_iq1_backpressure, perf_ex1_load_busy);
        $display("PERF_EXEC issue0=%0d issue1=%0d issue1_load=%0d issue1_store=%0d issue1_muldiv=%0d dcache_load=%0d dcache_hit=%0d dcache_miss=%0d branch_resolve=%0d branch_mispredict=%0d",
                 perf_issue0_count, perf_issue1_count, perf_issue1_load,
                 perf_issue1_store, perf_issue1_muldiv,
                 perf_dcache_load_accept, perf_dcache_hit, perf_dcache_miss,
                 perf_branch_resolve, perf_branch_mispredict);
        $display("PERF_BRANCH cond_mispredict=%0d jalr_mispredict=%0d",
                 perf_mispredict_cond, perf_mispredict_jalr);
      end
      if (dut.u_core.take_interrupt)
        interrupt_traps <= interrupt_traps + 1;
      if (dut.u_core.commit_mret)
        interrupt_returns <= interrupt_returns + 1;
      if (dut.u_core.take_interrupt && coremark_active) begin
        if (dut.u_core.fetch_buffer_valid_q) begin
          assert (dut.u_core.next_committed_pc_q ==
                  dut.u_core.fetch_buffer_pc_q)
            else $fatal(1,
              "interrupt PC skipped fetch buffer mepc=%08x frontend=%08x",
              dut.u_core.next_committed_pc_q,
              dut.u_core.fetch_buffer_pc_q);
        end
        assert (!interrupt_snapshot_valid)
          else $fatal(1, "nested CoreMark interrupt snapshot");
        interrupt_snapshot_valid <= 1'b1;
        for (int unsigned arch_reg = 0; arch_reg < 32; arch_reg++) begin
          interrupt_snapshot[arch_reg] <= committed_register_value(arch_reg);
          interrupt_snapshot_map[arch_reg] <=
            dut.u_core.u_rename_map.rrat_q[arch_reg];
        end
      end
      if (dut.u_core.commit_mret && interrupt_snapshot_valid) begin
        for (int unsigned arch_reg = 1; arch_reg < 32; arch_reg++) begin
          assert (committed_register_value(arch_reg) ==
                  interrupt_snapshot[arch_reg])
            else $fatal(1,
              "interrupt restore mismatch x%0d before=%08x(p%0d) after=%08x(p%0d) mepc=%08x",
              arch_reg, interrupt_snapshot[arch_reg],
              interrupt_snapshot_map[arch_reg],
              committed_register_value(arch_reg),
              dut.u_core.u_rename_map.rrat_q[arch_reg],
              dut.u_core.csr_mret_pc);
        end
        interrupt_snapshot_valid <= 1'b0;
      end

      // An IQ readiness bit must never outlive the current PRF generation.
      // Otherwise a recycled physical register can issue with its old value
      // before the new producer writes it.
      if (coremark_active && dut.u_core.iq0_issue_valid &&
          !dut.u_core.iq0_issue_recovery_kill) begin
        if (dut.u_core.iq0_issue_entry.uses_ps1)
          assert (issue_operand_available(dut.u_core.iq0_issue_entry.ps1))
            else $fatal(1,
              "IQ0 issued stale ps1 pc=%08x ps=%0d data=%08x",
              dut.u_core.iq0_issue_entry.pc,
              dut.u_core.iq0_issue_entry.ps1, dut.u_core.prf_read_data[0]);
        if (dut.u_core.iq0_issue_entry.uses_ps2)
          assert (issue_operand_available(dut.u_core.iq0_issue_entry.ps2))
            else $fatal(1,
              "IQ0 issued stale ps2 pc=%08x ps=%0d data=%08x",
              dut.u_core.iq0_issue_entry.pc,
              dut.u_core.iq0_issue_entry.ps2, dut.u_core.prf_read_data[1]);
      end
      if (coremark_active && dut.u_core.iq1_issue_valid &&
          !dut.u_core.iq1_issue_recovery_kill) begin
        if (dut.u_core.iq1_issue_entry.uses_ps1)
          assert (issue_operand_available(dut.u_core.iq1_issue_entry.ps1))
            else $fatal(1,
              "IQ1 issued stale ps1 pc=%08x ps=%0d prf=%08x issue=%08x wake=%b/%0d,%0d,%0d,%0d,%0d wb0=%b/%0d/%08x wb1=%b/%0d/%08x ex=%08x/%08x",
              dut.u_core.iq1_issue_entry.pc,
              dut.u_core.iq1_issue_entry.ps1, dut.u_core.prf_read_data[2],
              dut.u_core.issue_read_data[2], dut.u_core.wakeup_valid_iq1,
              dut.u_core.wakeup_preg_iq1[0], dut.u_core.wakeup_preg_iq1[1],
              dut.u_core.wakeup_preg_iq1[2], dut.u_core.wakeup_preg_iq1[3],
              dut.u_core.wakeup_preg_iq1[4], dut.u_core.wb0_valid,
              dut.u_core.wb0_pdst, dut.u_core.wb0_result,
              dut.u_core.wb1_valid, dut.u_core.wb1_pdst,
              dut.u_core.wb1_result, dut.u_core.ex0_q.pc,
              dut.u_core.ex1_q.pc);
        if (dut.u_core.iq1_issue_entry.uses_ps2)
          assert (issue_operand_available(dut.u_core.iq1_issue_entry.ps2))
            else $fatal(1,
              "IQ1 issued stale ps2 pc=%08x ps=%0d data=%08x",
              dut.u_core.iq1_issue_entry.pc,
              dut.u_core.iq1_issue_entry.ps2, dut.u_core.prf_read_data[3]);
      end

      // Testbench-only architectural shadow for all writes accepted by the
      // D-cache.  A load snapshots the bytes that are already cache-owned;
      // its eventual response must return that same value even if the miss
      // engine and later requests run in between.  Bytes never written since
      // reset are covered because both shadows are initialized from the same
      // firmware image as the backing BRAM.
      if (dut.dc_core_store_valid && dut.dc_core_store_ready) begin
        for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (dut.store_stage_wstrb_q[byte_idx]) begin
            shadow_data[{dut.store_stage_addr_q[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx]
              <= dut.store_stage_wdata_q[byte_idx*8 +: 8];
            shadow_valid[{dut.store_stage_addr_q[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx]
              <= 1'b1;
          end
        end
      end
      if (dut.dc_core_load_valid && dut.dc_core_load_ready) begin
        assert (!load_expected_valid[dut.fabric_dmem_req_uop_id])
          else $fatal(1, "D-cache reused live response id=%02x",
                      dut.fabric_dmem_req_uop_id);
        load_expected_valid[dut.fabric_dmem_req_uop_id] <= 1'b1;
        load_expected_addr[dut.fabric_dmem_req_uop_id] <=
          dut.fabric_dmem_req_addr;
        for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (dut.dc_core_store_valid && dut.dc_core_store_ready &&
              (dut.store_stage_addr_q[RAM_ADDR_BITS-1:2] ==
               dut.fabric_dmem_req_addr[RAM_ADDR_BITS-1:2]) &&
              dut.store_stage_wstrb_q[byte_idx]) begin
            load_expected_data[dut.fabric_dmem_req_uop_id][byte_idx*8 +: 8]
              <= dut.store_stage_wdata_q[byte_idx*8 +: 8];
            load_expected_mask[dut.fabric_dmem_req_uop_id][byte_idx] <= 1'b1;
          end else begin
            load_expected_data[dut.fabric_dmem_req_uop_id][byte_idx*8 +: 8]
              <= shadow_data[
                {dut.fabric_dmem_req_addr[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx];
            load_expected_mask[dut.fabric_dmem_req_uop_id][byte_idx]
              <= shadow_valid[
                {dut.fabric_dmem_req_addr[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx];
          end
        end
      end
      if (dut.dc_core_rsp_valid) begin
        assert (load_expected_valid[dut.dc_core_rsp_uop_id])
          else $fatal(1, "D-cache response without request id=%02x seq=%x",
                      dut.dc_core_rsp_uop_id, dut.dc_core_rsp_seq);
        for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (load_expected_mask[dut.dc_core_rsp_uop_id][byte_idx]) begin
            assert (dut.dc_core_rsp_data[byte_idx*8 +: 8] ==
                    load_expected_data[dut.dc_core_rsp_uop_id][byte_idx*8 +: 8])
              else $fatal(1,
                "D-cache stale load addr=%08x id=%02x byte=%0d expected=%02x actual=%02x commit_pc=%08x",
                load_expected_addr[dut.dc_core_rsp_uop_id],
                dut.dc_core_rsp_uop_id, byte_idx,
                load_expected_data[dut.dc_core_rsp_uop_id][byte_idx*8 +: 8],
                dut.dc_core_rsp_data[byte_idx*8 +: 8],
                dut.u_core.next_committed_pc_q);
          end
        end
        load_expected_valid[dut.dc_core_rsp_uop_id] <= 1'b0;
      end
      // Completion is a committed SQ drain. Observe it before the write-back
      // cache so the harness does not depend on when a dirty line is evicted.
      if (dut.core_dmem_req_valid && dut.core_dmem_req_ready &&
          dut.core_dmem_req_write &&
          (dut.core_dmem_req_addr == (RAM_BYTES - 16))) begin
        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (dut.core_dmem_req_wstrb[byte_idx])
            completion[byte_idx*8 +: 8] <=
              dut.core_dmem_req_wdata[byte_idx*8 +: 8];
        end
      end
      for (int lane = 0; lane < 2; lane++) begin
        if (dut.commit_trace[lane].valid && dut.commit_trace[lane].mem_wen &&
            (dut.commit_trace[lane].mem_addr < RAM_BYTES)) begin
          for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
            if (dut.commit_trace[lane].mem_mask[byte_idx]) begin
              commit_shadow_data[
                {dut.commit_trace[lane].mem_addr[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx]
                <= dut.commit_trace[lane].mem_data[byte_idx*8 +: 8];
              commit_shadow_valid[
                {dut.commit_trace[lane].mem_addr[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx]
                <= 1'b1;
            end
          end
        end
        if (dut.commit_trace[lane].valid &&
            dut.u_core.head_meta[lane].is_load) begin
          logic [31:0] load_addr;
          logic [31:0] raw_word;
          logic [31:0] expected_value;
          logic [3:0] compare_mask;
          logic [1:0] load_size;
          logic load_unsigned;
          load_addr = dut.u_core.u_lq.addr_q[
            dut.u_core.head_meta[lane].lq_seq[2:0]];
          load_size = dut.u_core.u_lq.size_q[
            dut.u_core.head_meta[lane].lq_seq[2:0]];
          load_unsigned = dut.u_core.u_lq.mem_unsigned_q[
            dut.u_core.head_meta[lane].lq_seq[2:0]];
          raw_word = '0;
          compare_mask = '0;
          for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
            raw_word[byte_idx*8 +: 8] = commit_shadow_data[
              {load_addr[RAM_ADDR_BITS-1:2], 2'b00} + byte_idx];
          end
          unique case (load_size)
            2'd0: begin
              compare_mask = 4'b0001 << load_addr[1:0];
              expected_value = load_unsigned
                ? {24'b0, raw_word[load_addr[1:0]*8 +: 8]}
                : {{24{raw_word[load_addr[1:0]*8 + 7]}},
                   raw_word[load_addr[1:0]*8 +: 8]};
            end
            2'd1: begin
              compare_mask = load_addr[1] ? 4'b1100 : 4'b0011;
              expected_value = load_unsigned
                ? {16'b0, (load_addr[1] ? raw_word[31:16] : raw_word[15:0])}
                : {{16{load_addr[1] ? raw_word[31] : raw_word[15]}},
                   (load_addr[1] ? raw_word[31:16] : raw_word[15:0])};
            end
            default: begin
              compare_mask = 4'b1111;
              expected_value = raw_word;
            end
          endcase
          if ((load_addr < RAM_BYTES) &&
              ((compare_mask & {
                commit_shadow_valid[{load_addr[RAM_ADDR_BITS-1:2], 2'b00} + 3],
                commit_shadow_valid[{load_addr[RAM_ADDR_BITS-1:2], 2'b00} + 2],
                commit_shadow_valid[{load_addr[RAM_ADDR_BITS-1:2], 2'b00} + 1],
                commit_shadow_valid[{load_addr[RAM_ADDR_BITS-1:2], 2'b00} + 0]}) ==
               compare_mask)) begin
            assert (dut.commit_trace[lane].rd_data == expected_value)
              else $fatal(1,
                "committed load mismatch pc=%08x addr=%08x size=%0d expected=%08x actual=%08x sp=%08x",
                dut.commit_trace[lane].pc, load_addr, load_size,
                expected_value, dut.commit_trace[lane].rd_data,
                committed_register_value(2));
          end
        end
        if (trace_commits && dut.commit_trace[lane].valid) begin
          $display("COMMIT lane=%0d pc=%08x inst=%08x rd=%0d data=%08x mem=%0b/%08x/%08x/%x",
                   lane, dut.commit_trace[lane].pc, dut.commit_trace[lane].inst,
                   dut.commit_trace[lane].rd_addr, dut.commit_trace[lane].rd_data,
                   dut.commit_trace[lane].mem_wen, dut.commit_trace[lane].mem_addr,
                   dut.commit_trace[lane].mem_data, dut.commit_trace[lane].mem_mask);
        end
        if (trace_irq && coremark_led && dut.commit_trace[lane].valid &&
            (dut.commit_trace[lane].pc >= 32'h0000_0168) &&
            (dut.commit_trace[lane].pc <= 32'h0000_01f4)) begin
          $display("IRQ_COMMIT lane=%0d pc=%08x inst=%08x rd=%0d data=%08x pdst=%0d",
                   lane, dut.commit_trace[lane].pc,
                   dut.commit_trace[lane].inst,
                   dut.commit_trace[lane].rd_addr,
                   dut.commit_trace[lane].rd_data,
                   dut.u_core.rob_head_entry[lane].pdst);
        end
      end
      if (trace_mem) begin
        if (dut.core_dmem_req_valid && dut.core_dmem_req_ready)
          $display("CORE_DMEM write=%0b addr=%08x data=%08x mask=%x seq=%x id=%02x",
                   dut.core_dmem_req_write, dut.core_dmem_req_addr,
                   dut.core_dmem_req_wdata, dut.core_dmem_req_wstrb,
                   dut.core_dmem_req_seq, dut.core_dmem_req_uop_id);
        if (dut.fabric_dmem_req_valid && dut.fabric_dmem_req_ready)
          $display("FABRIC_DMEM write=%0b addr=%08x data=%08x mask=%x seq=%x id=%02x",
                   dut.fabric_dmem_req_write, dut.fabric_dmem_req_addr,
                   dut.fabric_dmem_req_wdata, dut.fabric_dmem_req_wstrb,
                   dut.fabric_dmem_req_seq, dut.fabric_dmem_req_uop_id);
        if (dut.core_dmem_rsp_valid)
          $display("CORE_DRSP data=%08x error=%0b seq=%x id=%02x",
                   dut.core_dmem_rsp_data, dut.core_dmem_rsp_error,
                   dut.core_dmem_rsp_seq, dut.core_dmem_rsp_uop_id);
        if (dut.dc_mem_req_valid && dut.dc_mem_req_ready)
          $display("DC_MEM write=%0b addr=%08x data=%016x mask=%02x",
                   dut.dc_mem_req_write, dut.dc_mem_req_addr,
                   dut.dc_mem_req_wdata, dut.dc_mem_req_wstrb);
        if (dut.dc_mem_rsp_valid_q)
          $display("DC_MRSP data=%016x error=%0b", dut.dc_mem_rsp_data,
                   dut.dc_mem_rsp_error_q);
        if (dut.u_dcache.engine_active_q &&
            (dut.u_dcache.engine_state_q == 4'd6))
          $display("DC_INSTALL line=%08x beat=%0d raw=%016x merged=%016x mask=%08x",
                   dut.u_dcache.mshr_line_addr_q[dut.u_dcache.engine_mshr_q],
                   dut.u_dcache.engine_beat_q,
                   dut.u_dcache.mshr_line_data_q[dut.u_dcache.engine_mshr_q]
                                                     [dut.u_dcache.engine_beat_q],
                   dut.u_dcache.install_merged_data,
                   dut.u_dcache.mshr_store_mask_q[dut.u_dcache.engine_mshr_q]);
        if (dut.u_dcache.response_mshr_found)
          $display("DC_RESPONSE mshr=%0d line=%08x waiter=%0b/%0d addr=%08x word=%016x",
                   dut.u_dcache.response_mshr_idx,
                   dut.u_dcache.mshr_line_addr_q[dut.u_dcache.response_mshr_idx],
                   dut.u_dcache.response_waiter_found,
                   dut.u_dcache.response_waiter_idx,
                   dut.u_dcache.mshr_waiter_q[dut.u_dcache.response_mshr_idx]
                                                  [dut.u_dcache.response_waiter_idx].addr,
                   dut.u_dcache.response_line_word);
      end
      if (trace_pipe && cycles < 2000) begin
        if (dut.ic_mem_req_valid && dut.ic_mem_req_ready)
          $display("ICREQ addr=%08x refill_word=%0d state=%0d",
                   dut.ic_mem_req_addr, dut.u_icache.refill_word_q,
                   dut.u_icache.state_q);
        if (dut.ic_mem_rsp_valid_q)
          $display("ICRSP data=%016x refill_word=%0d state=%0d",
                   dut.ic_mem_rsp_data, dut.u_icache.refill_word_q,
                   dut.u_icache.state_q);
        if (dut.core_imem_rsp_valid)
          $display("COREIRSP pc=%08x epoch=%0h data=%016x error=%0b ready=%0b",
                   dut.core_imem_rsp_addr, dut.core_imem_rsp_epoch,
                   dut.core_imem_rsp_data, dut.core_imem_rsp_error,
                   dut.core_imem_rsp_ready);
        for (int lane = 0; lane < 2; lane++) begin
          if (dut.u_core.dispatch_take[lane])
            $display("DISP lane=%0d pc=%08x inst=%08x ps1=%0d ps2=%0d r1=%0b r2=%0b iq1=%0b",
                     lane, dut.u_core.lane_issue_entry[lane].pc,
                     dut.u_core.lane_issue_entry[lane].inst,
                     dut.u_core.lane_issue_entry[lane].ps1,
                     dut.u_core.lane_issue_entry[lane].ps2,
                     dut.u_core.source1_ready_lane[lane],
                     dut.u_core.source2_ready_lane[lane], dut.u_core.route_lane[lane]);
        end
        if (dut.u_core.iq0_issue_valid)
          $display("ISS0 ready=%0b pc=%08x live_ex=%0b recovery=%0b",
                   dut.u_core.iq0_issue_ready, dut.u_core.iq0_issue_entry.pc,
                   dut.u_core.ex0_live, dut.u_core.rob_recovery_valid);
        if (dut.u_core.ex0_valid_q)
          $display("EX0 pc=%08x live=%0b wb=%0b mis=%0b",
                   dut.u_core.ex0_q.pc, dut.u_core.ex0_live,
                   dut.u_core.wb0_valid, dut.u_core.branch_mispredict);
      end
      if (trace_commits) begin
        if (dut.u_core.commit_exception)
          $display("COMMIT_EXCEPTION cycle=%0d pc=%08x inst=%08x cause=%08x tval=%08x rob=%0d",
                   cycles, dut.u_core.rob_head_entry[0].pc,
                   dut.u_core.rob_head_entry[0].inst,
                   dut.u_core.rob_head_entry[0].cause,
                   dut.u_core.rob_head_entry[0].tval,
                   dut.u_core.rob_head_entry[0].rob_ptr);
        if (dut.u_core.wb1_valid && dut.u_core.wb1_exception)
          $display("WB1_EXCEPTION cycle=%0d id=%02x cause=%08x tval=%08x ex1_pc=%08x",
                   cycles, dut.u_core.wb1_id, dut.u_core.wb1_cause,
                   dut.u_core.wb1_tval, dut.u_core.ex1_q.pc);
        if (dut.u_core.branch_mispredict)
          $display("RECOVERY cycle=%0d ex_pc=%08x actual=%08x predicted=%08x rob_head=%0d recovery_tail=%0d cp=%0b/%0d",
                   cycles, dut.u_core.ex0_q.pc,
                   dut.u_core.branch_actual_next,
                   dut.u_core.ex0_q.predicted_pc,
                   dut.u_core.rob_head, dut.u_core.branch_recovery_tail,
                   dut.u_core.branch_has_checkpoint,
                   dut.u_core.branch_checkpoint_id);
        for (int lane = 0; lane < 2; lane++) begin
          if (dut.u_core.dispatch_take[lane])
            $display("DISPATCH cycle=%0d lane=%0d pc=%08x inst=%08x rob=%0d ps1=p%0d ps2=p%0d pdst=p%0d",
                     cycles, lane, dut.u_core.lane_issue_entry[lane].pc,
                     dut.u_core.lane_issue_entry[lane].inst,
                     dut.u_core.lane_issue_entry[lane].rob_ptr,
                     dut.u_core.lane_issue_entry[lane].ps1,
                     dut.u_core.lane_issue_entry[lane].ps2,
                     dut.u_core.lane_issue_entry[lane].pdst);
        end
        if (dut.u_core.iq0_issue_valid)
          $display("ISSUE0 cycle=%0d pc=%08x rob=%0d ps1=p%0d/%08x>%08x ps2=p%0d/%08x>%08x",
                   cycles, dut.u_core.iq0_issue_entry.pc,
                   dut.u_core.iq0_issue_entry.rob_ptr,
                   dut.u_core.iq0_issue_entry.ps1, dut.u_core.prf_read_data[0],
                   dut.u_core.issue_read_data[0],
                   dut.u_core.iq0_issue_entry.ps2, dut.u_core.prf_read_data[1],
                   dut.u_core.issue_read_data[1]);
        if (dut.u_core.iq1_issue_valid)
          $display("ISSUE1 cycle=%0d pc=%08x rob=%0d ps1=p%0d/%08x>%08x ps2=p%0d/%08x>%08x",
                   cycles, dut.u_core.iq1_issue_entry.pc,
                   dut.u_core.iq1_issue_entry.rob_ptr,
                   dut.u_core.iq1_issue_entry.ps1, dut.u_core.prf_read_data[2],
                   dut.u_core.issue_read_data[2],
                   dut.u_core.iq1_issue_entry.ps2, dut.u_core.prf_read_data[3],
                   dut.u_core.issue_read_data[3]);
      end
      if (dut.core_dmem_req_valid && dut.core_dmem_req_ready &&
          dut.core_dmem_req_write && dut.core_dmem_req_addr == 32'h1000_0000) begin
        if (dut.core_dmem_req_wdata[7:0] == 8'h0a) begin
          assert (uart_tx_previous_was_cr)
            else $fatal(1, "UART emitted LF without preceding CR");
        end
        uart_tx_previous_was_cr <= (dut.core_dmem_req_wdata[7:0] == 8'h0d);
        $write("%c", dut.core_dmem_req_wdata[7:0]);
      end
      if (completion == 32'h600d_0000) begin
        if (expect_coremark_led) begin
          assert (!coremark_led &&
                  (coremark_led_rises >= requested_coremark_runs) &&
                  (coremark_led_falls >= requested_coremark_runs))
            else $fatal(1, "CoreMark LED protocol failed led=%0b rises=%0d falls=%0d",
                        coremark_led, coremark_led_rises, coremark_led_falls);
        end else begin
          assert (!coremark_led && (coremark_led_rises == 0) &&
                  (coremark_led_falls == 0))
            else $fatal(1, "non-CoreMark firmware changed LED led=%0b rises=%0d falls=%0d",
                        coremark_led, coremark_led_rises, coremark_led_falls);
        end
        $display("PASS tb_soc_firmware cycles=%0d led_rises=%0d led_falls=%0d traps=%0d mret=%0d",
                 cycles, coremark_led_rises, coremark_led_falls,
                 interrupt_traps, interrupt_returns);
        $finish;
      end
      if (completion[31:16] == 16'hdead) begin
        $fatal(1,
          "firmware trapped cause=%0d pc=%08x rob=%0d arch_ra=%08x arch_sp=%08x",
          completion[15:0], debug_pc, debug_rob_count,
          committed_register_value(1), committed_register_value(2));
      end
      if (completion[31:16] == 16'h600d && completion != 32'h600d_0000) begin
        $fatal(1, "firmware returned status=%0d", completion[15:0]);
      end
      if (cycles > max_cycles) begin
        $display("HEAD pc=%08x inst=%08x valid=%0b done=%0b iq0=%0d iq1=%0d lq=%0d sq=%0d dmem=%0b/%0b/%0b addr=%08x",
                 dut.u_core.rob_head_entry[0].pc, dut.u_core.rob_head_entry[0].inst,
                 dut.u_core.rob_head_entry[0].valid, dut.u_core.rob_head_entry[0].done,
                 dut.u_core.iq0_count, dut.u_core.iq1_count,
                 dut.u_core.lq_count, dut.u_core.sq_count,
                 dut.core_dmem_req_valid, dut.core_dmem_req_ready,
                 dut.core_dmem_req_write, dut.core_dmem_req_addr);
        $display("FETCH pc=%08x inflight=%0d queue=%0d buffer=%0b serial=%0b redirect=%0b req=%0b/%0b rsp=%0b/%0b epoch=%0h rsp_epoch=%0h ic_state=%0d",
                 dut.u_core.fetch_pc_q, dut.u_core.fetch_inflight_count_q,
                 dut.u_core.fetch_queue_count,
                 dut.u_core.fetch_buffer_valid_q,
                 dut.u_core.serializing_inflight_q, dut.u_core.redirect_valid,
                 dut.core_imem_req_valid, dut.core_imem_req_ready,
                 dut.core_imem_rsp_valid, dut.core_imem_rsp_ready,
                 dut.u_core.fetch_epoch_q, dut.core_imem_rsp_epoch,
                 dut.u_icache.state_q);
        $display("INTERRUPTS traps=%0d mret=%0d pending=%0b timer_count=%08x",
                 interrupt_traps, interrupt_returns, timer_irq, timer_count);
        $display("EX1 valid=%0b live=%0b pc=%08x op=%0d load=%0b store=%0b lq_seq=%x sq_query=%0b/%0b immediate=%0b selected=%0b lq_req=%0b/%0b lq_wb=%0b/%0b",
                 dut.u_core.ex1_valid_q, dut.u_core.ex1_live,
                 dut.u_core.ex1_q.pc, dut.u_core.ex1_q.op,
                 dut.u_core.ex1_q.is_load, dut.u_core.ex1_q.is_store,
                 dut.u_core.ex1_q.lq_seq, dut.u_core.sq_query_valid,
                 dut.u_core.sq_query_ready,
                 dut.u_core.ex1_immediate_completion,
                 dut.u_core.ex1_completion_selected,
                 dut.u_core.lq_request_valid, dut.u_core.lq_request_ready,
                 dut.u_core.lq_wb_valid, dut.u_core.lq_wb_ready);
        for (int unsigned iq_idx = 0; iq_idx < 4; iq_idx++) begin
          if (dut.u_core.u_iq1.valid_bank0_q[iq_idx]) begin
            $display("IQ1 bank=0 idx=%0d rob=%0d ps1=%0d/%0b ps2=%0d/%0b load=%0b lq_seq=%x",
                     iq_idx, dut.u_core.u_iq1.rob_ptr_bank0_q[iq_idx],
                     dut.u_core.u_iq1.ps1_bank0_q[iq_idx],
                     dut.u_core.u_iq1.src1_ready_bank0_q[iq_idx],
                     dut.u_core.u_iq1.ps2_bank0_q[iq_idx],
                     dut.u_core.u_iq1.src2_ready_bank0_q[iq_idx],
                     dut.u_core.u_iq1.is_load_bank0_q[iq_idx],
                     dut.u_core.u_iq1.lq_seq_bank0_q[iq_idx]);
          end
          if (dut.u_core.u_iq1.valid_bank1_q[iq_idx]) begin
            $display("IQ1 bank=1 idx=%0d rob=%0d ps1=%0d/%0b ps2=%0d/%0b load=%0b lq_seq=%x",
                     iq_idx, dut.u_core.u_iq1.rob_ptr_bank1_q[iq_idx],
                     dut.u_core.u_iq1.ps1_bank1_q[iq_idx],
                     dut.u_core.u_iq1.src1_ready_bank1_q[iq_idx],
                     dut.u_core.u_iq1.ps2_bank1_q[iq_idx],
                     dut.u_core.u_iq1.src2_ready_bank1_q[iq_idx],
                     dut.u_core.u_iq1.is_load_bank1_q[iq_idx],
                     dut.u_core.u_iq1.lq_seq_bank1_q[iq_idx]);
          end
        end
        for (int unsigned lq_idx = 0; lq_idx < 8; lq_idx++) begin
          if (dut.u_core.u_lq.valid_q[lq_idx])
            $display("LQ idx=%0d seq=%x id=%02x addr_ready=%0b issued=%0b rsp=%0b done=%0b older_pending=%02x addr=%08x",
                     lq_idx, dut.u_core.u_lq.seq_q[lq_idx],
                     dut.u_core.u_lq.uop_id_q[lq_idx],
                     dut.u_core.u_lq.addr_ready_q[lq_idx],
                     dut.u_core.u_lq.issued_q[lq_idx],
                     dut.u_core.u_lq.response_ready_q[lq_idx],
                     dut.u_core.u_lq.done_q[lq_idx],
                     dut.u_core.u_lq.older_addr_pending_q[lq_idx],
                     dut.u_core.u_lq.addr_q[lq_idx]);
        end
        $fatal(1, "firmware timeout pc=%08x rob=%0d completion=%08x",
               debug_pc, debug_rob_count, completion);
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    cycles = 0;
    max_cycles = 20_000_000;
    trace_commits = $test$plusargs("TRACE_COMMIT");
    trace_irq = $test$plusargs("TRACE_IRQ");
    trace_pipe = $test$plusargs("TRACE_PIPE");
    trace_mem = $test$plusargs("TRACE_MEM");
    expect_coremark_led = $test$plusargs("EXPECT_COREMARK_LED");
    for (int unsigned byte_addr = 0; byte_addr < RAM_BYTES; byte_addr++) begin
      shadow_data[byte_addr] = '0;
      shadow_valid[byte_addr] = 1'b0;
      commit_shadow_data[byte_addr] = '0;
      commit_shadow_valid[byte_addr] = 1'b0;
    end
    for (int unsigned id = 0; id < 256; id++) begin
      load_expected_data[id] = '0;
      load_expected_mask[id] = '0;
      load_expected_addr[id] = '0;
      load_expected_valid[id] = 1'b0;
    end
    if (!$value$plusargs("MEM_FILE=%s", mem_file)) begin
      $fatal(1, "MEM_FILE plusarg is required");
    end
    $readmemh(mem_file, dut.u_memory.mem);
    // Seed both memory shadows from the same firmware image as the BRAM.  This
    // extends the response/retirement checks to immutable lookup tables and
    // initialized data instead of checking only bytes written after reset.
    for (int unsigned word_idx = 0; word_idx < RAM_BYTES/8; word_idx++) begin
      for (int unsigned byte_idx = 0; byte_idx < 8; byte_idx++) begin
        shadow_data[word_idx*8 + byte_idx] =
          dut.u_memory.mem[word_idx][byte_idx*8 +: 8];
        shadow_valid[word_idx*8 + byte_idx] = 1'b1;
        commit_shadow_data[word_idx*8 + byte_idx] =
          dut.u_memory.mem[word_idx][byte_idx*8 +: 8];
        commit_shadow_valid[word_idx*8 + byte_idx] = 1'b1;
      end
    end
    void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
  end
endmodule
