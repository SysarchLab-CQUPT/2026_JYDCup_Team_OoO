`timescale 1ns/1ps
module uart #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned RESET_BAUD = 115_200
) (
  input  logic                clk_i,
  input  logic                rst_ni,
  input  logic                rx_i,
  output logic                tx_o,
  output logic                irq_o,
  input  mmio_pkg::mmio_req_t bus_req_i,
  output mmio_pkg::mmio_rsp_t bus_rsp_o
);
  import mmio_pkg::*;

  localparam int unsigned RESET_DIV_INT =
    (CLK_HZ + (RESET_BAUD / 2)) / RESET_BAUD;
  localparam logic [31:0] RESET_DIV =
    (RESET_DIV_INT < 2) ? 32'd2 : RESET_DIV_INT;

  localparam logic [11:0] REG_TXDATA   = 12'h000;
  localparam logic [11:0] REG_RXDATA   = 12'h004;
  localparam logic [11:0] REG_STATUS   = 12'h008;
  localparam logic [11:0] REG_CTRL     = 12'h00c;
  localparam logic [11:0] REG_BAUD_DIV = 12'h010;

  logic [31:0] baud_div_q;
  logic [31:0] tx_count_q;
  logic [9:0] tx_frame_q;
  logic [3:0] tx_bit_q;
  logic tx_busy_q;
  logic [1:0] ctrl_q;

  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync_q;
  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
  rx_state_t rx_state_q;
  logic [31:0] rx_count_q;
  logic [2:0] rx_bit_q;
  logic [7:0] rx_shift_q;
  logic [7:0] rx_data_q;
  logic rx_valid_q;

  logic txdata_access;
  logic bus_fire;

  assign txdata_access = bus_req_i.valid && bus_req_i.write &&
                         (bus_req_i.addr[11:0] == REG_TXDATA);

  always_comb begin
    bus_rsp_o = '{ready: bus_req_i.valid, rdata: 32'b0, error: 1'b0};
    if (txdata_access && tx_busy_q) begin
      bus_rsp_o.ready = 1'b0;
    end
    unique case (bus_req_i.addr[11:0])
      REG_RXDATA:   bus_rsp_o.rdata = {24'b0, rx_data_q};
      REG_STATUS:   bus_rsp_o.rdata = {30'b0, rx_valid_q, ~tx_busy_q};
      REG_CTRL:     bus_rsp_o.rdata = {30'b0, ctrl_q};
      REG_BAUD_DIV: bus_rsp_o.rdata = baud_div_q;
      default:      bus_rsp_o.rdata = 32'b0;
    endcase
  end

  assign bus_fire = bus_req_i.valid && bus_rsp_o.ready;
  assign irq_o = (ctrl_q[0] && rx_valid_q) || (ctrl_q[1] && !tx_busy_q);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      baud_div_q <= RESET_DIV;
      tx_count_q <= '0;
      tx_frame_q <= 10'h3ff;
      tx_bit_q <= '0;
      tx_busy_q <= 1'b0;
      tx_o <= 1'b1;
      ctrl_q <= '0;
      rx_sync_q <= 2'b11;
      rx_state_q <= RX_IDLE;
      rx_count_q <= '0;
      rx_bit_q <= '0;
      rx_shift_q <= '0;
      rx_data_q <= '0;
      rx_valid_q <= 1'b0;
    end else begin
      rx_sync_q <= {rx_sync_q[0], rx_i};

      if (bus_fire && bus_req_i.write) begin
        unique case (bus_req_i.addr[11:0])
          REG_TXDATA: begin
            tx_frame_q <= {1'b1, bus_req_i.wdata[7:0], 1'b0};
            tx_bit_q <= 4'd0;
            tx_count_q <= baud_div_q - 1'b1;
            tx_busy_q <= 1'b1;
            tx_o <= 1'b0;
          end
          REG_CTRL: begin
            if (bus_req_i.wstrb[0]) begin
              ctrl_q <= bus_req_i.wdata[1:0];
            end
          end
          REG_BAUD_DIV: begin
            if (|bus_req_i.wstrb) begin
              baud_div_q <= (bus_req_i.wdata < 2) ? 32'd2 : bus_req_i.wdata;
            end
          end
          default: begin end
        endcase
      end

      if (tx_busy_q && !(bus_fire && bus_req_i.write &&
                         (bus_req_i.addr[11:0] == REG_TXDATA))) begin
        if (tx_count_q == 0) begin
          if (tx_bit_q == 4'd9) begin
            tx_busy_q <= 1'b0;
            tx_o <= 1'b1;
          end else begin
            tx_bit_q <= tx_bit_q + 1'b1;
            tx_o <= tx_frame_q[tx_bit_q + 1'b1];
            tx_count_q <= baud_div_q - 1'b1;
          end
        end else begin
          tx_count_q <= tx_count_q - 1'b1;
        end
      end

      if (bus_fire && !bus_req_i.write &&
          (bus_req_i.addr[11:0] == REG_RXDATA)) begin
        rx_valid_q <= 1'b0;
      end

      unique case (rx_state_q)
        RX_IDLE: begin
          if (!rx_sync_q[1]) begin
            rx_state_q <= RX_START;
            rx_count_q <= baud_div_q >> 1;
          end
        end
        RX_START: begin
          if (rx_count_q == 0) begin
            if (!rx_sync_q[1]) begin
              rx_state_q <= RX_DATA;
              rx_count_q <= baud_div_q - 1'b1;
              rx_bit_q <= '0;
            end else begin
              rx_state_q <= RX_IDLE;
            end
          end else begin
            rx_count_q <= rx_count_q - 1'b1;
          end
        end
        RX_DATA: begin
          if (rx_count_q == 0) begin
            rx_shift_q[rx_bit_q] <= rx_sync_q[1];
            rx_count_q <= baud_div_q - 1'b1;
            if (rx_bit_q == 3'd7) begin
              rx_state_q <= RX_STOP;
            end else begin
              rx_bit_q <= rx_bit_q + 1'b1;
            end
          end else begin
            rx_count_q <= rx_count_q - 1'b1;
          end
        end
        RX_STOP: begin
          if (rx_count_q == 0) begin
            if (rx_sync_q[1]) begin
              rx_data_q <= rx_shift_q;
              rx_valid_q <= 1'b1;
            end
            rx_state_q <= RX_IDLE;
          end else begin
            rx_count_q <= rx_count_q - 1'b1;
          end
        end
        default: rx_state_q <= RX_IDLE;
      endcase
    end
  end
endmodule

