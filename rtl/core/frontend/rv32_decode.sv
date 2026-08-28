`timescale 1ns/1ps
module rv32_decode (
  input  logic [31:0]                 inst_i,
  output rv32_pkg::decoded_instr_t    dec_o
);
  import rv32_pkg::*;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [31:0] imm_i;
  logic [31:0] imm_s;
  logic [31:0] imm_b;
  logic [31:0] imm_u;
  logic [31:0] imm_j;

  always_comb begin
    opcode = inst_i[6:0];
    funct3 = inst_i[14:12];
    funct7 = inst_i[31:25];
    imm_i = {{20{inst_i[31]}}, inst_i[31:20]};
    imm_s = {{20{inst_i[31]}}, inst_i[31:25], inst_i[11:7]};
    imm_b = {{19{inst_i[31]}}, inst_i[31], inst_i[7],
             inst_i[30:25], inst_i[11:8], 1'b0};
    imm_u = {inst_i[31:12], 12'b0};
    imm_j = {{11{inst_i[31]}}, inst_i[31], inst_i[19:12],
             inst_i[20], inst_i[30:21], 1'b0};

    dec_o = '0;
    dec_o.valid = 1'b1;
    dec_o.illegal = 1'b0;
    dec_o.op = UOP_ILLEGAL;
    dec_o.rs1 = inst_i[19:15];
    dec_o.rs2 = inst_i[24:20];
    dec_o.rd = inst_i[11:7];
    dec_o.csr_addr = inst_i[31:20];
    dec_o.mem_size = MEM_SIZE_W;

    unique case (opcode)
      7'b0110111: begin
        dec_o.op = UOP_LUI;
        dec_o.imm = imm_u;
        dec_o.rd_wen = (dec_o.rd != 0);
      end
      7'b0010111: begin
        dec_o.op = UOP_AUIPC;
        dec_o.imm = imm_u;
        dec_o.rd_wen = (dec_o.rd != 0);
      end
      7'b1101111: begin
        dec_o.op = UOP_JAL;
        dec_o.imm = imm_j;
        dec_o.rd_wen = (dec_o.rd != 0);
        dec_o.is_jump = 1'b1;
      end
      7'b1100111: begin
        if (funct3 == 3'b000) begin
          dec_o.op = UOP_JALR;
          dec_o.imm = imm_i;
          dec_o.uses_rs1 = 1'b1;
          dec_o.rd_wen = (dec_o.rd != 0);
          dec_o.is_jump = 1'b1;
        end else begin
          dec_o.illegal = 1'b1;
        end
      end
      7'b1100011: begin
        dec_o.imm = imm_b;
        dec_o.uses_rs1 = 1'b1;
        dec_o.uses_rs2 = 1'b1;
        dec_o.is_branch = 1'b1;
        unique case (funct3)
          3'b000: dec_o.op = UOP_BEQ;
          3'b001: dec_o.op = UOP_BNE;
          3'b100: dec_o.op = UOP_BLT;
          3'b101: dec_o.op = UOP_BGE;
          3'b110: dec_o.op = UOP_BLTU;
          3'b111: dec_o.op = UOP_BGEU;
          default: dec_o.illegal = 1'b1;
        endcase
      end
      7'b0000011: begin
        dec_o.imm = imm_i;
        dec_o.uses_rs1 = 1'b1;
        dec_o.rd_wen = (dec_o.rd != 0);
        dec_o.is_load = 1'b1;
        unique case (funct3)
          3'b000: begin dec_o.op = UOP_LB;  dec_o.mem_size = MEM_SIZE_B; end
          3'b001: begin dec_o.op = UOP_LH;  dec_o.mem_size = MEM_SIZE_H; end
          3'b010: begin dec_o.op = UOP_LW;  dec_o.mem_size = MEM_SIZE_W; end
          3'b100: begin dec_o.op = UOP_LBU; dec_o.mem_size = MEM_SIZE_B; dec_o.mem_unsigned = 1'b1; end
          3'b101: begin dec_o.op = UOP_LHU; dec_o.mem_size = MEM_SIZE_H; dec_o.mem_unsigned = 1'b1; end
          default: dec_o.illegal = 1'b1;
        endcase
      end
      7'b0100011: begin
        dec_o.imm = imm_s;
        dec_o.uses_rs1 = 1'b1;
        dec_o.uses_rs2 = 1'b1;
        dec_o.is_store = 1'b1;
        unique case (funct3)
          3'b000: begin dec_o.op = UOP_SB; dec_o.mem_size = MEM_SIZE_B; end
          3'b001: begin dec_o.op = UOP_SH; dec_o.mem_size = MEM_SIZE_H; end
          3'b010: begin dec_o.op = UOP_SW; dec_o.mem_size = MEM_SIZE_W; end
          default: dec_o.illegal = 1'b1;
        endcase
      end
      7'b0010011: begin
        dec_o.imm = imm_i;
        dec_o.uses_rs1 = 1'b1;
        dec_o.rd_wen = (dec_o.rd != 0);
        unique case (funct3)
          3'b000: dec_o.op = UOP_ADDI;
          3'b010: dec_o.op = UOP_SLTI;
          3'b011: dec_o.op = UOP_SLTIU;
          3'b100: dec_o.op = UOP_XORI;
          3'b110: dec_o.op = UOP_ORI;
          3'b111: dec_o.op = UOP_ANDI;
          3'b001: begin
            if (funct7 == 7'b0000000) begin
              dec_o.op = UOP_SLLI;
              dec_o.imm = {27'b0, inst_i[24:20]};
            end else dec_o.illegal = 1'b1;
          end
          3'b101: begin
            dec_o.imm = {27'b0, inst_i[24:20]};
            if (funct7 == 7'b0000000) dec_o.op = UOP_SRLI;
            else if (funct7 == 7'b0100000) dec_o.op = UOP_SRAI;
            else dec_o.illegal = 1'b1;
          end
          default: dec_o.illegal = 1'b1;
        endcase
      end
      7'b0110011: begin
        dec_o.uses_rs1 = 1'b1;
        dec_o.uses_rs2 = 1'b1;
        dec_o.rd_wen = (dec_o.rd != 0);
        if (funct7 == 7'b0000001) begin
          dec_o.is_muldiv = 1'b1;
          unique case (funct3)
            3'b000: dec_o.op = UOP_MUL;
            3'b001: dec_o.op = UOP_MULH;
            3'b010: dec_o.op = UOP_MULHSU;
            3'b011: dec_o.op = UOP_MULHU;
            3'b100: dec_o.op = UOP_DIV;
            3'b101: dec_o.op = UOP_DIVU;
            3'b110: dec_o.op = UOP_REM;
            3'b111: dec_o.op = UOP_REMU;
            default: dec_o.illegal = 1'b1;
          endcase
        end else begin
          unique case ({funct7, funct3})
            10'b0000000_000: dec_o.op = UOP_ADD;
            10'b0100000_000: dec_o.op = UOP_SUB;
            10'b0000000_001: dec_o.op = UOP_SLL;
            10'b0000000_010: dec_o.op = UOP_SLT;
            10'b0000000_011: dec_o.op = UOP_SLTU;
            10'b0000000_100: dec_o.op = UOP_XOR;
            10'b0000000_101: dec_o.op = UOP_SRL;
            10'b0100000_101: dec_o.op = UOP_SRA;
            10'b0000000_110: dec_o.op = UOP_OR;
            10'b0000000_111: dec_o.op = UOP_AND;
            10'b0010000_010: dec_o.op = UOP_SH1ADD;
            10'b0010000_100: dec_o.op = UOP_SH2ADD;
            10'b0010000_110: dec_o.op = UOP_SH3ADD;
            default: dec_o.illegal = 1'b1;
          endcase
        end
      end
      // JYD custom-0 accelerators. CRC32 folds a full word in the same order
      // as two CRC16 operations, eliminating the dependency between them.
      7'b0001011: begin
        if ((funct7 == 7'b0000000) &&
            (funct3 inside {3'b000, 3'b001, 3'b010})) begin
          unique case (funct3)
            3'b000: dec_o.op = UOP_CRC16;
            3'b001: dec_o.op = UOP_STATE_STEP;
            default: dec_o.op = UOP_CRC32;
          endcase
          dec_o.is_accel = 1'b1;
          dec_o.uses_rs1 = 1'b1;
          dec_o.uses_rs2 = 1'b1;
          dec_o.rd_wen = (dec_o.rd != 0);
        end else begin
          dec_o.illegal = 1'b1;
        end
      end
      7'b0001111: begin
        dec_o.is_serializing = 1'b1;
        unique case (funct3)
          3'b000: dec_o.op = UOP_FENCE;
          3'b001: dec_o.op = UOP_FENCEI;
          default: dec_o.illegal = 1'b1;
        endcase
      end
      7'b1110011: begin
        dec_o.is_serializing = 1'b1;
        if (funct3 == 3'b000) begin
          unique case (inst_i)
            32'h0000_0073: dec_o.op = UOP_ECALL;
            32'h0010_0073: dec_o.op = UOP_EBREAK;
            32'h3020_0073: dec_o.op = UOP_MRET;
            default: dec_o.illegal = 1'b1;
          endcase
        end else begin
          dec_o.is_csr = 1'b1;
          dec_o.rd_wen = (dec_o.rd != 0);
          unique case (funct3)
            3'b001: begin dec_o.op = UOP_CSRRW;  dec_o.uses_rs1 = 1'b1; end
            3'b010: begin dec_o.op = UOP_CSRRS;  dec_o.uses_rs1 = (dec_o.rs1 != 0); end
            3'b011: begin dec_o.op = UOP_CSRRC;  dec_o.uses_rs1 = (dec_o.rs1 != 0); end
            3'b101: begin dec_o.op = UOP_CSRRWI; dec_o.imm = {27'b0, dec_o.rs1}; end
            3'b110: begin dec_o.op = UOP_CSRRSI; dec_o.imm = {27'b0, dec_o.rs1}; end
            3'b111: begin dec_o.op = UOP_CSRRCI; dec_o.imm = {27'b0, dec_o.rs1}; end
            default: dec_o.illegal = 1'b1;
          endcase
        end
      end
      default: dec_o.illegal = 1'b1;
    endcase

    if (dec_o.illegal) begin
      dec_o.op = UOP_ILLEGAL;
      dec_o.rd_wen = 1'b0;
      dec_o.is_branch = 1'b0;
      dec_o.is_jump = 1'b0;
      dec_o.is_load = 1'b0;
      dec_o.is_store = 1'b0;
      dec_o.is_muldiv = 1'b0;
      dec_o.is_accel = 1'b0;
      dec_o.is_csr = 1'b0;
    end
  end
endmodule
