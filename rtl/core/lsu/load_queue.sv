`timescale 1ns/1ps
module load_queue #(
  parameter int unsigned ENTRIES = 8
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [1:0]                   alloc_valid_i,
  input  core_types_pkg::uop_id_t      alloc_uop_id_i [2],
  input  core_types_pkg::preg_t        alloc_pdst_i [2],
  input  logic [3:0]                   alloc_older_sq_tail_i [2],
  input  logic [7:0]                   alloc_older_addr_pending_i [2],
  output logic [1:0]                   alloc_accept_o,
  output logic [3:0]                   alloc_seq_o [2],

  input  logic [7:0]                   store_addr_done_onehot_i,
  output logic [7:0]                   mem_dep_ready_bitmap_o,
  output logic [7:0]                   mem_dep_ready_set_o,

  input  logic                         execute_valid_i,
  input  logic [3:0]                   execute_seq_i,
  input  core_types_pkg::uop_id_t      execute_uop_id_i,
  input  logic [31:0]                  execute_addr_i,
  input  rv32_pkg::mem_size_e          execute_size_i,
  input  logic                         execute_unsigned_i,
  input  logic [3:0]                   execute_older_sq_tail_i,
  input  logic [3:0]                   execute_forward_mask_i,
  input  logic [31:0]                  execute_forward_data_i,

  output logic                         request_valid_o,
  input  logic                         request_ready_i,
  output logic [31:0]                  request_addr_o,
  output logic [3:0]                   request_seq_o,
  output core_types_pkg::uop_id_t      request_uop_id_o,
  output logic [3:0]                   request_older_sq_tail_o,
  output logic                         request_fast_o,

  input  logic                         response_valid_i,
  input  logic [3:0]                   response_seq_i,
  input  core_types_pkg::uop_id_t      response_uop_id_i,
  input  logic [31:0]                  response_data_i,
  input  logic                         response_error_i,

  output logic                         wb_valid_o,
  input  logic                         wb_ready_i,
  output core_types_pkg::uop_id_t      wb_uop_id_o,
  output core_types_pkg::preg_t        wb_pdst_o,
  output logic [31:0]                  wb_data_o,
  output logic                         wb_error_o,
  output logic [31:0]                  wb_fault_addr_o,
  output logic                         wakeup_valid_o,
  output core_types_pkg::preg_t        wakeup_pdst_o,

  input  logic [1:0]                   release_valid_i,
  input  logic [3:0]                   release_seq_i [2],
  input  logic                         recovery_valid_i,
  input  logic [3:0]                   recovery_alloc_tail_i,

  output logic [3:0]                   head_o,
  output logic [3:0]                   alloc_tail_o,
  output logic [3:0]                   count_o,
  output logic                         empty_o
);
  import core_types_pkg::*;
  import rv32_pkg::*;

  localparam int unsigned INDEX_W = $clog2(ENTRIES);
  localparam logic [3:0] ENTRY_COUNT = 4'(ENTRIES);

  typedef struct packed {
    logic        valid;
    logic        addr_ready;
    logic        issued;
    logic        response_ready;
    logic        done;
    logic [3:0]  seq;
    uop_id_t     uop_id;
    preg_t       pdst;
    logic [3:0]  older_sq_tail;
    logic [7:0]  older_addr_pending;
    logic [31:0] addr;
    mem_size_e   size;
    logic        mem_unsigned;
    logic [3:0]  load_mask;
    logic [3:0]  forward_mask;
    logic [31:0] forward_data;
    logic [31:0] response_data;
    logic        response_error;
  } lq_entry_t;

  // Allocation owns only identity/dependency state.  Address, forwarding,
  // and response payloads have later single producers and are deliberately
  // unreset, so dispatch cannot fan out into every wide LQ storage bit.
  logic valid_q [ENTRIES];
  logic addr_ready_q [ENTRIES];
  logic issued_q [ENTRIES];
  logic response_ready_q [ENTRIES];
  logic done_q [ENTRIES];
  logic [3:0] seq_q [ENTRIES];
  uop_id_t uop_id_q [ENTRIES];
  preg_t pdst_q [ENTRIES];
  logic [3:0] older_sq_tail_q [ENTRIES];
  logic [7:0] older_addr_pending_q [ENTRIES];
  logic [ENTRIES-1:0] mem_dep_ready_q;
  (* ram_style = "distributed" *) logic [31:0] addr_q [ENTRIES];
  logic [ENTRIES-1:0] mem_unsigned_q;
  mem_size_e size_q [ENTRIES];
  logic [3:0] load_mask_q [ENTRIES];
  logic [3:0] forward_mask_q [ENTRIES];
  (* ram_style = "distributed" *) logic [31:0] forward_data_q [ENTRIES];
  (* ram_style = "distributed" *) logic [31:0] response_data_q [ENTRIES];
  logic response_error_q [ENTRIES];
  logic [3:0] head_q, alloc_tail_q;
  logic [3:0] occupancy;
  logic [1:0] release_count, alloc_count;
  logic [3:0] tail_after_lane0, head_after_release;
  logic [3:0] removed_count;
  logic request_fire, wb_fire;
  logic request_from_execute, execute_request_candidate;
  logic request_q_valid;
  logic [31:0] request_q_addr;
  logic [3:0] request_q_seq;
  uop_id_t request_q_uop_id;
  logic [3:0] request_q_older_sq_tail;
  logic request_q_consumed, request_q_can_fill, request_q_capture;
  logic request_q_capture_execute;
  logic request_q_killed;
  logic response_match, wb_from_response;
  logic [2:0] execute_index, response_index;
  logic [3:0] execute_load_mask;

  // Store forwarding is produced by the EX1 address/SQ compare cone.  Capture
  // it in this one-entry sidecar first, then copy it to the indexed payload
  // arrays on the following edge.  A cache hit returns no earlier than that
  // following cycle, where the sidecar bypass supplies the same data, so this
  // removes the long EX1 -> SQ -> distributed-RAM write path without adding a
  // load-use or cache-hit cycle.
  logic forward_pipe_valid_q;
  logic [3:0] forward_pipe_seq_q;
  uop_id_t forward_pipe_uop_id_q;
  logic [3:0] forward_pipe_mask_q;
  logic [31:0] forward_pipe_data_q;
  logic forward_pipe_response_match, forward_pipe_wb_match;
  logic [3:0] response_forward_mask, wb_forward_mask;
  logic [31:0] response_forward_data, wb_forward_data;

  logic [ENTRIES-1:0] req_bitmap, wb_bitmap;
  logic [(2*ENTRIES)-1:0] req_doubled, wb_doubled;
  logic [ENTRIES-1:0] req_rotated, wb_rotated;
  logic [ENTRIES-1:0] req_grant_rotated, wb_grant_rotated;
  logic [INDEX_W-1:0] req_offset, wb_offset;
  logic [INDEX_W-1:0] req_index, wb_index;
  logic req_candidate_valid, wb_candidate_valid;
  lq_entry_t request_entry, wb_candidate_entry, wb_entry;
  lq_entry_t response_entry;
  logic [31:0] wb_merged_word, response_merged_word;
  // A queued completion is selected into this narrow index boundary before
  // its wide payload is read.  A newly returning cache response still uses the
  // direct fast path; only already-buffered/forwarded completions take this
  // extra arbitration boundary.
  logic wb_q_valid, wb_q_capture, wb_q_can_fill, wb_q_killed;
  logic [INDEX_W-1:0] wb_q_index;
  logic [3:0] wb_q_seq;
  uop_id_t wb_q_uop_id;

  function automatic logic [3:0] load_byte_mask(
    input mem_size_e size,
    input logic [1:0] offset
  );
    unique case (size)
      MEM_SIZE_B: return 4'b0001 << offset;
      MEM_SIZE_H: return offset[1] ? 4'b1100 : 4'b0011;
      default:    return 4'b1111;
    endcase
  endfunction

  function automatic logic [31:0] extend_load(
    input logic [31:0] word,
    input logic [1:0] offset,
    input mem_size_e size,
    input logic is_unsigned
  );
    logic [7:0] byte_value;
    logic [15:0] half_value;
    byte_value = word[offset*8 +: 8];
    half_value = offset[1] ? word[31:16] : word[15:0];
    unique case (size)
      MEM_SIZE_B: return is_unsigned ? {24'b0, byte_value}
                                    : {{24{byte_value[7]}}, byte_value};
      MEM_SIZE_H: return is_unsigned ? {16'b0, half_value}
                                    : {{16{half_value[15]}}, half_value};
      default:    return word;
    endcase
  endfunction

  function automatic lq_entry_t read_entry(
    input logic [INDEX_W-1:0] index
  );
    lq_entry_t entry;
    entry = '0;
    entry.valid = valid_q[index];
    entry.addr_ready = addr_ready_q[index];
    entry.issued = issued_q[index];
    entry.response_ready = response_ready_q[index];
    entry.done = done_q[index];
    entry.seq = seq_q[index];
    entry.uop_id = uop_id_q[index];
    entry.pdst = pdst_q[index];
    entry.older_sq_tail = older_sq_tail_q[index];
    entry.older_addr_pending = older_addr_pending_q[index];
    entry.addr = addr_q[index];
    entry.size = size_q[index];
    entry.mem_unsigned = mem_unsigned_q[index];
    entry.load_mask = load_mask_q[index];
    entry.forward_mask = forward_mask_q[index];
    entry.forward_data = forward_data_q[index];
    entry.response_data = response_data_q[index];
    entry.response_error = response_error_q[index];
    return entry;
  endfunction

  assign occupancy = alloc_tail_q - head_q;
  assign mem_dep_ready_bitmap_o = mem_dep_ready_q;
  always_comb begin
    mem_dep_ready_set_o = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      mem_dep_ready_set_o[i] = valid_q[i] && !mem_dep_ready_q[i] &&
        !(|(older_addr_pending_q[i] & ~store_addr_done_onehot_i));
    end
  end
  assign request_fire = request_valid_o && request_ready_i;
  assign wb_fire = wb_valid_o && wb_ready_i;
  assign request_q_killed = request_q_valid &&
    ((request_q_seq - recovery_alloc_tail_i) < removed_count);

  assign response_index = response_seq_i[INDEX_W-1:0];
  always_comb response_entry = read_entry(response_index);
  assign response_match = response_valid_i && response_entry.valid &&
                          (response_entry.seq == response_seq_i) &&
                          (response_entry.uop_id == response_uop_id_i) &&
                          response_entry.issued &&
                          !response_entry.response_ready &&
                          !response_entry.done;
  assign execute_index = execute_seq_i[INDEX_W-1:0];
  assign execute_load_mask = load_byte_mask(execute_size_i,
                                             execute_addr_i[1:0]);
  // EX1 is an elastic single-consumer stage and the core suppresses it during
  // recovery.  Re-reading a dynamically indexed LQ entry merely to validate
  // the uop rebuilt a LUTRAM mux and identity comparator in the cache request
  // cone.  Likewise, deciding whether SQ forwarding covers every byte must
  // not feed request valid: doing so would pull the complete SQ compare/data
  // forwarding network into the D-cache admission cone.  A fully forwarded
  // load may therefore launch a harmless redundant read; its LQ entry is
  // already complete and rejects the eventual response by identity/state.
  // State writes below retain their local identity guard.
  assign execute_request_candidate = execute_valid_i;
  always_comb begin : select_lq_entries
    release_count = {1'b0, release_valid_i[0]} + {1'b0, release_valid_i[1]};
    head_after_release = head_q + {2'b0, release_count};
    alloc_accept_o = '0;
    alloc_seq_o[0] = alloc_tail_q;
    if (!recovery_valid_i && alloc_valid_i[0] &&
        (occupancy < ENTRY_COUNT))
      alloc_accept_o[0] = 1'b1;
    tail_after_lane0 = alloc_tail_q + {3'b0, alloc_accept_o[0]};
    alloc_seq_o[1] = tail_after_lane0;
    if (!recovery_valid_i && alloc_valid_i[1] &&
        ((occupancy + {3'b0, alloc_accept_o[0]}) < ENTRY_COUNT))
      alloc_accept_o[1] = 1'b1;
    alloc_count = {1'b0, alloc_accept_o[0]} + {1'b0, alloc_accept_o[1]};
    removed_count = alloc_tail_q - recovery_alloc_tail_i;
  end

  always_comb begin
    req_bitmap = '0;
    wb_bitmap = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      req_bitmap[i] = valid_q[i] && addr_ready_q[i] && !issued_q[i] &&
                      !response_ready_q[i] && !done_q[i] &&
                      !(|older_addr_pending_q[i]) &&
                      ((forward_mask_q[i] & load_mask_q[i]) != load_mask_q[i]);

      wb_bitmap[i] = valid_q[i] && response_ready_q[i] && !done_q[i];
    end

    // Physical slots wrap every eight allocations.  Rotate both ready maps so
    // bit zero is the architectural LQ head, then isolate the first set bit.
    // This preserves oldest-ready order without per-entry ROB-age subtractors
    // and prevents a younger slot-zero MMIO load from starving a head in slot 7.
    req_doubled = {req_bitmap, req_bitmap};
    wb_doubled = {wb_bitmap, wb_bitmap};
    req_rotated = req_doubled[{1'b0, head_q[INDEX_W-1:0]} +: ENTRIES];
    wb_rotated = wb_doubled[{1'b0, head_q[INDEX_W-1:0]} +: ENTRIES];
    req_grant_rotated = req_rotated & (~req_rotated + 1'b1);
    wb_grant_rotated = wb_rotated & (~wb_rotated + 1'b1);
    req_candidate_valid = |req_rotated;
    wb_candidate_valid = |wb_rotated;
    req_offset = '0;
    wb_offset = '0;
    for (int unsigned i = 0; i < ENTRIES; i++) begin
      if (req_grant_rotated[i]) req_offset = i[INDEX_W-1:0];
      if (wb_grant_rotated[i]) wb_offset = i[INDEX_W-1:0];
    end
    req_index = head_q[INDEX_W-1:0] + req_offset;
    wb_index = head_q[INDEX_W-1:0] + wb_offset;
    request_entry = read_entry(req_index);
    wb_candidate_entry = read_entry(wb_index);
    wb_entry = read_entry(wb_q_index);
  end

  assign wb_q_can_fill = !wb_q_valid || (wb_q_valid && wb_ready_i &&
                                          !recovery_valid_i);
  assign wb_q_capture = wb_q_can_fill && wb_candidate_valid &&
                        !recovery_valid_i;
  assign wb_q_killed = wb_q_valid && recovery_valid_i &&
                       ((wb_q_seq - recovery_alloc_tail_i) < removed_count);

  // Request-state ownership may depend on downstream ready, but the outward
  // valid/address channel below does not.  Keeping these cones separate makes
  // the valid/ready protocol acyclic both structurally and to synthesis/lint.
  always_comb begin : update_request_state
    // The normal oldest-ready scan terminates at a one-entry request register;
    // it no longer drives the cache, dmem FIFO and peripheral decode directly.
    // Preserve the common hit path by allowing a newly executed dependency-
    // clean load to bypass whenever the request register is empty.  The IQ
    // already admits a load only after its registered older-store dependency
    // mask is clear, so re-reading that mask here duplicated the LQ scan in
    // the cache-valid cone.  If an older scanned request exists concurrently,
    // capture it into request_q while the just-executed load uses the port.
    // Backpressure gives the executing load ownership of request_q and leaves
    // the scanned request unissued for the next cycle.
    request_q_consumed = request_q_valid && request_ready_i &&
                          !recovery_valid_i;
    request_q_can_fill = !request_q_valid || request_q_consumed;
    request_from_execute = execute_request_candidate && !request_q_valid &&
                           !recovery_valid_i;
    request_q_capture_execute = request_from_execute && !request_ready_i;
    request_q_capture = request_q_can_fill && req_candidate_valid &&
                        !request_q_capture_execute && !recovery_valid_i;
  end

  always_comb begin : drive_request_channel
    request_valid_o = !recovery_valid_i &&
                      (request_q_valid || request_from_execute);
    request_addr_o = request_from_execute ? execute_addr_i : request_q_addr;
    request_seq_o = request_from_execute ? execute_seq_i : request_q_seq;
    request_uop_id_o = request_from_execute ? execute_uop_id_i
                                            : request_q_uop_id;
    request_older_sq_tail_o = request_from_execute
                            ? execute_older_sq_tail_i
                            : request_q_older_sq_tail;
    // Identify the direct EX1 request independently of the payload mux.  The
    // SoC can use the matching EX-local address/identity to start a cache read
    // without dragging the queued-request selector through the D-cache.
    request_fast_o = !recovery_valid_i && request_from_execute;
  end

  always_comb begin : drive_writeback_channel
    forward_pipe_response_match = forward_pipe_valid_q &&
      (forward_pipe_seq_q == response_seq_i) &&
      (forward_pipe_uop_id_q == response_uop_id_i);
    forward_pipe_wb_match = forward_pipe_valid_q &&
      (forward_pipe_seq_q == wb_entry.seq) &&
      (forward_pipe_uop_id_q == wb_entry.uop_id);
    response_forward_mask = forward_pipe_response_match
      ? forward_pipe_mask_q : response_entry.forward_mask;
    response_forward_data = forward_pipe_response_match
      ? forward_pipe_data_q : response_entry.forward_data;
    wb_forward_mask = forward_pipe_wb_match
      ? forward_pipe_mask_q : wb_entry.forward_mask;
    wb_forward_data = forward_pipe_wb_match
      ? forward_pipe_data_q : wb_entry.forward_data;

    wb_merged_word = wb_entry.response_data;
    for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
      if (wb_forward_mask[byte_idx])
        wb_merged_word[byte_idx*8 +: 8] =
          wb_forward_data[byte_idx*8 +: 8];
    end
    response_merged_word = response_data_i;
    for (int unsigned byte_idx = 0; byte_idx < 4; byte_idx++) begin
      if (response_forward_mask[byte_idx])
        response_merged_word[byte_idx*8 +: 8] =
          response_forward_data[byte_idx*8 +: 8];
    end
    wb_from_response = response_match && !wb_q_valid;
    wb_valid_o = !recovery_valid_i &&
                 (wb_q_valid || response_match);
    wb_uop_id_o = wb_from_response ? response_entry.uop_id : wb_q_uop_id;
    wb_pdst_o = wb_from_response ? response_entry.pdst : wb_entry.pdst;
    wb_data_o = wb_from_response
      ? extend_load(response_merged_word, response_entry.addr[1:0],
                    response_entry.size, response_entry.mem_unsigned)
      : extend_load(wb_merged_word, wb_entry.addr[1:0],
                    wb_entry.size, wb_entry.mem_unsigned);
    wb_error_o = wb_from_response ? response_error_i
                                  : wb_entry.response_error;
    wb_fault_addr_o = wb_from_response ? response_entry.addr : wb_entry.addr;
  end

  // Publish the identity of the actual writeback transaction.  The SoC uses
  // the registered PRF write boundary for global wakeup; these outputs remain
  // available for local verification and compatibility.
  always_comb begin
    wakeup_valid_o = 1'b0;
    wakeup_pdst_o = '0;
    if (!recovery_valid_i) begin
      if (wb_q_valid) begin
        wakeup_pdst_o = wb_entry.pdst;
        wakeup_valid_o = !wb_entry.response_error &&
                         (wb_entry.pdst != '0);
      end else if (response_match) begin
        wakeup_pdst_o = pdst_q[response_index];
        wakeup_valid_o = !response_error_i &&
                         (pdst_q[response_index] != '0);
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      head_q <= '0;
      alloc_tail_q <= '0;
      request_q_valid <= 1'b0;
      request_q_addr <= '0;
      request_q_seq <= '0;
      request_q_uop_id <= '0;
      request_q_older_sq_tail <= '0;
      wb_q_valid <= 1'b0;
      wb_q_index <= '0;
      wb_q_seq <= '0;
      wb_q_uop_id <= '0;
      forward_pipe_valid_q <= 1'b0;
      forward_pipe_seq_q <= '0;
      forward_pipe_uop_id_q <= '0;
      forward_pipe_mask_q <= '0;
      forward_pipe_data_q <= '0;
      mem_dep_ready_q <= '0;
      for (int unsigned i = 0; i < ENTRIES; i++) begin
        valid_q[i] <= 1'b0;
        addr_ready_q[i] <= 1'b0;
        issued_q[i] <= 1'b0;
        response_ready_q[i] <= 1'b0;
        done_q[i] <= 1'b0;
        older_addr_pending_q[i] <= '0;
      end
    end else begin
      // A branch-recovery pulse may coincide with an older surviving load in
      // EX1.  Capture unconditionally; the following identity/valid guard
      // discards a killed load after recovery truncates the queue.
      forward_pipe_valid_q <= execute_valid_i;
      if (execute_valid_i) begin
        forward_pipe_seq_q <= execute_seq_i;
        forward_pipe_uop_id_q <= execute_uop_id_i;
        forward_pipe_mask_q <= execute_forward_mask_i;
        forward_pipe_data_q <= execute_forward_data_i;
      end
      if (forward_pipe_valid_q &&
          valid_q[forward_pipe_seq_q[INDEX_W-1:0]] &&
          (seq_q[forward_pipe_seq_q[INDEX_W-1:0]] == forward_pipe_seq_q) &&
          (uop_id_q[forward_pipe_seq_q[INDEX_W-1:0]] ==
           forward_pipe_uop_id_q)) begin
        forward_mask_q[forward_pipe_seq_q[INDEX_W-1:0]] <=
          forward_pipe_mask_q;
        forward_data_q[forward_pipe_seq_q[INDEX_W-1:0]] <=
          forward_pipe_data_q;
      end

      for (int unsigned i = 0; i < ENTRIES; i++) begin
        if (valid_q[i]) begin
          older_addr_pending_q[i] <=
            older_addr_pending_q[i] & ~store_addr_done_onehot_i;
          // Publish a registered physical-slot readiness bit on the same edge
          // that removes the final older-store dependency.  IQ selection no
          // longer performs an eight-bit reduction for every load candidate.
          mem_dep_ready_q[i] <=
            !(|(older_addr_pending_q[i] & ~store_addr_done_onehot_i));
        end
      end

      if (execute_valid_i &&
          valid_q[execute_seq_i[INDEX_W-1:0]] &&
          (seq_q[execute_seq_i[INDEX_W-1:0]] == execute_seq_i) &&
          (uop_id_q[execute_seq_i[INDEX_W-1:0]] == execute_uop_id_i)) begin
        addr_ready_q[execute_seq_i[INDEX_W-1:0]] <= 1'b1;
        addr_q[execute_seq_i[INDEX_W-1:0]] <= execute_addr_i;
        size_q[execute_seq_i[INDEX_W-1:0]] <= execute_size_i;
        mem_unsigned_q[execute_seq_i[INDEX_W-1:0]] <= execute_unsigned_i;
        load_mask_q[execute_seq_i[INDEX_W-1:0]] <=
          load_byte_mask(execute_size_i, execute_addr_i[1:0]);
        if ((execute_forward_mask_i &
             execute_load_mask) == execute_load_mask) begin
          response_ready_q[execute_seq_i[INDEX_W-1:0]] <= 1'b1;
          // All requested bytes are supplied by the forwarding sidecar, so
          // response_data is a don't-care.  Writing a cosmetic zero here made
          // EX1 address/mask selection drive every bit of this distributed
          // RAM and created the dominant EX1 -> LQ setup family.
          response_error_q[execute_seq_i[INDEX_W-1:0]] <= 1'b0;
        end
      end

      if (request_q_consumed && !request_q_capture)
        request_q_valid <= 1'b0;
      if (request_q_capture) begin
        request_q_valid <= 1'b1;
        request_q_addr <= request_entry.addr;
        request_q_seq <= request_entry.seq;
        request_q_uop_id <= request_entry.uop_id;
        request_q_older_sq_tail <= request_entry.older_sq_tail;
        // Ownership transfers to the request register at capture, rather than
        // at downstream acceptance, preventing the scan from selecting it twice.
        issued_q[req_index] <= 1'b1;
      end
      if (request_q_capture_execute) begin
        request_q_valid <= 1'b1;
        request_q_addr <= execute_addr_i;
        request_q_seq <= execute_seq_i;
        request_q_uop_id <= execute_uop_id_i;
        request_q_older_sq_tail <= execute_older_sq_tail_i;
        issued_q[execute_index] <= 1'b1;
      end
      if (request_fire && request_from_execute)
        issued_q[execute_index] <= 1'b1;
      if (response_match && !(wb_from_response && wb_ready_i)) begin
        response_ready_q[response_index] <= 1'b1;
        response_data_q[response_index] <= response_data_i;
        response_error_q[response_index] <= response_error_i;
      end

      if (wb_q_valid && wb_ready_i)
        wb_q_valid <= 1'b0;
      if (wb_q_capture) begin
        wb_q_valid <= 1'b1;
        wb_q_index <= wb_index;
        wb_q_seq <= wb_candidate_entry.seq;
        wb_q_uop_id <= wb_candidate_entry.uop_id;
        // Ownership moves from the response-ready map to wb_q.  The payload
        // arrays remain unchanged and are addressed by the registered index.
        response_ready_q[wb_index] <= 1'b0;
      end

      if (wb_fire) begin
        if (wb_from_response) begin
          response_ready_q[response_index] <= 1'b0;
          done_q[response_index] <= 1'b1;
        end else begin
          done_q[wb_q_index] <= 1'b1;
        end
      end

      if (release_valid_i[0]) begin
        valid_q[release_seq_i[0][INDEX_W-1:0]] <= 1'b0;
        mem_dep_ready_q[release_seq_i[0][INDEX_W-1:0]] <= 1'b0;
      end
      if (release_valid_i[1]) begin
        valid_q[release_seq_i[1][INDEX_W-1:0]] <= 1'b0;
        mem_dep_ready_q[release_seq_i[1][INDEX_W-1:0]] <= 1'b0;
      end
      head_q <= head_after_release;

      if (recovery_valid_i) begin
        alloc_tail_q <= recovery_alloc_tail_i;
        if (request_q_killed)
          request_q_valid <= 1'b0;
        if (wb_q_killed)
          wb_q_valid <= 1'b0;
        for (int unsigned i = 0; i < ENTRIES; i++) begin
          logic [3:0] from_recovery;
          from_recovery = seq_q[i] - recovery_alloc_tail_i;
          if (valid_q[i] && (from_recovery < removed_count)) begin
            valid_q[i] <= 1'b0;
            mem_dep_ready_q[i] <= 1'b0;
          end
        end
      end else begin
        alloc_tail_q <= alloc_tail_q + {2'b0, alloc_count};
        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (alloc_accept_o[lane]) begin
            valid_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b1;
            addr_ready_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b0;
            issued_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b0;
            response_ready_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b0;
            done_q[alloc_seq_o[lane][INDEX_W-1:0]] <= 1'b0;
            seq_q[alloc_seq_o[lane][INDEX_W-1:0]] <= alloc_seq_o[lane];
            uop_id_q[alloc_seq_o[lane][INDEX_W-1:0]] <= alloc_uop_id_i[lane];
            pdst_q[alloc_seq_o[lane][INDEX_W-1:0]] <= alloc_pdst_i[lane];
            older_sq_tail_q[alloc_seq_o[lane][INDEX_W-1:0]] <=
              alloc_older_sq_tail_i[lane];
            older_addr_pending_q[alloc_seq_o[lane][INDEX_W-1:0]] <=
              alloc_older_addr_pending_i[lane] & ~store_addr_done_onehot_i;
            mem_dep_ready_q[alloc_seq_o[lane][INDEX_W-1:0]] <=
              !(|(alloc_older_addr_pending_i[lane] &
                   ~store_addr_done_onehot_i));
          end
        end
      end
    end
  end

  assign head_o = head_q;
  assign alloc_tail_o = alloc_tail_q;
  assign count_o = occupancy;
  assign empty_o = (head_q == alloc_tail_q);

`ifndef SYNTHESIS
  initial assert (ENTRIES == 8) else $fatal(1, "LQ requires exactly 8 entries");
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (occupancy <= ENTRY_COUNT) else $fatal(1, "LQ occupancy overflow");
      assert (!(release_valid_i[1] && !release_valid_i[0]))
        else $fatal(1, "LQ lane1 release requires lane0 release");
      if (release_valid_i[0]) begin
        assert (release_seq_i[0] == head_q &&
                valid_q[release_seq_i[0][INDEX_W-1:0]] &&
                done_q[release_seq_i[0][INDEX_W-1:0]])
          else $fatal(1, "LQ released a non-head or incomplete load");
      end
      if (release_valid_i[1]) begin
        assert (release_seq_i[1] == (head_q + 1'b1) &&
                valid_q[release_seq_i[1][INDEX_W-1:0]] &&
                done_q[release_seq_i[1][INDEX_W-1:0]])
          else $fatal(1, "LQ second release was not consecutive");
      end
      if (recovery_valid_i)
        assert ((recovery_alloc_tail_i - head_after_release) <= ENTRY_COUNT)
          else $fatal(1, "LQ recovery tail is outside live window");
      if (wb_q_valid) begin
        assert (valid_q[wb_q_index] &&
                (seq_q[wb_q_index] == wb_q_seq) &&
                (uop_id_q[wb_q_index] == wb_q_uop_id) &&
                !done_q[wb_q_index])
          else $fatal(1, "LQ queued writeback lost entry ownership");
      end
    end
  end
`endif
endmodule
