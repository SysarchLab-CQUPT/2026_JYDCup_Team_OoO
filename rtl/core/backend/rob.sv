`timescale 1ns/1ps
module rob (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [1:0]                   alloc_valid_i,
  input  logic [31:0]                  alloc_pc_i [2],
  input  logic [31:0]                  alloc_inst_i [2],
  input  logic [1:0]                   alloc_rd_wen_i,
  input  logic [4:0]                   alloc_rd_addr_i [2],
  input  core_types_pkg::preg_t        alloc_pdst_i [2],
  input  core_types_pkg::preg_t        alloc_stale_pdst_i [2],
  output logic [1:0]                   alloc_accept_o,
  output core_types_pkg::rob_ptr_t     alloc_rob_ptr_o [2],
  output core_types_pkg::uop_id_t      alloc_uop_id_o [2],

  input  logic [1:0]                   complete_valid_i,
  input  core_types_pkg::uop_id_t      complete_uop_id_i [2],
  input  logic [31:0]                  complete_result_i [2],
  input  logic [1:0]                   complete_exception_i,
  input  logic [31:0]                  complete_cause_i [2],
  input  logic [31:0]                  complete_tval_i [2],

  input  logic [1:0]                   retire_count_i,
  input  logic                         recovery_valid_i,
  input  core_types_pkg::rob_ptr_t     recovery_tail_i,

  output core_types_pkg::rob_entry_t   head_entry_o [2],
  output core_types_pkg::rob_ptr_t     head_ptr_o,
  output core_types_pkg::rob_ptr_t     tail_ptr_o,
  output logic [5:0]                   count_o
);
  import soc_cfg_pkg::*;
  import core_types_pkg::*;

  localparam int unsigned BANK_ENTRIES = ROB_ENTRIES / 2;
  localparam int unsigned BANK_ADDR_W = ROB_INDEX_W - 1;
  localparam logic [5:0] ROB_COUNT_MAX = 6'd32;
  localparam logic [5:0] ROB_DUAL_ALLOC_LIMIT = 6'd30;

  // Fields written once at allocation are kept in two parity banks.  Since two
  // accepted allocations and the two retirement heads are consecutive, each
  // bank has exactly one write and one read address per cycle.  This is the
  // natural FPGA memory shape; the old 32-entry wide asynchronous array built
  // two 32:1 mux trees for every payload bit.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] inst;
    logic        rd_wen;
    logic [4:0]  rd_addr;
    preg_t       pdst;
    preg_t       stale_pdst;
  } rob_alloc_payload_t;
  localparam int unsigned ALLOC_PAYLOAD_W = $bits(rob_alloc_payload_t);

  // Completion data has two independent write ports, so it remains a small
  // register bank, but parity banking halves each retirement read tree.
  typedef struct packed {
    logic [31:0] result;
    logic        exception;
    logic [31:0] cause;
    logic [31:0] tval;
  } rob_complete_payload_t;
  localparam int unsigned COMPLETE_PAYLOAD_W = $bits(rob_complete_payload_t);

  (* ram_style = "distributed" *)
  logic [ALLOC_PAYLOAD_W-1:0] alloc_even_q [BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [ALLOC_PAYLOAD_W-1:0] alloc_odd_q [BANK_ENTRIES];
  // Each completion port owns one physical LUTRAM copy.  A narrow source bit
  // records which copy contains the entry's single architectural completion.
  // This preserves two arbitrary writes per cycle without building two wide
  // 16:1 flip-flop mux trees at retirement.
  (* ram_style = "distributed" *)
  logic [COMPLETE_PAYLOAD_W-1:0] complete0_even_q [BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [COMPLETE_PAYLOAD_W-1:0] complete0_odd_q [BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [COMPLETE_PAYLOAD_W-1:0] complete1_even_q [BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [COMPLETE_PAYLOAD_W-1:0] complete1_odd_q [BANK_ENTRIES];
  logic complete_done_q [ROB_ENTRIES];
  logic complete_source_q [ROB_ENTRIES];

  logic valid_q [ROB_ENTRIES];
  rob_ptr_t rob_ptr_q [ROB_ENTRIES];
  logic [UOP_GEN_W-1:0] slot_gen_q [ROB_ENTRIES];
  rob_ptr_t head_q, tail_q;
  logic [5:0] count_q;

  rob_ptr_t head_after_retire, tail_after_alloc;
  logic [5:0] count_after_retire, recovery_count;
  logic [1:0] alloc_count, retire_count_safe;

  rob_alloc_payload_t alloc_payload [2];
  logic [ROB_INDEX_W-1:0] alloc_index [2];
  logic alloc_even_we, alloc_odd_we;
  logic [BANK_ADDR_W-1:0] alloc_even_addr, alloc_odd_addr;
  rob_alloc_payload_t alloc_even_data, alloc_odd_data;
  logic alloc_even_pending_q, alloc_odd_pending_q;
  logic [BANK_ADDR_W-1:0] alloc_even_pending_addr_q;
  logic [BANK_ADDR_W-1:0] alloc_odd_pending_addr_q;
  rob_alloc_payload_t alloc_even_pending_data_q, alloc_odd_pending_data_q;

  logic [ROB_INDEX_W-1:0] head_slot;
  logic [BANK_ADDR_W-1:0] head_even_addr, head_odd_addr;
  rob_alloc_payload_t head_alloc_even, head_alloc_odd;
  rob_complete_payload_t head_complete0_even, head_complete0_odd;
  rob_complete_payload_t head_complete1_even, head_complete1_odd;
  rob_alloc_payload_t head_alloc [2];
  rob_complete_payload_t head_complete [2];
  logic [ROB_INDEX_W-1:0] head_index [2];

  logic [1:0] complete_match;
  logic [ROB_INDEX_W-1:0] complete_index [2];
  rob_complete_payload_t complete_payload [2];

  always_comb begin
    retire_count_safe = retire_count_i;
    if ({4'b0, retire_count_safe} > count_q)
      retire_count_safe = count_q[1:0];
    if (retire_count_safe > 2)
      retire_count_safe = 2;
    count_after_retire = count_q - {4'b0, retire_count_safe};
    head_after_retire = rob_ptr_add(head_q, retire_count_safe);

    alloc_accept_o = '0;
    if (!recovery_valid_i) begin
      // Do not reuse entries retired in this cycle.  Registered occupancy is
      // the admission boundary; freed slots become allocatable next cycle.
      if (alloc_valid_i[0] && (count_q < ROB_COUNT_MAX))
        alloc_accept_o[0] = 1'b1;
      if (alloc_valid_i[0] && alloc_valid_i[1] &&
          (count_q <= ROB_DUAL_ALLOC_LIMIT))
        alloc_accept_o[1] = 1'b1;
    end
    alloc_count = {1'b0, alloc_accept_o[0]} + {1'b0, alloc_accept_o[1]};

    tail_after_alloc = rob_ptr_add(tail_q, alloc_count);
    // Recovery discards only work younger than the resolving branch.  Older
    // completed heads may retire on the same edge, so measure the surviving
    // window from the post-retirement head.  This preserves precise in-order
    // state without paying one empty commit cycle on every misprediction.
    recovery_count = rob_distance(recovery_tail_i, head_after_retire);
  end

  // Allocation identities depend only on the tail and slot generations.  Keep
  // them out of the accept calculation so dispatch_valid cannot form a false
  // combinational feedback path through the ROB pointer outputs.
  always_comb begin
    alloc_rob_ptr_o[0] = tail_q;
    alloc_rob_ptr_o[1] = rob_ptr_add(tail_q, 2'd1);
    alloc_uop_id_o[0] = {
      slot_gen_q[rob_index(alloc_rob_ptr_o[0])] + 1'b1,
      alloc_rob_ptr_o[0]
    };
    alloc_uop_id_o[1] = {
      slot_gen_q[rob_index(alloc_rob_ptr_o[1])] + 1'b1,
      alloc_rob_ptr_o[1]
    };
  end

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      alloc_index[lane] = rob_index(alloc_rob_ptr_o[lane]);
      alloc_payload[lane] = '{
        pc: alloc_pc_i[lane],
        inst: alloc_inst_i[lane],
        rd_wen: alloc_rd_wen_i[lane],
        rd_addr: alloc_rd_addr_i[lane],
        pdst: alloc_pdst_i[lane],
        stale_pdst: alloc_stale_pdst_i[lane]
      };
    end

    alloc_even_we = 1'b0;
    alloc_odd_we = 1'b0;
    alloc_even_addr = '0;
    alloc_odd_addr = '0;
    alloc_even_data = '0;
    alloc_odd_data = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (alloc_accept_o[lane]) begin
        if (alloc_index[lane][0]) begin
          alloc_odd_we = 1'b1;
          alloc_odd_addr = alloc_index[lane][ROB_INDEX_W-1:1];
          alloc_odd_data = alloc_payload[lane];
        end else begin
          alloc_even_we = 1'b1;
          alloc_even_addr = alloc_index[lane][ROB_INDEX_W-1:1];
          alloc_even_data = alloc_payload[lane];
        end
      end
    end
  end

  // Each bank is read only once.  When the head is odd, the following even
  // entry lives in the next bank row; otherwise both heads share the row.
  always_comb begin
    head_slot = rob_index(head_q);
    head_odd_addr = head_slot[ROB_INDEX_W-1:1];
    head_even_addr = head_slot[ROB_INDEX_W-1:1] +
                     BANK_ADDR_W'(head_slot[0]);
    head_alloc_even = alloc_even_q[head_even_addr];
    head_alloc_odd = alloc_odd_q[head_odd_addr];
    if (alloc_even_pending_q &&
        (alloc_even_pending_addr_q == head_even_addr))
      head_alloc_even = alloc_even_pending_data_q;
    if (alloc_odd_pending_q &&
        (alloc_odd_pending_addr_q == head_odd_addr))
      head_alloc_odd = alloc_odd_pending_data_q;
    head_complete0_even = rob_complete_payload_t'(
      complete0_even_q[head_even_addr]
    );
    head_complete0_odd = rob_complete_payload_t'(
      complete0_odd_q[head_odd_addr]
    );
    head_complete1_even = rob_complete_payload_t'(
      complete1_even_q[head_even_addr]
    );
    head_complete1_odd = rob_complete_payload_t'(
      complete1_odd_q[head_odd_addr]
    );
    if (head_slot[0]) begin
      head_alloc[0] = head_alloc_odd;
      head_alloc[1] = head_alloc_even;
    end else begin
      head_alloc[0] = head_alloc_even;
      head_alloc[1] = head_alloc_odd;
    end
    head_index[0] = head_slot;
    head_index[1] = head_slot + 1'b1;
    head_complete[0] = complete_source_q[head_index[0]]
      ? (head_slot[0] ? head_complete1_odd : head_complete1_even)
      : (head_slot[0] ? head_complete0_odd : head_complete0_even);
    head_complete[1] = complete_source_q[head_index[1]]
      ? (head_slot[0] ? head_complete1_even : head_complete1_odd)
      : (head_slot[0] ? head_complete0_even : head_complete0_odd);

    head_entry_o[0] = '0;
    head_entry_o[1] = '0;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if ((lane == 0 && count_q != 0) || (lane == 1 && count_q > 1)) begin
        head_entry_o[lane] = '{
          valid: valid_q[head_index[lane]],
          done: complete_done_q[head_index[lane]],
          rob_ptr: rob_ptr_q[head_index[lane]],
          uop_id: {slot_gen_q[head_index[lane]], rob_ptr_q[head_index[lane]]},
          pc: head_alloc[lane].pc,
          inst: head_alloc[lane].inst,
          rd_wen: head_alloc[lane].rd_wen,
          rd_addr: head_alloc[lane].rd_addr,
          pdst: head_alloc[lane].pdst,
          stale_pdst: head_alloc[lane].stale_pdst,
          result: head_complete[lane].result,
          exception: head_complete[lane].exception,
          cause: head_complete[lane].cause,
          tval: head_complete[lane].tval
        };
      end
    end
  end

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      complete_index[lane] = rob_index(uop_rob_ptr(complete_uop_id_i[lane]));
      // Completion producers validate their live identity at the source: the
      // elastic EX stages are killed by the exact recovery interval, LQ owns
      // seq/uop matching, and the M-unit checks its accepted uop generation.
      // Keep that distributed hardware contract here; repeating a 32-entry
      // dynamic identity read would put a global comparator back on the hot
      // cache-response/writeback path.  The assertion below remains the
      // independent end-to-end proof of every producer.
      complete_match[lane] = complete_valid_i[lane];
      complete_payload[lane] = '{
        result: complete_result_i[lane],
        exception: complete_exception_i[lane],
        cause: complete_cause_i[lane],
        tval: complete_tval_i[lane]
      };
    end
  end

  // Static allocation banks cross a local pending boundary.  Dispatch may
  // still proceed every cycle; the earliest execution completion is later
  // than this write, so retirement observes the payload without a new bubble.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      alloc_even_pending_q <= 1'b0;
      alloc_odd_pending_q <= 1'b0;
      alloc_even_pending_addr_q <= '0;
      alloc_odd_pending_addr_q <= '0;
      alloc_even_pending_data_q <= '0;
      alloc_odd_pending_data_q <= '0;
    end else begin
      if (alloc_even_pending_q)
        alloc_even_q[alloc_even_pending_addr_q] <= alloc_even_pending_data_q;
      if (alloc_odd_pending_q)
        alloc_odd_q[alloc_odd_pending_addr_q] <= alloc_odd_pending_data_q;
      alloc_even_pending_q <= alloc_even_we;
      alloc_odd_pending_q <= alloc_odd_we;
      if (alloc_even_we) begin
        alloc_even_pending_addr_q <= alloc_even_addr;
        alloc_even_pending_data_q <= alloc_even_data;
      end
      if (alloc_odd_we) begin
        alloc_odd_pending_addr_q <= alloc_odd_addr;
        alloc_odd_pending_data_q <= alloc_odd_data;
      end
    end
  end

  // Completion port memories are independent one-write LUTRAMs.
  always_ff @(posedge clk_i) begin
    if (rst_ni && complete_match[0]) begin
      if (complete_index[0][0])
        complete0_odd_q[complete_index[0][ROB_INDEX_W-1:1]] <=
          complete_payload[0];
      else
        complete0_even_q[complete_index[0][ROB_INDEX_W-1:1]] <=
          complete_payload[0];
    end
    if (rst_ni && complete_match[1]) begin
      if (complete_index[1][0])
        complete1_odd_q[complete_index[1][ROB_INDEX_W-1:1]] <=
          complete_payload[1];
      else
        complete1_even_q[complete_index[1][ROB_INDEX_W-1:1]] <=
          complete_payload[1];
    end
  end

  // Only the completion-valid/source metadata needs reset and arbitrary
  // two-port updates.  Allocation clearing has precedence over stale writes.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
        complete_done_q[i] <= 1'b0;
        complete_source_q[i] <= 1'b0;
      end
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (complete_match[lane]) begin
          complete_done_q[complete_index[lane]] <= 1'b1;
          complete_source_q[complete_index[lane]] <= lane[0];
        end
      end
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (alloc_accept_o[lane]) begin
          complete_done_q[alloc_index[lane]] <= 1'b0;
          complete_source_q[alloc_index[lane]] <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin : rob_state
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
        valid_q[i] <= 1'b0;
        slot_gen_q[i] <= '0;
      end
    end else begin
      // count_q and head_q define the live ROB window.  A retired physical row
      // is unreachable until tail allocation reinitializes its generation and
      // completion state, so writing its valid bit low is unnecessary.  Not
      // doing so prevents live head/retire arbitration from being decoded into
      // all 32 valid-bit D inputs.

      if (recovery_valid_i) begin
        head_q <= head_after_retire;
        tail_q <= recovery_tail_i;
        count_q <= recovery_count;
        for (int unsigned i = 0; i < ROB_ENTRIES; i++) begin
          // recovery_tail_i is the first discarded uop and tail_q is the
          // exclusive end of the live window.  Clearing that half-open tail
          // interval is equivalent to rebuilding the survivor window from
          // head_after_retire, but it keeps the retire/head arithmetic out of
          // every valid bit's D cone.
          if (valid_q[i] &&
              rob_ptr_in_range(rob_ptr_q[i], recovery_tail_i, tail_q))
            valid_q[i] <= 1'b0;
        end
      end else begin
        head_q <= head_after_retire;
        tail_q <= tail_after_alloc;
        count_q <= count_after_retire + {4'b0, alloc_count};
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (alloc_accept_o[lane]) begin
            valid_q[rob_index(alloc_rob_ptr_o[lane])] <= 1'b1;
            rob_ptr_q[rob_index(alloc_rob_ptr_o[lane])] <= alloc_rob_ptr_o[lane];
            slot_gen_q[rob_index(alloc_rob_ptr_o[lane])] <=
              alloc_uop_id_o[lane][UOP_ID_W-1 -: UOP_GEN_W];
          end
        end
      end
    end
  end

  assign head_ptr_o = head_q;
  assign tail_ptr_o = tail_q;
  assign count_o = count_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (count_q <= ROB_COUNT_MAX) else $fatal(1, "ROB occupancy overflow");
      assert (!(alloc_valid_i[1] && !alloc_valid_i[0]))
        else $fatal(1, "ROB lane1 allocation requires lane0");
      assert (retire_count_i <= 2) else $fatal(1, "ROB retire count exceeds two");
      assert ({4'b0, retire_count_i} <= count_q)
        else $fatal(1, "ROB retired more entries than present");
      if (recovery_valid_i) begin
        assert (recovery_count <= count_q)
          else $fatal(1,
            "ROB recovery tail is outside the live window: head=%0d head_after=%0d tail=%0d recovery_tail=%0d count=%0d count_after=%0d recovery_count=%0d retire=%0d",
            head_q, head_after_retire, tail_q, recovery_tail_i, count_q,
            count_after_retire, recovery_count, retire_count_safe);
        assert (!(|alloc_accept_o))
          else $fatal(1, "ROB allocated during recovery");
      end
      if (complete_valid_i[0] && complete_valid_i[1]) begin
        assert (complete_uop_id_i[0] != complete_uop_id_i[1])
          else $fatal(1, "two completion ports targeted one uop");
      end
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (complete_valid_i[lane]) begin
          assert (valid_q[complete_index[lane]] &&
                  (rob_ptr_q[complete_index[lane]] ==
                   uop_rob_ptr(complete_uop_id_i[lane])) &&
                  (slot_gen_q[complete_index[lane]] ==
                   complete_uop_id_i[lane][UOP_ID_W-1 -: UOP_GEN_W]))
            else $fatal(1,
              "completion producer supplied a stale ROB identity: lane=%0d uop_id=0x%0h ptr=%0d index=%0d valid=%0b stored_ptr=%0d stored_gen=%0d incoming_gen=%0d head=%0d tail=%0d count=%0d recovery=%0b recovery_tail=%0d retire=%0d",
              lane, complete_uop_id_i[lane],
              uop_rob_ptr(complete_uop_id_i[lane]), complete_index[lane],
              valid_q[complete_index[lane]],
              rob_ptr_q[complete_index[lane]],
              slot_gen_q[complete_index[lane]],
              complete_uop_id_i[lane][UOP_ID_W-1 -: UOP_GEN_W],
              head_q, tail_q, count_q, recovery_valid_i,
              recovery_tail_i, retire_count_safe);
        end
      end
    end
  end
`endif
endmodule
