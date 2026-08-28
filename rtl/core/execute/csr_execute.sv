`timescale 1ns/1ps
module csr_execute (
  input  logic               csr_valid_i,
  input  rv32_pkg::uop_op_e op_i,
  input  logic [4:0]         rs1_field_i,
  input  logic [11:0]        csr_addr_i,
  input  logic [31:0]        source_i,
  input  logic [31:0]        read_data_i,
  input  logic               read_illegal_i,
  output logic               write_o,
  output logic [31:0]        write_data_o,
  output logic               illegal_o
);
  import rv32_pkg::*;

  function automatic logic csr_address_writable(input logic [11:0] addr);
    return addr inside {12'h300,12'h304,12'h305,12'h340,12'h341,12'h342,
                        12'h343,12'hb00,12'hb80,12'hb02,12'hb82};
  endfunction

  always_comb begin
    write_data_o = read_data_i;
    write_o = 1'b0;
    unique case (op_i)
      UOP_CSRRW, UOP_CSRRWI: begin
        write_data_o = source_i;
        write_o = 1'b1;
      end
      UOP_CSRRS, UOP_CSRRSI: begin
        write_data_o = read_data_i | source_i;
        // Bits 19:15 are rs1 for register forms and zimm for immediate forms.
        // CSRRS/CSRRC write intent is defined by that instruction field, not
        // by the runtime source value held in the register file.
        write_o = (rs1_field_i != 0);
      end
      UOP_CSRRC, UOP_CSRRCI: begin
        write_data_o = read_data_i & ~source_i;
        write_o = (rs1_field_i != 0);
      end
      default: begin end
    endcase
    illegal_o = csr_valid_i &&
                (read_illegal_i ||
                 (write_o && !csr_address_writable(csr_addr_i)));
  end

endmodule
