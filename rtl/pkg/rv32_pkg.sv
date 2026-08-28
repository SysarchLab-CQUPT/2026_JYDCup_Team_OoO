`timescale 1ns/1ps
package rv32_pkg;
  typedef enum logic [5:0] {
    UOP_ILLEGAL,
    UOP_LUI, UOP_AUIPC, UOP_JAL, UOP_JALR,
    UOP_BEQ, UOP_BNE, UOP_BLT, UOP_BGE, UOP_BLTU, UOP_BGEU,
    UOP_LB, UOP_LH, UOP_LW, UOP_LBU, UOP_LHU,
    UOP_SB, UOP_SH, UOP_SW,
    UOP_ADDI, UOP_SLTI, UOP_SLTIU, UOP_XORI, UOP_ORI, UOP_ANDI,
    UOP_SLLI, UOP_SRLI, UOP_SRAI,
    UOP_ADD, UOP_SUB, UOP_SLL, UOP_SLT, UOP_SLTU,
    UOP_XOR, UOP_SRL, UOP_SRA, UOP_OR, UOP_AND,
    UOP_SH1ADD, UOP_SH2ADD, UOP_SH3ADD,
    UOP_MUL, UOP_MULH, UOP_MULHSU, UOP_MULHU,
    UOP_DIV, UOP_DIVU, UOP_REM, UOP_REMU,
    UOP_FENCE, UOP_FENCEI,
    UOP_CSRRW, UOP_CSRRS, UOP_CSRRC,
    UOP_CSRRWI, UOP_CSRRSI, UOP_CSRRCI,
    UOP_ECALL, UOP_EBREAK, UOP_MRET,
    UOP_CRC16, UOP_STATE_STEP, UOP_CRC32
  } uop_op_e;

  typedef enum logic [1:0] {
    MEM_SIZE_B = 2'd0,
    MEM_SIZE_H = 2'd1,
    MEM_SIZE_W = 2'd2
  } mem_size_e;

  typedef struct packed {
    logic        valid;
    logic        illegal;
    uop_op_e     op;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic [31:0] imm;
    logic [11:0] csr_addr;
    logic        uses_rs1;
    logic        uses_rs2;
    logic        rd_wen;
    logic        is_branch;
    logic        is_jump;
    logic        is_load;
    logic        is_store;
    logic        is_muldiv;
    logic        is_accel;
    logic        is_csr;
    logic        is_serializing;
    mem_size_e   mem_size;
    logic        mem_unsigned;
  } decoded_instr_t;

  function automatic logic is_mul_op(input uop_op_e op);
    return op inside {UOP_MUL, UOP_MULH, UOP_MULHSU, UOP_MULHU};
  endfunction

  function automatic logic is_div_op(input uop_op_e op);
    return op inside {UOP_DIV, UOP_DIVU, UOP_REM, UOP_REMU};
  endfunction
endpackage
