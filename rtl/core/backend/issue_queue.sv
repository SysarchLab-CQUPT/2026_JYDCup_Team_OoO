`timescale 1ns/1ps
module issue_queue #(
  parameter int unsigned ENTRIES = 8,
  parameter int unsigned WAKEUP_PORTS = 3,
  parameter int unsigned SELECT_WAKEUP_PORTS = 2
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic [1:0]                        dispatch_valid_i,
  input  backend_types_pkg::issue_entry_t   dispatch_entry_i [2],
  input  logic [1:0]                        dispatch_src1_ready_i,
  input  logic [1:0]                        dispatch_src2_ready_i,
  input  logic [1:0]                        dispatch_mem_ready_i,
  output logic [1:0]                        dispatch_accept_o,
  input  logic [WAKEUP_PORTS-1:0]           wakeup_valid_i,
  input  core_types_pkg::preg_t             wakeup_preg_i [WAKEUP_PORTS],
  // Fixed-latency producers at the registered EX boundary may make an entry
  // selectable in this cycle.  These inputs must never be driven from this
  // queue's current issue output; that would recreate a zero-cycle
  // ready->select->wakeup->ready feedback path.
  input  logic [SELECT_WAKEUP_PORTS-1:0]     select_wakeup_valid_i,
  input  core_types_pkg::preg_t             select_wakeup_preg_i [SELECT_WAKEUP_PORTS],
  // Registered LQ dependency state.  A newly asserted bit may use the same
  // short selection bypass as an EX wakeup, while persistent IQ state is
  // updated on the following edge.  The current EX/SQ resolve cone must not
  // drive this input directly.
  input  logic [7:0]                        load_mem_ready_bitmap_i,
  output logic                              can_accept_one_o,
  output logic                              can_accept_two_o,
  output logic                              issue_valid_o,
  input  logic                              issue_ready_i,
  output backend_types_pkg::issue_entry_t   issue_entry_o,
  output core_types_pkg::preg_t             issue_ps1_o,
  output core_types_pkg::preg_t             issue_ps2_o,
  output core_types_pkg::preg_t             issue_pdst_o,
  output logic                              issue_fast_wakeup_o,
  output logic [SELECT_WAKEUP_PORTS-1:0]    issue_src1_select_hit_o,
  output logic [SELECT_WAKEUP_PORTS-1:0]    issue_src2_select_hit_o,
  input  logic                              flush_i,
  input  logic                              recovery_valid_i,
  input  core_types_pkg::rob_ptr_t           recovery_start_i,
  input  core_types_pkg::rob_ptr_t           recovery_end_i,
  output logic [$clog2(2*ENTRIES+1)-1:0]    count_o,
  output logic [$clog2(ENTRIES+1)-1:0]      bank0_free_o,
  output logic [$clog2(ENTRIES+1)-1:0]      bank1_free_o
);
  import core_types_pkg::*;
  import backend_types_pkg::*;
  import rv32_pkg::*;

  // Wakeup/selection keys live in the parallel arrays below.  Storing those
  // same fields again in every wide payload row wastes roughly one fifth of
  // both IQ payloads and enlarges the selected-data mux.  Keep only immutable
  // execute metadata here; rebuild the public issue_entry_t at the output.
  typedef struct packed {
    uop_op_e                   op;
    logic [31:0]               pc;
    logic [31:0]               inst;
    logic [31:0]               imm;
    logic [11:0]               csr_addr;
    core_types_pkg::uop_id_t    uop_id;
    logic                      rd_wen;
    logic                      is_branch;
    logic                      is_jump;
    logic                      is_store;
    logic                      is_muldiv;
    logic                      is_csr;
    mem_size_e                 mem_size;
    logic                      mem_unsigned;
    logic [3:0]                sq_seq;
    logic [3:0]                older_sq_tail;
    logic [31:0]               predicted_pc;
    logic [3:0]                recovery_lq_tail;
    logic [3:0]                recovery_sq_tail;
    logic                      fetch_fault;
  } issue_payload_t;

  function automatic issue_payload_t compact_payload(input issue_entry_t e);
    issue_payload_t payload;
    payload = '{
      op: e.op,
      pc: e.pc,
      inst: e.inst,
      imm: e.imm,
      csr_addr: e.csr_addr,
      uop_id: e.uop_id,
      rd_wen: e.rd_wen,
      is_branch: e.is_branch,
      is_jump: e.is_jump,
      is_store: e.is_store,
      is_muldiv: e.is_muldiv,
      is_csr: e.is_csr,
      mem_size: e.mem_size,
      mem_unsigned: e.mem_unsigned,
      sq_seq: e.sq_seq,
      older_sq_tail: e.older_sq_tail,
      predicted_pc: e.predicted_pc,
      recovery_lq_tail: e.recovery_lq_tail,
      recovery_sq_tail: e.recovery_sq_tail,
      fetch_fault: e.fetch_fault
    };
    return payload;
  endfunction

  localparam int unsigned INDEX_W = $clog2(ENTRIES);
  localparam int unsigned ENTRY_W = $bits(issue_payload_t);
  localparam int unsigned CAPACITY = 2 * ENTRIES;
  localparam int unsigned BANK_COUNT_W = $clog2(ENTRIES + 1);

  // The execution payload is immutable after insertion.  Keep two physical
  // write banks so a dual dispatch performs at most one write per RAM.  Both
  // banks contribute architectural capacity, providing a 2*ENTRIES window.
  (* ram_style = "distributed" *)
  logic [ENTRY_W-1:0] payload_bank0_q [ENTRIES];
  (* ram_style = "distributed" *)
  logic [ENTRY_W-1:0] payload_bank1_q [ENTRIES];

  // Selection and wakeup need all keys in parallel.  Only these narrow keys,
  // valid bits, and readiness bits remain in registers.
  logic valid_bank0_q [ENTRIES], valid_bank1_q [ENTRIES];
  logic src1_ready_bank0_q [ENTRIES], src1_ready_bank1_q [ENTRIES];
  logic src2_ready_bank0_q [ENTRIES], src2_ready_bank1_q [ENTRIES];
  // This is a denormalized view of the persistent operand/memory readiness
  // state, not an extra issue pipeline stage.  It is updated at the same edge
  // as the component ready bits, so selection keeps identical cycle timing
  // without rebuilding a four-input ready predicate in front of every age
  // mask reduction.
  logic entry_ready_bank0_q [ENTRIES], entry_ready_bank1_q [ENTRIES];
  logic src1_ready_bank0_next [ENTRIES], src1_ready_bank1_next [ENTRIES];
  logic src2_ready_bank0_next [ENTRIES], src2_ready_bank1_next [ENTRIES];
  logic load_mem_ready_bank0_next [ENTRIES], load_mem_ready_bank1_next [ENTRIES];
  logic entry_ready_bank0_next [ENTRIES], entry_ready_bank1_next [ENTRIES];
  rob_ptr_t rob_ptr_bank0_q [ENTRIES], rob_ptr_bank1_q [ENTRIES];
  preg_t ps1_bank0_q [ENTRIES], ps1_bank1_q [ENTRIES];
  preg_t ps2_bank0_q [ENTRIES], ps2_bank1_q [ENTRIES];
  preg_t pdst_bank0_q [ENTRIES], pdst_bank1_q [ENTRIES];
  logic fast_wakeup_bank0_q [ENTRIES], fast_wakeup_bank1_q [ENTRIES];
  logic uses_ps1_bank0_q [ENTRIES], uses_ps1_bank1_q [ENTRIES];
  logic uses_ps2_bank0_q [ENTRIES], uses_ps2_bank1_q [ENTRIES];
  logic is_load_bank0_q [ENTRIES], is_load_bank1_q [ENTRIES];
  logic [3:0] lq_seq_bank0_q [ENTRIES], lq_seq_bank1_q [ENTRIES];
  logic load_mem_ready_bank0_q [ENTRIES], load_mem_ready_bank1_q [ENTRIES];

  // Admission tokens are prepared from the post-edge valid map.  Dispatch
  // consumes only a registered {bank,index} choice; it never participates in
  // a same-cycle first-free scan or feeds a wide payload back through one.
  logic token_bank0_valid_q, token_bank1_valid_q;
  logic token_bank0_valid_next, token_bank1_valid_next;
  logic [INDEX_W-1:0] token_bank0_idx_q, token_bank1_idx_q;
  logic [INDEX_W-1:0] token_bank0_idx_next, token_bank1_idx_next;
  logic [ENTRIES-1:0] post_valid_bank0, post_valid_bank1;
  logic [BANK_COUNT_W-1:0] bank0_count_q, bank1_count_q;
  logic [BANK_COUNT_W-1:0] bank0_count_next, bank1_count_next;
  logic [BANK_COUNT_W-1:0] recovery_bank0_count;
  logic [BANK_COUNT_W-1:0] recovery_bank1_count;
  logic issue_recovery_killed_for_count;
  logic can_accept_one_q, can_accept_two_q;
  logic can_accept_one_next, can_accept_two_next;
  logic bank_alloc_prefer_q;

  logic payload_bank0_we, payload_bank1_we;
  logic [INDEX_W-1:0] payload_bank0_waddr, payload_bank1_waddr;
  issue_entry_t payload_bank0_wdata, payload_bank1_wdata;
  issue_payload_t payload_bank0_compact_wdata, payload_bank1_compact_wdata;
  logic payload_bank0_src1_ready, payload_bank1_src1_ready;
  logic payload_bank0_src2_ready, payload_bank1_src2_ready;
  logic payload_bank0_mem_ready, payload_bank1_mem_ready;

  logic [CAPACITY-1:0] valid_bitmap;
  logic [CAPACITY-1:0] ready_bitmap;
  logic [CAPACITY-1:0] registered_ready_bitmap;
  logic [CAPACITY-1:0] bypass_ready_bitmap;
  logic [CAPACITY-1:0] oldest_ready_bitmap;
  logic [CAPACITY-1:0] older_mask_q [CAPACITY];
  logic [SELECT_WAKEUP_PORTS-1:0] select_src1_hit_bank0 [ENTRIES];
  logic [SELECT_WAKEUP_PORTS-1:0] select_src1_hit_bank1 [ENTRIES];
  logic [SELECT_WAKEUP_PORTS-1:0] select_src2_hit_bank0 [ENTRIES];
  logic [SELECT_WAKEUP_PORTS-1:0] select_src2_hit_bank1 [ENTRIES];
  logic load_mem_ready_hit_bank0 [ENTRIES], load_mem_ready_hit_bank1 [ENTRIES];
  logic load_mem_ready_now_bank0 [ENTRIES], load_mem_ready_now_bank1 [ENTRIES];
  logic load_mem_age_ready_bank0 [ENTRIES], load_mem_age_ready_bank1 [ENTRIES];

  logic age_issue_found, age_issue_bank0_found, age_issue_bank1_found;
  logic age_issue_bank;
  logic [INDEX_W-1:0] age_issue_idx;
  logic [ENTRIES-1:0] bypass_bank0_onehot, bypass_bank1_onehot;
  logic bypass_issue_found, bypass_bank0_found, bypass_bank1_found;
  logic bypass_issue_bank;
  logic [INDEX_W-1:0] bypass_issue_idx;
  logic issue_found;
  // The index fans out to the distributed payload/key RAM read addresses.
  // Bound synthesis fanout so replicas can be placed next to those consumers
  // instead of routing one selector node across the entire backend.
  (* max_fanout = 48 *) logic issue_bank;
  (* max_fanout = 48 *) logic [INDEX_W-1:0] issue_idx;
  logic [ENTRY_W-1:0] issue_payload_bank0_bits, issue_payload_bank1_bits;
  issue_payload_t issue_payload_bank0, issue_payload_bank1;
  preg_t issue_ps1_bank0, issue_ps1_bank1;
  preg_t issue_ps2_bank0, issue_ps2_bank1;
  preg_t issue_pdst_bank0, issue_pdst_bank1;
  rob_ptr_t issue_rob_ptr_bank0, issue_rob_ptr_bank1;
  logic issue_fast_wakeup_bank0, issue_fast_wakeup_bank1;
  logic issue_uses_ps1_bank0, issue_uses_ps1_bank1;
  logic issue_uses_ps2_bank0, issue_uses_ps2_bank1;
  logic issue_is_load_bank0, issue_is_load_bank1;
  logic [3:0] issue_lq_seq_bank0, issue_lq_seq_bank1;

  always_comb begin
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      src1_ready_bank0_next[i] = src1_ready_bank0_q[i];
      src1_ready_bank1_next[i] = src1_ready_bank1_q[i];
      src2_ready_bank0_next[i] = src2_ready_bank0_q[i];
      src2_ready_bank1_next[i] = src2_ready_bank1_q[i];
      load_mem_ready_bank0_next[i] = load_mem_ready_bank0_q[i];
      load_mem_ready_bank1_next[i] = load_mem_ready_bank1_q[i];

      if (valid_bank0_q[i] && is_load_bank0_q[i] &&
          load_mem_ready_bitmap_i[lq_seq_bank0_q[i][2:0]])
        load_mem_ready_bank0_next[i] = 1'b1;
      if (valid_bank1_q[i] && is_load_bank1_q[i] &&
          load_mem_ready_bitmap_i[lq_seq_bank1_q[i][2:0]])
        load_mem_ready_bank1_next[i] = 1'b1;

      for (int unsigned wb = 0; wb < WAKEUP_PORTS; wb++) begin
        if (valid_bank0_q[i] && wakeup_valid_i[wb] &&
            uses_ps1_bank0_q[i] &&
            (ps1_bank0_q[i] == wakeup_preg_i[wb]))
          src1_ready_bank0_next[i] = 1'b1;
        if (valid_bank0_q[i] && wakeup_valid_i[wb] &&
            uses_ps2_bank0_q[i] &&
            (ps2_bank0_q[i] == wakeup_preg_i[wb]))
          src2_ready_bank0_next[i] = 1'b1;
        if (valid_bank1_q[i] && wakeup_valid_i[wb] &&
            uses_ps1_bank1_q[i] &&
            (ps1_bank1_q[i] == wakeup_preg_i[wb]))
          src1_ready_bank1_next[i] = 1'b1;
        if (valid_bank1_q[i] && wakeup_valid_i[wb] &&
            uses_ps2_bank1_q[i] &&
            (ps2_bank1_q[i] == wakeup_preg_i[wb]))
          src2_ready_bank1_next[i] = 1'b1;
      end

      entry_ready_bank0_next[i] = src1_ready_bank0_next[i] &&
                                  src2_ready_bank0_next[i] &&
                                  load_mem_ready_bank0_next[i];
      entry_ready_bank1_next[i] = src1_ready_bank1_next[i] &&
                                  src2_ready_bank1_next[i] &&
                                  load_mem_ready_bank1_next[i];
    end
  end

  always_comb begin
    valid_bitmap = '0;
    ready_bitmap = '0;
    registered_ready_bitmap = '0;
    bypass_ready_bitmap = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      valid_bitmap[i] = valid_bank0_q[i];
      valid_bitmap[i+ENTRIES] = valid_bank1_q[i];
      select_src1_hit_bank0[i] = '0;
      select_src1_hit_bank1[i] = '0;
      select_src2_hit_bank0[i] = '0;
      select_src2_hit_bank1[i] = '0;
      for (int unsigned fw = 0; fw < SELECT_WAKEUP_PORTS; fw++) begin
        if (select_wakeup_valid_i[fw] && uses_ps1_bank0_q[i] &&
            (ps1_bank0_q[i] == select_wakeup_preg_i[fw]))
          select_src1_hit_bank0[i][fw] = 1'b1;
        if (select_wakeup_valid_i[fw] && uses_ps2_bank0_q[i] &&
            (ps2_bank0_q[i] == select_wakeup_preg_i[fw]))
          select_src2_hit_bank0[i][fw] = 1'b1;
        if (select_wakeup_valid_i[fw] && uses_ps1_bank1_q[i] &&
            (ps1_bank1_q[i] == select_wakeup_preg_i[fw]))
          select_src1_hit_bank1[i][fw] = 1'b1;
        if (select_wakeup_valid_i[fw] && uses_ps2_bank1_q[i] &&
            (ps2_bank1_q[i] == select_wakeup_preg_i[fw]))
          select_src2_hit_bank1[i][fw] = 1'b1;
      end

      // Keep the age tree physically independent from current EX tags.  The
      // LQ bitmap is already registered, so a load whose persistent operands
      // are ready can enter the ordinary age tree immediately without the old
      // EX -> SQ -> LQ -> IQ combinational feedback.  A same-cycle EX operand
      // wakeup still uses only the short bypass below.
      load_mem_ready_hit_bank0[i] = valid_bank0_q[i] && is_load_bank0_q[i] &&
        !load_mem_ready_bank0_q[i] &&
        load_mem_ready_bitmap_i[lq_seq_bank0_q[i][2:0]];
      load_mem_ready_hit_bank1[i] = valid_bank1_q[i] && is_load_bank1_q[i] &&
        !load_mem_ready_bank1_q[i] &&
        load_mem_ready_bitmap_i[lq_seq_bank1_q[i][2:0]];
      load_mem_ready_now_bank0[i] = load_mem_ready_bank0_q[i] ||
                                    load_mem_ready_hit_bank0[i];
      load_mem_ready_now_bank1[i] = load_mem_ready_bank1_q[i] ||
                                    load_mem_ready_hit_bank1[i];
      load_mem_age_ready_bank0[i] = load_mem_ready_hit_bank0[i] &&
                                    src1_ready_bank0_q[i] &&
                                    src2_ready_bank0_q[i];
      load_mem_age_ready_bank1[i] = load_mem_ready_hit_bank1[i] &&
                                    src1_ready_bank1_q[i] &&
                                    src2_ready_bank1_q[i];
      registered_ready_bitmap[i] = entry_ready_bank0_q[i] ||
                                    load_mem_age_ready_bank0[i];
      registered_ready_bitmap[i+ENTRIES] = entry_ready_bank1_q[i] ||
                                            load_mem_age_ready_bank1[i];
      bypass_ready_bitmap[i] = !entry_ready_bank0_q[i] &&
        valid_bank0_q[i] && load_mem_ready_now_bank0[i] &&
        (load_mem_ready_hit_bank0[i] ||
         (|select_src1_hit_bank0[i]) || (|select_src2_hit_bank0[i])) &&
        (src1_ready_bank0_q[i] || (|select_src1_hit_bank0[i])) &&
        (src2_ready_bank0_q[i] || (|select_src2_hit_bank0[i]));
      bypass_ready_bitmap[i+ENTRIES] = !entry_ready_bank1_q[i] &&
        valid_bank1_q[i] && load_mem_ready_now_bank1[i] &&
        (load_mem_ready_hit_bank1[i] ||
         (|select_src1_hit_bank1[i]) || (|select_src2_hit_bank1[i])) &&
        (src1_ready_bank1_q[i] || (|select_src1_hit_bank1[i])) &&
        (src2_ready_bank1_q[i] || (|select_src2_hit_bank1[i]));
    end
    ready_bitmap = registered_ready_bitmap | bypass_ready_bitmap;

    // Each row remembers which occupied slots were older when it entered.
    // Only persistent state enters this global matrix.  EX/recovery/PRF tags
    // therefore cannot cross the matrix and return to an EX capture register
    // in the same cycle.
    oldest_ready_bitmap = '0;
    for (int unsigned i = 0; i < CAPACITY; i++)
      oldest_ready_bitmap[i] = registered_ready_bitmap[i] &&
        ((registered_ready_bitmap & older_mask_q[i]) == '0);

    age_issue_bank0_found = |oldest_ready_bitmap[ENTRIES-1:0];
    age_issue_bank1_found = |oldest_ready_bitmap[CAPACITY-1:ENTRIES];
    age_issue_found = age_issue_bank0_found || age_issue_bank1_found;
    age_issue_bank = age_issue_bank1_found;
    age_issue_idx = '0;
    for (int unsigned i = 0; i < ENTRIES; i++)
      begin
        age_issue_idx |= INDEX_W'(i) &
          {INDEX_W{oldest_ready_bitmap[i] |
                   oldest_ready_bitmap[i+ENTRIES]}};
      end

    // Newly woken rows use a separate bank-local carry/priority tree.  Exact
    // global age is unnecessary for correctness of out-of-order issue; the
    // row becomes age-ordered persistent-ready on the following edge if this
    // one-cycle fast path does not consume it.
    bypass_bank0_onehot = bypass_ready_bitmap[ENTRIES-1:0] &
      (~bypass_ready_bitmap[ENTRIES-1:0] + 1'b1);
    bypass_bank1_onehot = bypass_ready_bitmap[CAPACITY-1:ENTRIES] &
      (~bypass_ready_bitmap[CAPACITY-1:ENTRIES] + 1'b1);
    bypass_bank0_found = |bypass_bank0_onehot;
    bypass_bank1_found = |bypass_bank1_onehot;
    bypass_issue_found = bypass_bank0_found || bypass_bank1_found;
    bypass_issue_bank = !bypass_bank0_found && bypass_bank1_found;
    bypass_issue_idx = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      bypass_issue_idx |= INDEX_W'(i) &
        {INDEX_W{bypass_issue_bank ? bypass_bank1_onehot[i]
                                   : bypass_bank0_onehot[i]}};
    end

    // Preserve the scheduler's oldest-ready policy whenever registered work
    // exists.  The short EX bypass is used only to avoid an otherwise empty
    // issue cycle; an unselected just-woken row joins the exact age tree on the
    // following edge through the ordinary persistent wakeup state update.
    issue_found = bypass_issue_found || age_issue_found;
    issue_bank = age_issue_found ? age_issue_bank : bypass_issue_bank;
    issue_idx = age_issue_found ? age_issue_idx : bypass_issue_idx;

    // Decode the one-hot age winner once, then address both physical banks.
    // The former per-row AND/OR network replicated the oldest-ready term for
    // every payload bit and prevented the wide immutable payload from looking
    // like an ordinary asynchronous-read RAM.  Invalid output data is a don't
    // care architecturally, but retaining a zero value keeps the old interface
    // behaviour and avoids propagating uninitialised RAM contents in simulation.
    issue_payload_bank0_bits = '0;
    issue_payload_bank1_bits = '0;
    issue_ps1_bank0 = '0;
    issue_ps1_bank1 = '0;
    issue_ps2_bank0 = '0;
    issue_ps2_bank1 = '0;
    issue_pdst_bank0 = '0;
    issue_pdst_bank1 = '0;
    issue_rob_ptr_bank0 = '0;
    issue_rob_ptr_bank1 = '0;
    issue_fast_wakeup_bank0 = 1'b0;
    issue_fast_wakeup_bank1 = 1'b0;
    issue_uses_ps1_bank0 = 1'b0;
    issue_uses_ps1_bank1 = 1'b0;
    issue_uses_ps2_bank0 = 1'b0;
    issue_uses_ps2_bank1 = 1'b0;
    issue_is_load_bank0 = 1'b0;
    issue_is_load_bank1 = 1'b0;
    issue_lq_seq_bank0 = '0;
    issue_lq_seq_bank1 = '0;
    if (issue_found) begin
      issue_payload_bank0_bits = payload_bank0_q[issue_idx];
      issue_payload_bank1_bits = payload_bank1_q[issue_idx];
      issue_ps1_bank0 = ps1_bank0_q[issue_idx];
      issue_ps1_bank1 = ps1_bank1_q[issue_idx];
      issue_ps2_bank0 = ps2_bank0_q[issue_idx];
      issue_ps2_bank1 = ps2_bank1_q[issue_idx];
      issue_pdst_bank0 = pdst_bank0_q[issue_idx];
      issue_pdst_bank1 = pdst_bank1_q[issue_idx];
      issue_rob_ptr_bank0 = rob_ptr_bank0_q[issue_idx];
      issue_rob_ptr_bank1 = rob_ptr_bank1_q[issue_idx];
      issue_fast_wakeup_bank0 = fast_wakeup_bank0_q[issue_idx];
      issue_fast_wakeup_bank1 = fast_wakeup_bank1_q[issue_idx];
      issue_uses_ps1_bank0 = uses_ps1_bank0_q[issue_idx];
      issue_uses_ps1_bank1 = uses_ps1_bank1_q[issue_idx];
      issue_uses_ps2_bank0 = uses_ps2_bank0_q[issue_idx];
      issue_uses_ps2_bank1 = uses_ps2_bank1_q[issue_idx];
      issue_is_load_bank0 = is_load_bank0_q[issue_idx];
      issue_is_load_bank1 = is_load_bank1_q[issue_idx];
      issue_lq_seq_bank0 = lq_seq_bank0_q[issue_idx];
      issue_lq_seq_bank1 = lq_seq_bank1_q[issue_idx];
    end
    issue_payload_bank0 = issue_payload_t'(issue_payload_bank0_bits);
    issue_payload_bank1 = issue_payload_t'(issue_payload_bank1_bits);
    issue_entry_o = '0;
    issue_entry_o.valid = issue_found;
    issue_entry_o.op = issue_bank ? issue_payload_bank1.op
                                  : issue_payload_bank0.op;
    issue_entry_o.pc = issue_bank ? issue_payload_bank1.pc
                                  : issue_payload_bank0.pc;
    issue_entry_o.inst = issue_bank ? issue_payload_bank1.inst
                                    : issue_payload_bank0.inst;
    issue_entry_o.imm = issue_bank ? issue_payload_bank1.imm
                                   : issue_payload_bank0.imm;
    issue_entry_o.csr_addr = issue_bank ? issue_payload_bank1.csr_addr
                                        : issue_payload_bank0.csr_addr;
    issue_entry_o.rob_ptr = issue_bank ? issue_rob_ptr_bank1
                                       : issue_rob_ptr_bank0;
    issue_entry_o.uop_id = issue_bank ? issue_payload_bank1.uop_id
                                      : issue_payload_bank0.uop_id;
    issue_ps1_o = issue_bank ? issue_ps1_bank1 : issue_ps1_bank0;
    issue_ps2_o = issue_bank ? issue_ps2_bank1 : issue_ps2_bank0;
    issue_pdst_o = issue_bank ? issue_pdst_bank1 : issue_pdst_bank0;
    issue_entry_o.ps1 = issue_ps1_o;
    issue_entry_o.ps2 = issue_ps2_o;
    issue_entry_o.pdst = issue_pdst_o;
    issue_entry_o.uses_ps1 = issue_bank ? issue_uses_ps1_bank1
                                        : issue_uses_ps1_bank0;
    issue_entry_o.uses_ps2 = issue_bank ? issue_uses_ps2_bank1
                                        : issue_uses_ps2_bank0;
    issue_entry_o.rd_wen = issue_bank ? issue_payload_bank1.rd_wen
                                      : issue_payload_bank0.rd_wen;
    issue_entry_o.is_branch = issue_bank ? issue_payload_bank1.is_branch
                                         : issue_payload_bank0.is_branch;
    issue_entry_o.is_jump = issue_bank ? issue_payload_bank1.is_jump
                                       : issue_payload_bank0.is_jump;
    issue_entry_o.is_load = issue_bank ? issue_is_load_bank1
                                       : issue_is_load_bank0;
    issue_entry_o.is_store = issue_bank ? issue_payload_bank1.is_store
                                        : issue_payload_bank0.is_store;
    issue_entry_o.is_muldiv = issue_bank ? issue_payload_bank1.is_muldiv
                                         : issue_payload_bank0.is_muldiv;
    issue_entry_o.is_csr = issue_bank ? issue_payload_bank1.is_csr
                                      : issue_payload_bank0.is_csr;
    issue_entry_o.mem_size = issue_bank ? issue_payload_bank1.mem_size
                                        : issue_payload_bank0.mem_size;
    issue_entry_o.mem_unsigned = issue_bank
      ? issue_payload_bank1.mem_unsigned : issue_payload_bank0.mem_unsigned;
    issue_entry_o.lq_seq = issue_bank ? issue_lq_seq_bank1
                                      : issue_lq_seq_bank0;
    issue_entry_o.sq_seq = issue_bank ? issue_payload_bank1.sq_seq
                                      : issue_payload_bank0.sq_seq;
    issue_entry_o.older_sq_tail = issue_bank
      ? issue_payload_bank1.older_sq_tail : issue_payload_bank0.older_sq_tail;
    issue_entry_o.predicted_pc = issue_bank ? issue_payload_bank1.predicted_pc
                                            : issue_payload_bank0.predicted_pc;
    issue_entry_o.recovery_lq_tail = issue_bank
      ? issue_payload_bank1.recovery_lq_tail
      : issue_payload_bank0.recovery_lq_tail;
    issue_entry_o.recovery_sq_tail = issue_bank
      ? issue_payload_bank1.recovery_sq_tail
      : issue_payload_bank0.recovery_sq_tail;
    issue_entry_o.fetch_fault = issue_bank ? issue_payload_bank1.fetch_fault
                                            : issue_payload_bank0.fetch_fault;
    issue_fast_wakeup_o = issue_found &&
      (issue_bank ? issue_fast_wakeup_bank1 : issue_fast_wakeup_bank0);
    issue_src1_select_hit_o = '0;
    issue_src2_select_hit_o = '0;
    if (issue_found) begin
      issue_src1_select_hit_o = issue_bank
        ? select_src1_hit_bank1[issue_idx]
        : select_src1_hit_bank0[issue_idx];
      issue_src2_select_hit_o = issue_bank
        ? select_src2_hit_bank1[issue_idx]
        : select_src2_hit_bank0[issue_idx];
    end
  end

  // Recovery removes its half-open victim range from queue state at the edge,
  // but it must not sit in front of the selected payload/PRF/EX register cone.
  // A selected victim is harmless when the consumer captures its data with a
  // cleared EX-valid bit; a selected survivor continues to issue normally.
  // This keeps the wide issue transfer independent of the recovery comparator
  // while preserving exact state truncation below.
  // Flush owns the sequential state update, while the top-level clears only
  // the narrow EX-valid bit.  Leaving flush out of this payload-valid cone
  // allows the wide selected data to remain a pure IQ/PRF path on a flush
  // edge; any data captured on that edge is architecturally invalid.
  assign issue_valid_o = issue_found;

  // The selected row may already be part of the recovery victim set.  Keep
  // this comparison local to occupancy accounting: subtracting it again from
  // recovery_*_count would double-delete the row.  It deliberately does not
  // qualify issue_valid_o or any selected payload/operand output.
  assign issue_recovery_killed_for_count = recovery_valid_i && issue_found &&
    rob_ptr_in_range(issue_entry_o.rob_ptr, recovery_start_i, recovery_end_i);

  // Occupancy is architectural queue state, not a same-cycle reduction of all
  // sixteen valid bits.  Keeping it alongside the entries breaks the former
  // valid -> population count -> top-level route -> queue-write feedback cone.
  assign count_o = $clog2(2*ENTRIES+1)'(bank0_count_q) +
                   $clog2(2*ENTRIES+1)'(bank1_count_q);
  assign bank0_free_o = BANK_COUNT_W'(ENTRIES) - bank0_count_q;
  assign bank1_free_o = BANK_COUNT_W'(ENTRIES) - bank1_count_q;
  assign can_accept_one_o = can_accept_one_q;
  assign can_accept_two_o = can_accept_two_q;

  always_comb begin
    recovery_bank0_count = '0;
    recovery_bank1_count = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      if (valid_bank0_q[i] &&
          !rob_ptr_in_range(rob_ptr_bank0_q[i], recovery_start_i,
                            recovery_end_i))
        recovery_bank0_count = recovery_bank0_count + 1'b1;
      if (valid_bank1_q[i] &&
          !rob_ptr_in_range(rob_ptr_bank1_q[i], recovery_start_i,
                            recovery_end_i))
        recovery_bank1_count = recovery_bank1_count + 1'b1;
    end
  end

  always_comb begin
    dispatch_accept_o = '0;
    payload_bank0_we = 1'b0;
    payload_bank1_we = 1'b0;
    payload_bank0_waddr = token_bank0_idx_q;
    payload_bank1_waddr = token_bank1_idx_q;
    payload_bank0_wdata = '0;
    payload_bank1_wdata = '0;
    payload_bank0_src1_ready = 1'b0;
    payload_bank1_src1_ready = 1'b0;
    payload_bank0_src2_ready = 1'b0;
    payload_bank1_src2_ready = 1'b0;
    payload_bank0_mem_ready = 1'b0;
    payload_bank1_mem_ready = 1'b0;

    if (!flush_i && !recovery_valid_i && dispatch_valid_i[0] &&
        can_accept_one_q) begin
      if (dispatch_valid_i[1] &&
          can_accept_two_q &&
          token_bank0_valid_q && token_bank1_valid_q) begin
        dispatch_accept_o = 2'b11;
        payload_bank0_we = 1'b1;
        payload_bank1_we = 1'b1;
        payload_bank0_wdata = dispatch_entry_i[0];
        payload_bank1_wdata = dispatch_entry_i[1];
        payload_bank0_src1_ready = !dispatch_entry_i[0].uses_ps1 ||
                                   dispatch_src1_ready_i[0];
        payload_bank0_src2_ready = !dispatch_entry_i[0].uses_ps2 ||
                                   dispatch_src2_ready_i[0];
        payload_bank1_src1_ready = !dispatch_entry_i[1].uses_ps1 ||
                                   dispatch_src1_ready_i[1];
        payload_bank1_src2_ready = !dispatch_entry_i[1].uses_ps2 ||
                                   dispatch_src2_ready_i[1];
        payload_bank0_mem_ready = !dispatch_entry_i[0].is_load ||
                                  dispatch_mem_ready_i[0];
        payload_bank1_mem_ready = !dispatch_entry_i[1].is_load ||
                                  dispatch_mem_ready_i[1];
      end else if ((!bank_alloc_prefer_q && token_bank0_valid_q) ||
                   !token_bank1_valid_q) begin
        dispatch_accept_o[0] = 1'b1;
        payload_bank0_we = 1'b1;
        payload_bank0_wdata = dispatch_entry_i[0];
        payload_bank0_src1_ready = !dispatch_entry_i[0].uses_ps1 ||
                                   dispatch_src1_ready_i[0];
        payload_bank0_src2_ready = !dispatch_entry_i[0].uses_ps2 ||
                                   dispatch_src2_ready_i[0];
        payload_bank0_mem_ready = !dispatch_entry_i[0].is_load ||
                                  dispatch_mem_ready_i[0];
      end else if (token_bank1_valid_q) begin
        dispatch_accept_o[0] = 1'b1;
        payload_bank1_we = 1'b1;
        payload_bank1_wdata = dispatch_entry_i[0];
        payload_bank1_src1_ready = !dispatch_entry_i[0].uses_ps1 ||
                                   dispatch_src1_ready_i[0];
        payload_bank1_src2_ready = !dispatch_entry_i[0].uses_ps2 ||
                                   dispatch_src2_ready_i[0];
        payload_bank1_mem_ready = !dispatch_entry_i[0].is_load ||
                                  dispatch_mem_ready_i[0];
      end
    end

    // Fold the event accepted at this edge into a newly allocated row.  The
    // same event is written into every older matching row below, so selection
    // in the following cycle reads only persistent ready state and never puts
    // wakeup compare in front of the IQ/PRF read cone.
    for (int unsigned wb = 0; wb < WAKEUP_PORTS; wb++) begin
      if (payload_bank0_we && wakeup_valid_i[wb] &&
          payload_bank0_wdata.uses_ps1 &&
          (payload_bank0_wdata.ps1 == wakeup_preg_i[wb]))
        payload_bank0_src1_ready = 1'b1;
      if (payload_bank0_we && wakeup_valid_i[wb] &&
          payload_bank0_wdata.uses_ps2 &&
          (payload_bank0_wdata.ps2 == wakeup_preg_i[wb]))
        payload_bank0_src2_ready = 1'b1;
      if (payload_bank1_we && wakeup_valid_i[wb] &&
          payload_bank1_wdata.uses_ps1 &&
          (payload_bank1_wdata.ps1 == wakeup_preg_i[wb]))
        payload_bank1_src1_ready = 1'b1;
      if (payload_bank1_we && wakeup_valid_i[wb] &&
          payload_bank1_wdata.uses_ps2 &&
          (payload_bank1_wdata.ps2 == wakeup_preg_i[wb]))
        payload_bank1_src2_ready = 1'b1;
    end
    payload_bank0_compact_wdata = compact_payload(payload_bank0_wdata);
    payload_bank1_compact_wdata = compact_payload(payload_bank1_wdata);
  end

  // Predict the exact valid map after this edge, then prepare the next free
  // token locally.  Recovery/issue/dispatch precedence mirrors the state
  // update below, including safe reuse of a row only after it is truly free.
  always_comb begin
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      post_valid_bank0[i] = valid_bank0_q[i];
      post_valid_bank1[i] = valid_bank1_q[i];
      if (flush_i) begin
        post_valid_bank0[i] = 1'b0;
        post_valid_bank1[i] = 1'b0;
      end else if (recovery_valid_i) begin
        if (rob_ptr_in_range(rob_ptr_bank0_q[i], recovery_start_i,
                             recovery_end_i))
          post_valid_bank0[i] = 1'b0;
        if (rob_ptr_in_range(rob_ptr_bank1_q[i], recovery_start_i,
                             recovery_end_i))
          post_valid_bank1[i] = 1'b0;
      end
    end
    if (!flush_i && issue_valid_o && issue_ready_i) begin
      if (issue_bank) post_valid_bank1[issue_idx] = 1'b0;
      else post_valid_bank0[issue_idx] = 1'b0;
    end
    if (!flush_i && payload_bank0_we)
      post_valid_bank0[payload_bank0_waddr] = 1'b1;
    if (!flush_i && payload_bank1_we)
      post_valid_bank1[payload_bank1_waddr] = 1'b1;

    token_bank0_valid_next = 1'b0;
    token_bank1_valid_next = 1'b0;
    token_bank0_idx_next = '0;
    token_bank1_idx_next = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      if (!token_bank0_valid_next && !post_valid_bank0[i]) begin
        token_bank0_valid_next = 1'b1;
        token_bank0_idx_next = i[INDEX_W-1:0];
      end
      if (!token_bank1_valid_next && !post_valid_bank1[i]) begin
        token_bank1_valid_next = 1'b1;
        token_bank1_idx_next = i[INDEX_W-1:0];
      end
    end
  end

  // Export registered admission credits.  The old bank-count subtraction and
  // comparison lived in the top-level dispatch cone, then fed predictor and
  // IQ writes back in the same cycle.  These bits are updated from the exact
  // post-edge occupancy and make that global path a short Boolean check.
  always_comb begin
    if (recovery_valid_i) begin
      bank0_count_next = recovery_bank0_count -
        BANK_COUNT_W'(issue_valid_o && issue_ready_i && !issue_bank &&
                      !issue_recovery_killed_for_count);
      bank1_count_next = recovery_bank1_count -
        BANK_COUNT_W'(issue_valid_o && issue_ready_i && issue_bank &&
                      !issue_recovery_killed_for_count);
    end else begin
      bank0_count_next = bank0_count_q + BANK_COUNT_W'(payload_bank0_we) -
        BANK_COUNT_W'(issue_valid_o && issue_ready_i && !issue_bank);
      bank1_count_next = bank1_count_q + BANK_COUNT_W'(payload_bank1_we) -
        BANK_COUNT_W'(issue_valid_o && issue_ready_i && issue_bank);
    end
    can_accept_one_next =
      (($clog2(2*ENTRIES+1)'(bank0_count_next) +
        $clog2(2*ENTRIES+1)'(bank1_count_next)) <
       $clog2(2*ENTRIES+1)'(CAPACITY));
    can_accept_two_next =
      (($clog2(2*ENTRIES+1)'(bank0_count_next) +
        $clog2(2*ENTRIES+1)'(bank1_count_next)) <=
       $clog2(2*ENTRIES+1)'(CAPACITY-2)) &&
      (bank0_count_next < BANK_COUNT_W'(ENTRIES)) &&
      (bank1_count_next < BANK_COUNT_W'(ENTRIES));
  end

  // One write per physical bank lets the immutable payload infer LUTRAM.
  always_ff @(posedge clk_i) begin
    // Valid bits guard payload reads; the payload RAM itself does not require
    // reset.  Keeping reset out of this write process prevents the dispatch
    // acceptance cone from mapping onto hundreds of payload reset pins.
    if (payload_bank0_we)
      payload_bank0_q[payload_bank0_waddr] <= payload_bank0_compact_wdata;
    if (payload_bank1_we)
      payload_bank1_q[payload_bank1_waddr] <= payload_bank1_compact_wdata;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      bank0_count_q <= '0;
      bank1_count_q <= '0;
      can_accept_one_q <= 1'b1;
      can_accept_two_q <= 1'b1;
      bank_alloc_prefer_q <= 1'b0;
      token_bank0_valid_q <= 1'b1;
      token_bank1_valid_q <= 1'b1;
      token_bank0_idx_q <= '0;
      token_bank1_idx_q <= '0;
      for (int unsigned i = 0; i < ENTRIES; i++) begin
        valid_bank0_q[i] <= 1'b0;
        valid_bank1_q[i] <= 1'b0;
        src1_ready_bank0_q[i] <= 1'b0;
        src1_ready_bank1_q[i] <= 1'b0;
        src2_ready_bank0_q[i] <= 1'b0;
        src2_ready_bank1_q[i] <= 1'b0;
        load_mem_ready_bank0_q[i] <= 1'b0;
        load_mem_ready_bank1_q[i] <= 1'b0;
        entry_ready_bank0_q[i] <= 1'b0;
        entry_ready_bank1_q[i] <= 1'b0;
      end
      for (int unsigned i = 0; i < CAPACITY; i++)
        older_mask_q[i] <= '0;
    end else if (recovery_valid_i) begin
      bank0_count_q <= bank0_count_next;
      bank1_count_q <= bank1_count_next;
      can_accept_one_q <= can_accept_one_next;
      can_accept_two_q <= can_accept_two_next;
      token_bank0_valid_q <= token_bank0_valid_next;
      token_bank1_valid_q <= token_bank1_valid_next;
      token_bank0_idx_q <= token_bank0_idx_next;
      token_bank1_idx_q <= token_bank1_idx_next;
      for (int unsigned i = 0; i < ENTRIES; i++) begin
        if (valid_bank0_q[i] &&
            rob_ptr_in_range(rob_ptr_bank0_q[i], recovery_start_i,
                             recovery_end_i)) begin
          valid_bank0_q[i] <= 1'b0;
          entry_ready_bank0_q[i] <= 1'b0;
        end
        // Wakeup state is irrelevant once valid clears, so update it for all
        // occupied rows without conditioning its D input on the recovery kill
        // mask.  This removes recovery-mask fanout from every readiness flop.
        else if (valid_bank0_q[i]) begin
          src1_ready_bank0_q[i] <= src1_ready_bank0_next[i];
          src2_ready_bank0_q[i] <= src2_ready_bank0_next[i];
          load_mem_ready_bank0_q[i] <= load_mem_ready_bank0_next[i];
          entry_ready_bank0_q[i] <= entry_ready_bank0_next[i];
        end
        if (valid_bank1_q[i] &&
            rob_ptr_in_range(rob_ptr_bank1_q[i], recovery_start_i,
                             recovery_end_i)) begin
          valid_bank1_q[i] <= 1'b0;
          entry_ready_bank1_q[i] <= 1'b0;
        end
        else if (valid_bank1_q[i]) begin
          src1_ready_bank1_q[i] <= src1_ready_bank1_next[i];
          src2_ready_bank1_q[i] <= src2_ready_bank1_next[i];
          load_mem_ready_bank1_q[i] <= load_mem_ready_bank1_next[i];
          entry_ready_bank1_q[i] <= entry_ready_bank1_next[i];
        end
      end
      if (issue_valid_o && issue_ready_i) begin
        if (issue_bank) begin
          valid_bank1_q[issue_idx] <= 1'b0;
          entry_ready_bank1_q[issue_idx] <= 1'b0;
        end else begin
          valid_bank0_q[issue_idx] <= 1'b0;
          entry_ready_bank0_q[issue_idx] <= 1'b0;
        end
      end
    end else begin
      token_bank0_valid_q <= token_bank0_valid_next;
      token_bank1_valid_q <= token_bank1_valid_next;
      token_bank0_idx_q <= token_bank0_idx_next;
      token_bank1_idx_q <= token_bank1_idx_next;
      bank0_count_q <= bank0_count_next;
      bank1_count_q <= bank1_count_next;
      can_accept_one_q <= can_accept_one_next;
      can_accept_two_q <= can_accept_two_next;
      if (payload_bank0_we ^ payload_bank1_we)
        bank_alloc_prefer_q <= payload_bank0_we;
      if (issue_valid_o && issue_ready_i) begin
        if (issue_bank) valid_bank1_q[issue_idx] <= 1'b0;
        else valid_bank0_q[issue_idx] <= 1'b0;
      end

      for (int unsigned i = 0; i < ENTRIES; i++) begin
        if (valid_bank0_q[i]) begin
          src1_ready_bank0_q[i] <= src1_ready_bank0_next[i];
          src2_ready_bank0_q[i] <= src2_ready_bank0_next[i];
          load_mem_ready_bank0_q[i] <= load_mem_ready_bank0_next[i];
          entry_ready_bank0_q[i] <= entry_ready_bank0_next[i];
        end
        if (valid_bank1_q[i]) begin
          src1_ready_bank1_q[i] <= src1_ready_bank1_next[i];
          src2_ready_bank1_q[i] <= src2_ready_bank1_next[i];
          load_mem_ready_bank1_q[i] <= load_mem_ready_bank1_next[i];
          entry_ready_bank1_q[i] <= entry_ready_bank1_next[i];
        end
      end

      // These assignments follow the generic occupied-row updates above so a
      // consumed row cannot be reasserted by a coincident wakeup event.
      if (issue_valid_o && issue_ready_i) begin
        if (issue_bank) entry_ready_bank1_q[issue_idx] <= 1'b0;
        else entry_ready_bank0_q[issue_idx] <= 1'b0;
      end

      if (payload_bank0_we) begin
        valid_bank0_q[payload_bank0_waddr] <= 1'b1;
        src1_ready_bank0_q[payload_bank0_waddr] <= payload_bank0_src1_ready;
        src2_ready_bank0_q[payload_bank0_waddr] <= payload_bank0_src2_ready;
        entry_ready_bank0_q[payload_bank0_waddr] <=
          payload_bank0_src1_ready && payload_bank0_src2_ready &&
          payload_bank0_mem_ready;
        rob_ptr_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.rob_ptr;
        ps1_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.ps1;
        ps2_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.ps2;
        pdst_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.pdst;
        fast_wakeup_bank0_q[payload_bank0_waddr] <=
          payload_bank0_wdata.rd_wen && !payload_bank0_wdata.is_load &&
          !payload_bank0_wdata.is_muldiv;
        uses_ps1_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.uses_ps1;
        uses_ps2_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.uses_ps2;
        is_load_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.is_load;
        lq_seq_bank0_q[payload_bank0_waddr] <= payload_bank0_wdata.lq_seq;
        load_mem_ready_bank0_q[payload_bank0_waddr] <= payload_bank0_mem_ready;
      end
      if (payload_bank1_we) begin
        valid_bank1_q[payload_bank1_waddr] <= 1'b1;
        src1_ready_bank1_q[payload_bank1_waddr] <= payload_bank1_src1_ready;
        src2_ready_bank1_q[payload_bank1_waddr] <= payload_bank1_src2_ready;
        entry_ready_bank1_q[payload_bank1_waddr] <=
          payload_bank1_src1_ready && payload_bank1_src2_ready &&
          payload_bank1_mem_ready;
        rob_ptr_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.rob_ptr;
        ps1_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.ps1;
        ps2_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.ps2;
        pdst_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.pdst;
        fast_wakeup_bank1_q[payload_bank1_waddr] <=
          payload_bank1_wdata.rd_wen && !payload_bank1_wdata.is_load &&
          !payload_bank1_wdata.is_muldiv;
        uses_ps1_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.uses_ps1;
        uses_ps2_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.uses_ps2;
        is_load_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.is_load;
        lq_seq_bank1_q[payload_bank1_waddr] <= payload_bank1_wdata.lq_seq;
        load_mem_ready_bank1_q[payload_bank1_waddr] <= payload_bank1_mem_ready;
      end

      // A newly allocated row is younger than every currently valid row.
      // Existing rows clear reused-slot columns so stale matrix state cannot
      // invert order after wrap. With dual allocation bank 0/lane 0 is older.
      for (int unsigned row = 0; row < CAPACITY; row++) begin
        if (payload_bank0_we && (row == int'(payload_bank0_waddr))) begin
          older_mask_q[row] <= valid_bitmap;
        end else if (payload_bank1_we &&
                     (row == (ENTRIES + int'(payload_bank1_waddr)))) begin
          older_mask_q[row] <= valid_bitmap |
            (payload_bank0_we
             ? (CAPACITY'(1) << payload_bank0_waddr) : '0);
        end else begin
          if (payload_bank0_we)
            older_mask_q[row][int'(payload_bank0_waddr)] <= 1'b0;
          if (payload_bank1_we)
            older_mask_q[row][ENTRIES + int'(payload_bank1_waddr)] <= 1'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial assert ((ENTRIES == 4) || (ENTRIES == 8))
    else $fatal(1, "banked issue queue supports ENTRIES=4 or ENTRIES=8");

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(dispatch_valid_i[1] && !dispatch_valid_i[0]))
        else $fatal(1, "issue queue lane1 dispatch requires lane0");
      assert (count_o <= $clog2(2*ENTRIES+1)'(CAPACITY))
        else $fatal(1, "issue queue overflow");
      assert (count_o == ($countones(valid_bitmap)))
        else $fatal(1, "issue queue occupancy diverged from valid bitmap");
      assert ((ready_bitmap & ~valid_bitmap) == '0)
        else $fatal(1, "issue queue selectable bit outlived its valid row");
      assert ($onehot0(oldest_ready_bitmap))
        else $fatal(1, "issue queue selected more than one global oldest row");
      assert (!(dispatch_valid_i[0] && !flush_i && !recovery_valid_i &&
                can_accept_one_q &&
                !dispatch_accept_o[0]))
        else $fatal(1, "issue queue rejected dispatch despite logical capacity");
      assert (!(dispatch_valid_i[1] &&
                can_accept_two_q &&
                !dispatch_accept_o[1]))
        else $fatal(1, "issue queue rejected dual dispatch despite logical capacity");
    end
  end
`endif
endmodule
