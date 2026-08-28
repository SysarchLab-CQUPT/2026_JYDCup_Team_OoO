`timescale 1ns/1ps
package core_types_pkg;
  import soc_cfg_pkg::*;

  typedef logic [ROB_PTR_W-1:0] rob_ptr_t;
  typedef logic [UOP_ID_W-1:0] uop_id_t;
  typedef logic [PREG_W-1:0] preg_t;

  typedef struct packed {
    logic        valid;
    logic        done;
    rob_ptr_t    rob_ptr;
    uop_id_t     uop_id;
    logic [31:0] pc;
    logic [31:0] inst;
    logic        rd_wen;
    logic [4:0]  rd_addr;
    preg_t       pdst;
    preg_t       stale_pdst;
    logic [31:0] result;
    logic        exception;
    logic [31:0] cause;
    logic [31:0] tval;
  } rob_entry_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
    logic        rd_wen;
    logic [4:0]  rd_addr;
    logic [31:0] rd_data;
    logic        mem_wen;
    logic [31:0] mem_addr;
    logic [31:0] mem_data;
    logic [3:0]  mem_mask;
    logic        exception;
    logic [31:0] cause;
    logic [31:0] tval;
  } commit_trace_t;

  function automatic rob_ptr_t rob_ptr_add(
    input rob_ptr_t ptr,
    input logic [1:0] amount
  );
    rob_ptr_add = ptr + rob_ptr_t'(amount);
  endfunction

  function automatic rob_ptr_t rob_distance(
    input rob_ptr_t ptr,
    input rob_ptr_t head
  );
    rob_distance = ptr - head;
  endfunction

  function automatic logic rob_ptr_inflight(
    input rob_ptr_t ptr,
    input rob_ptr_t head
  );
    rob_ptr_inflight = (rob_distance(ptr, head) < rob_ptr_t'(ROB_ENTRIES));
  endfunction

  function automatic logic rob_older(
    input rob_ptr_t lhs,
    input rob_ptr_t rhs,
    input rob_ptr_t head
  );
    rob_older = rob_distance(lhs, head) < rob_distance(rhs, head);
  endfunction

  // Modular half-open interval test used by branch recovery consumers.  The
  // ROB never contains more than ROB_ENTRIES live slots, so the distance from
  // start to end is unambiguous across the single wrap bit.
  function automatic logic rob_ptr_in_range(
    input rob_ptr_t ptr,
    input rob_ptr_t start_ptr,
    input rob_ptr_t end_ptr
  );
    rob_ptr_in_range = rob_distance(ptr, start_ptr) <
                       rob_distance(end_ptr, start_ptr);
  endfunction

  function automatic logic [ROB_INDEX_W-1:0] rob_index(input rob_ptr_t ptr);
    rob_index = ptr[ROB_INDEX_W-1:0];
  endfunction

  function automatic rob_ptr_t uop_rob_ptr(input uop_id_t id);
    uop_rob_ptr = id[ROB_PTR_W-1:0];
  endfunction
endpackage
