`timescale 1ns/1ps
package backend_types_pkg;
  import rv32_pkg::*;
  import core_types_pkg::*;

  typedef struct packed {
    logic        valid;
    uop_op_e     op;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [31:0] imm;
    logic [11:0] csr_addr;
    rob_ptr_t    rob_ptr;
    uop_id_t     uop_id;
    preg_t       ps1;
    preg_t       ps2;
    preg_t       pdst;
    logic        uses_ps1;
    logic        uses_ps2;
    logic        rd_wen;
    logic        is_branch;
    logic        is_jump;
    logic        is_load;
    logic        is_store;
    logic        is_muldiv;
    logic        is_csr;
    mem_size_e   mem_size;
    logic        mem_unsigned;
    logic [3:0]  lq_seq;
    logic [3:0]  sq_seq;
    logic [3:0]  older_sq_tail;
    logic [31:0] predicted_pc;
    logic [3:0]  recovery_lq_tail;
    logic [3:0]  recovery_sq_tail;
    logic        fetch_fault;
  } issue_entry_t;
endpackage
