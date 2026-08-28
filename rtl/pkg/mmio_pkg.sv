`timescale 1ns/1ps
package mmio_pkg;
  typedef struct packed {
    logic        valid;
    logic        write;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
  } mmio_req_t;

  typedef struct packed {
    logic        ready;
    logic [31:0] rdata;
    logic        error;
  } mmio_rsp_t;
endpackage

