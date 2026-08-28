`timescale 1ns/1ps
module ooo_soc_system #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned UART_BAUD = 115_200,
  parameter logic [31:0] BUILD_ID = 32'h2025_2302,
  parameter string MEM_INIT_FILE = ""
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        uart_rx_i,
  output logic        uart_tx_o,
  output logic        timer_irq_o,
  output logic        ext_irq_o,
  output logic [31:0] debug_pc_o,
  output logic [5:0]  debug_rob_count_o,
  output logic [31:0] timer_count_o,
  output logic [3:0]  irq_pending_o,
  output logic        coremark_led_o
);
  import soc_cfg_pkg::*;
  import mmio_pkg::*;
  import core_types_pkg::*;

  // Local synchronous run copies keep the high-fanout functional reset out of
  // the core/cache/fabric placement clusters.  They intentionally have no
  // reset pin: INIT=0 provides the power-up state and rst_ni has already passed
  // through the domain synchronizer and the top-level functional boundary.
  (* keep = "true" *) logic run_core_q = 1'b0;
  (* keep = "true" *) logic run_icache_q = 1'b0;
  (* keep = "true" *) logic run_dcache_q = 1'b0;
  (* keep = "true" *) logic run_fabric_q = 1'b0;
  (* keep = "true" *) logic run_periph_q = 1'b0;

  always_ff @(posedge clk_i) begin
    run_core_q <= rst_ni;
    run_icache_q <= rst_ni;
    run_dcache_q <= rst_ni;
    run_fabric_q <= rst_ni;
    run_periph_q <= rst_ni;
  end

  logic core_imem_req_valid, core_imem_req_ready;
  logic [31:0] core_imem_req_addr;
  logic [3:0] core_imem_req_epoch;
  logic core_imem_rsp_valid, core_imem_rsp_ready, core_imem_rsp_error;
  logic [31:0] core_imem_rsp_addr;
  logic [3:0] core_imem_rsp_epoch;
  logic [63:0] core_imem_rsp_data;
  logic icache_flush;
  logic dcache_clean_req_raw, dcache_clean_req_q, dcache_clean_done;

  logic core_dmem_req_valid, core_dmem_req_ready, core_dmem_req_write;
  logic [31:0] core_dmem_req_addr, core_dmem_req_wdata;
  logic [3:0] core_dmem_req_wstrb;
  logic [3:0] core_dmem_req_seq, core_dmem_rsp_seq;
  uop_id_t core_dmem_req_uop_id, core_dmem_rsp_uop_id;
  logic core_dmem_load_valid, core_dmem_store_valid;
  logic [31:0] core_dmem_load_addr, core_dmem_store_addr;
  logic core_dmem_fast_load_valid;
  logic [31:0] core_dmem_fast_load_addr;
  logic [3:0] core_dmem_fast_load_seq;
  uop_id_t core_dmem_fast_load_uop_id;
  logic core_dmem_rsp_valid, core_dmem_rsp_error;
  logic [31:0] core_dmem_rsp_data;
  commit_trace_t commit_trace [2];

  logic fabric_dmem_req_valid, fabric_dmem_req_ready, fabric_dmem_req_write;
  logic [31:0] fabric_dmem_req_addr, fabric_dmem_req_wdata;
  logic [3:0] fabric_dmem_req_wstrb, fabric_dmem_req_seq;
  uop_id_t fabric_dmem_req_uop_id;
  logic dmem_req_fifo_empty;
  logic dmem_fifo_enq_valid, dmem_fifo_enq_ready;
  logic dc_fast_load_use;
  logic fabric_dmem_buffered;
  logic buffered_dmem_valid, buffered_dmem_write;
  logic [31:0] buffered_dmem_addr, buffered_dmem_wdata;
  logic [3:0] buffered_dmem_wstrb, buffered_dmem_seq;
  uop_id_t buffered_dmem_uop_id;
  logic selected_store_valid;
  logic [31:0] selected_store_addr, selected_store_wdata;
  logic [3:0] selected_store_wstrb, selected_store_seq;
  uop_id_t selected_store_uop_id;

  // Cacheable stores are accepted into a one-entry elastic stage before they
  // reach the D-cache.  This is a throughput boundary, not a serial delay:
  // when the resident store advances, a new store can replace it on the same
  // edge.  The upstream two-entry FIFO holds a following load until the store
  // has reached the cache, preserving memory order.
  logic store_stage_valid_q;
  logic [31:0] store_stage_addr_q, store_stage_wdata_q;
  logic [3:0] store_stage_wstrb_q, store_stage_seq_q;
  uop_id_t store_stage_uop_id_q;
  logic store_stage_ready, store_stage_push, store_stage_pop;

  logic ic_mem_req_valid, ic_mem_req_ready;
  logic [31:0] ic_mem_req_addr;
  logic ic_mem_rsp_valid_q, ic_mem_rsp_error_q;
  logic [63:0] ic_mem_rsp_data;

  logic dc_core_load_valid, dc_core_store_valid, dc_core_req_ready;
  logic dc_core_load_ready, dc_core_store_ready;
  logic [31:0] dc_core_load_addr;
  logic [31:0] dc_core_req_wdata;
  logic [3:0] dc_core_req_wstrb, dc_core_req_seq;
  uop_id_t dc_core_req_uop_id;
  logic dcache_idle, core_dcache_idle;
  logic dc_core_rsp_valid, dc_core_rsp_error;
  logic [31:0] dc_core_rsp_data;
  logic [3:0] dc_core_rsp_seq;
  logic [7:0] dc_core_rsp_uop_id;
  logic dc_mem_req_valid, dc_mem_req_ready, dc_mem_req_write;
  logic [31:0] dc_mem_req_addr;
  logic [63:0] dc_mem_req_wdata;
  logic [7:0] dc_mem_req_wstrb;
  logic dc_mem_rsp_valid_q, dc_mem_rsp_error_q;
  logic [63:0] dc_mem_rsp_data;

  logic bram_a_en;
  logic [$clog2(RAM_BYTES/8)-1:0] bram_a_addr;
  logic [63:0] bram_a_rdata;
  logic bram_b_en;
  logic [7:0] bram_b_we;
  logic [$clog2(RAM_BYTES/8)-1:0] bram_b_addr;
  logic [63:0] bram_b_wdata;
  logic [63:0] bram_b_rdata;

  logic dmem_load_is_ram, dmem_store_is_ram;
  logic bypass_rsp_valid_q, bypass_rsp_error_q;
  logic [31:0] bypass_rsp_data_q;
  logic [3:0] bypass_rsp_seq_q;
  logic [7:0] bypass_rsp_uop_id_q;
  mmio_req_t mmio_req;
  mmio_rsp_t mmio_rsp;

  ooo_core u_core (
    .clk_i(clk_i), .rst_ni(run_core_q),
    .imem_req_valid_o(core_imem_req_valid), .imem_req_ready_i(core_imem_req_ready),
    .imem_req_addr_o(core_imem_req_addr), .imem_req_epoch_o(core_imem_req_epoch),
    .imem_rsp_valid_i(core_imem_rsp_valid), .imem_rsp_ready_o(core_imem_rsp_ready),
    .imem_rsp_addr_i(core_imem_rsp_addr), .imem_rsp_epoch_i(core_imem_rsp_epoch),
    .imem_rsp_data_i(core_imem_rsp_data), .imem_rsp_error_i(core_imem_rsp_error),
    .icache_flush_o(icache_flush),
    .dcache_idle_i(core_dcache_idle), .dcache_clean_req_o(dcache_clean_req_raw),
    .dcache_clean_done_i(dcache_clean_done),
    .dmem_req_valid_o(core_dmem_req_valid), .dmem_req_ready_i(core_dmem_req_ready),
    .dmem_req_write_o(core_dmem_req_write), .dmem_req_addr_o(core_dmem_req_addr),
    .dmem_req_wdata_o(core_dmem_req_wdata), .dmem_req_wstrb_o(core_dmem_req_wstrb),
    .dmem_req_seq_o(core_dmem_req_seq), .dmem_req_uop_id_o(core_dmem_req_uop_id),
    .dmem_load_valid_o(core_dmem_load_valid), .dmem_load_addr_o(core_dmem_load_addr),
    .dmem_fast_load_valid_o(core_dmem_fast_load_valid),
    .dmem_fast_load_addr_o(core_dmem_fast_load_addr),
    .dmem_fast_load_seq_o(core_dmem_fast_load_seq),
    .dmem_fast_load_uop_id_o(core_dmem_fast_load_uop_id),
    .dmem_store_valid_o(core_dmem_store_valid), .dmem_store_addr_o(core_dmem_store_addr),
    .dmem_rsp_valid_i(core_dmem_rsp_valid), .dmem_rsp_data_i(core_dmem_rsp_data),
    .dmem_rsp_error_i(core_dmem_rsp_error), .dmem_rsp_seq_i(core_dmem_rsp_seq),
    .dmem_rsp_uop_id_i(core_dmem_rsp_uop_id), .timer_irq_i(timer_irq_o),
    .external_irq_i(ext_irq_o), .commit_trace_o(commit_trace),
    .debug_pc_o(debug_pc_o), .debug_rob_count_o(debug_rob_count_o)
  );

  instruction_cache u_icache (
    .clk_i(clk_i), .rst_ni(run_icache_q), .flush_i(icache_flush),
    .core_req_valid_i(core_imem_req_valid), .core_req_ready_o(core_imem_req_ready),
    .core_req_addr_i(core_imem_req_addr), .core_req_epoch_i(core_imem_req_epoch),
    .core_rsp_valid_o(core_imem_rsp_valid), .core_rsp_ready_i(core_imem_rsp_ready),
    .core_rsp_addr_o(core_imem_rsp_addr), .core_rsp_epoch_o(core_imem_rsp_epoch),
    .core_rsp_data_o(core_imem_rsp_data), .core_rsp_error_o(core_imem_rsp_error),
    .mem_req_valid_o(ic_mem_req_valid), .mem_req_ready_i(ic_mem_req_ready),
    .mem_req_addr_o(ic_mem_req_addr), .mem_rsp_valid_i(ic_mem_rsp_valid_q),
    .mem_rsp_data_i(ic_mem_rsp_data), .mem_rsp_error_i(ic_mem_rsp_error_q)
  );

  // A two-entry registered request boundary prevents cache/MMIO ready logic
  // from feeding back through precise retirement and dispatch in the same
  // cycle.  It preserves request order and sustains one transfer per cycle
  // whenever one entry is occupied and the fabric consumes the head.
  dmem_request_fifo u_dmem_request_fifo (
    .clk_i(clk_i), .rst_ni(run_fabric_q),
    .enq_valid_i(dmem_fifo_enq_valid), .enq_ready_o(dmem_fifo_enq_ready),
    .enq_write_i(core_dmem_req_write), .enq_addr_i(core_dmem_req_addr),
    .enq_wdata_i(core_dmem_req_wdata), .enq_wstrb_i(core_dmem_req_wstrb),
    .enq_seq_i(core_dmem_req_seq), .enq_uop_id_i(core_dmem_req_uop_id),
    .enq_fast_load_i(core_dmem_fast_load_valid),
    .deq_valid_o(fabric_dmem_req_valid), .deq_ready_i(fabric_dmem_req_ready),
    .deq_write_o(fabric_dmem_req_write), .deq_addr_o(fabric_dmem_req_addr),
    .deq_wdata_o(fabric_dmem_req_wdata), .deq_wstrb_o(fabric_dmem_req_wstrb),
    .deq_seq_o(fabric_dmem_req_seq), .deq_uop_id_o(fabric_dmem_req_uop_id),
    .buffered_valid_o(buffered_dmem_valid),
    .buffered_write_o(buffered_dmem_write),
    .buffered_addr_o(buffered_dmem_addr),
    .buffered_wdata_o(buffered_dmem_wdata),
    .buffered_wstrb_o(buffered_dmem_wstrb),
    .buffered_seq_o(buffered_dmem_seq),
    .buffered_uop_id_o(buffered_dmem_uop_id),
    .empty_o(dmem_req_fifo_empty), .count_o()
  );

  assign core_dcache_idle = dcache_idle && dmem_req_fifo_empty &&
                            !store_stage_valid_q;
  assign fabric_dmem_buffered = buffered_dmem_valid;
  // Upstream acceptance depends only on FIFO capacity.  The FIFO falls the
  // EX-local cacheable load lane (and stores) through when empty, so a ready
  // D-cache keeps the zero-added-cycle hit path.  If the cache blocks, the
  // same edge stores the request locally instead of feeding cache ready back
  // through LQ/SQ/ROB.
  assign dmem_fifo_enq_valid = core_dmem_req_valid;
  assign core_dmem_req_ready = dmem_fifo_enq_ready;

  // CoreMark's measured data working set produces one miss in the complete
  // run.  A 64-set, two-way cache keeps 4 KiB of data capacity while halving
  // both the data BRAMs and the replicated multi-reader tag arrays.
  data_cache #(.SETS(64)) u_dcache (
    .clk_i(clk_i), .rst_ni(run_dcache_q), .core_load_valid_i(dc_core_load_valid),
    .core_load_addr_i(dc_core_load_addr),
    .core_store_valid_i(dc_core_store_valid),
    .core_store_addr_i(store_stage_addr_q),
    .core_req_ready_o(dc_core_req_ready),
    .core_load_ready_o(dc_core_load_ready),
    .core_store_ready_o(dc_core_store_ready),
    .core_req_wdata_i(dc_core_req_wdata),
    .core_req_wstrb_i(dc_core_req_wstrb), .core_req_seq_i(dc_core_req_seq),
    .core_req_uop_id_i(dc_core_req_uop_id), .core_rsp_valid_o(dc_core_rsp_valid),
    .core_rsp_data_o(dc_core_rsp_data), .core_rsp_error_o(dc_core_rsp_error),
    .core_rsp_seq_o(dc_core_rsp_seq), .core_rsp_uop_id_o(dc_core_rsp_uop_id),
    .idle_o(dcache_idle),
    .clean_req_i(dcache_clean_req_q), .clean_done_o(dcache_clean_done),
    .mem_req_valid_o(dc_mem_req_valid), .mem_req_ready_i(dc_mem_req_ready),
    .mem_req_write_o(dc_mem_req_write), .mem_req_addr_o(dc_mem_req_addr),
    .mem_req_wdata_o(dc_mem_req_wdata), .mem_req_wstrb_o(dc_mem_req_wstrb),
    .mem_rsp_valid_i(dc_mem_rsp_valid_q), .mem_rsp_data_i(dc_mem_rsp_data),
    .mem_rsp_error_i(dc_mem_rsp_error_q)
  );

  unified_bram #(.BYTES(RAM_BYTES), .INIT_FILE(MEM_INIT_FILE)) u_memory (
    .clk_i(clk_i), .a_en_i(bram_a_en), .a_addr_i(bram_a_addr),
    .a_rdata_o(bram_a_rdata), .b_en_i(bram_b_en), .b_we_i(bram_b_we),
    .b_addr_i(bram_b_addr), .b_wdata_i(bram_b_wdata), .b_rdata_o(bram_b_rdata)
  );

  soc_peripherals #(.CLK_HZ(CLK_HZ), .UART_BAUD(UART_BAUD), .BUILD_ID(BUILD_ID))
  u_peripherals (
    .clk_i(clk_i), .rst_ni(run_periph_q), .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .mtip_o(timer_irq_o), .meip_o(ext_irq_o), .bus_req_i(mmio_req),
    .bus_rsp_o(mmio_rsp), .timer_count_o(timer_count_o), .irq_pending_o(irq_pending_o),
    .coremark_led_o(coremark_led_o)
  );

  // Each cache owns one physical 64-bit port of the unified backing BRAM.
  // Refill requests are naturally serialized per port by the cache FSMs.
  assign ic_mem_req_ready = 1'b1;
  assign bram_a_en = ic_mem_req_valid && ic_mem_req_ready &&
                     addr_is_ram(ic_mem_req_addr);
  assign bram_a_addr = ic_mem_req_addr[$clog2(RAM_BYTES/8)+2:3];
  assign ic_mem_rsp_data = bram_a_rdata;

  assign dc_mem_req_ready = 1'b1;
  assign bram_b_en = dc_mem_req_valid && dc_mem_req_ready &&
                     addr_is_ram(dc_mem_req_addr);
  assign bram_b_addr = dc_mem_req_addr[$clog2(RAM_BYTES/8)+2:3];
  assign bram_b_we = dc_mem_req_write ? dc_mem_req_wstrb : '0;
  assign bram_b_wdata = dc_mem_req_wdata;
  assign dc_mem_rsp_data = bram_b_rdata;

  // MMIO and unmapped accesses bypass the D-cache. Only the five architected
  // 4 KiB peripheral windows are treated as MMIO; holes return an access fault.
  // The FIFO dequeue channel is either its registered head or its RAM-only
  // fall-through request.  MMIO remains registered, while a cacheable load can
  // still start the D-cache lookup on its enqueue cycle.
  // A newly executed load has a dedicated EX-local address/identity lane.
  // The canonical request still enters the FIFO and owns acceptance/replay;
  // only an empty-FIFO fall-through uses these narrow direct wires to start
  // the D-cache lookup.  Buffered and replayed loads use the registered head.
  assign dc_fast_load_use = dmem_req_fifo_empty &&
                            core_dmem_fast_load_valid &&
                            addr_is_ram(core_dmem_fast_load_addr);
  assign dc_core_load_addr = dc_fast_load_use ? core_dmem_fast_load_addr
                                               : buffered_dmem_addr;
  assign dmem_load_is_ram = addr_is_ram(dc_core_load_addr);
  assign dc_core_load_valid = dc_fast_load_use ||
                              (buffered_dmem_valid &&
                               !buffered_dmem_write && dmem_load_is_ram);

  assign selected_store_valid = fabric_dmem_buffered
    ? (buffered_dmem_valid && buffered_dmem_write)
    : (core_dmem_req_valid && core_dmem_store_valid);
  assign selected_store_addr = fabric_dmem_buffered ? buffered_dmem_addr
                                                     : core_dmem_store_addr;
  assign selected_store_wdata = fabric_dmem_buffered ? buffered_dmem_wdata
                                                      : core_dmem_req_wdata;
  assign selected_store_wstrb = fabric_dmem_buffered ? buffered_dmem_wstrb
                                                      : core_dmem_req_wstrb;
  assign selected_store_seq = fabric_dmem_buffered ? buffered_dmem_seq
                                                    : core_dmem_req_seq;
  assign selected_store_uop_id = fabric_dmem_buffered ? buffered_dmem_uop_id
                                                       : core_dmem_req_uop_id;
  assign dmem_store_is_ram = addr_is_ram(selected_store_addr);
  assign dc_core_store_valid = store_stage_valid_q;
  assign dc_core_req_wdata = store_stage_wdata_q;
  assign dc_core_req_wstrb = store_stage_wstrb_q;
  // Only loads consume response identity; stores retain their identity in the
  // stage for debug, but must not steal the simultaneous load's metadata.
  assign dc_core_req_seq = dc_fast_load_use ? core_dmem_fast_load_seq
                                             : buffered_dmem_seq;
  assign dc_core_req_uop_id = dc_fast_load_use
                            ? core_dmem_fast_load_uop_id
                            : buffered_dmem_uop_id;

  assign store_stage_pop = store_stage_valid_q && dc_core_store_ready;
  assign store_stage_ready = !store_stage_valid_q || store_stage_pop;
  assign store_stage_push = selected_store_valid && dmem_store_is_ram &&
                            fabric_dmem_req_ready;

  always_comb begin
    mmio_req = '0;
    // Non-RAM traffic is necessarily a registered FIFO head: the FIFO permits
    // fall-through only for RAM.  Drive all MMIO payload/control from that
    // head instead of the mixed dequeue channel so STA has a real register
    // boundary between EX/LQ and the peripherals.
    mmio_req.valid = !store_stage_valid_q && buffered_dmem_valid &&
                     addr_is_mmio(buffered_dmem_addr);
    mmio_req.write = mmio_req.valid && buffered_dmem_write;
    mmio_req.addr = buffered_dmem_addr;
    mmio_req.wdata = buffered_dmem_wdata;
    mmio_req.wstrb = buffered_dmem_wstrb;

    if (fabric_dmem_buffered) begin
      if (!buffered_dmem_write) begin
        if (addr_is_ram(buffered_dmem_addr))
          fabric_dmem_req_ready = dc_core_load_ready;
        else if (store_stage_valid_q || !dcache_idle)
          fabric_dmem_req_ready = 1'b0;
        else if (addr_is_mmio(buffered_dmem_addr))
          fabric_dmem_req_ready = mmio_rsp.ready;
        else
          fabric_dmem_req_ready = 1'b1;
        // D-cache and bypass responses are one-cycle, valid-only streams into
        // one core response port.  Serialize precise non-RAM reads until the
        // D-cache is completely quiescent so a collision is impossible.
      end else if (addr_is_ram(buffered_dmem_addr)) begin
        fabric_dmem_req_ready = store_stage_ready;
      end else if (store_stage_valid_q) begin
        fabric_dmem_req_ready = 1'b0;
      end else if (addr_is_mmio(buffered_dmem_addr)) begin
        fabric_dmem_req_ready = mmio_rsp.ready;
      end else begin
        fabric_dmem_req_ready = 1'b1;
      end
    end else if (core_dmem_req_valid && core_dmem_load_valid &&
                 addr_is_ram(core_dmem_load_addr)) begin
      fabric_dmem_req_ready = dc_core_load_ready;
    end else if (core_dmem_req_valid && core_dmem_store_valid &&
                 addr_is_ram(core_dmem_store_addr)) begin
      fabric_dmem_req_ready = store_stage_ready;
    end else begin
      fabric_dmem_req_ready = 1'b1;
    end

    core_dmem_rsp_valid = dc_core_rsp_valid || bypass_rsp_valid_q;
    core_dmem_rsp_data = dc_core_rsp_valid ? dc_core_rsp_data : bypass_rsp_data_q;
    core_dmem_rsp_error = dc_core_rsp_valid ? dc_core_rsp_error : bypass_rsp_error_q;
    core_dmem_rsp_seq = dc_core_rsp_valid ? dc_core_rsp_seq : bypass_rsp_seq_q;
    core_dmem_rsp_uop_id = dc_core_rsp_valid ? dc_core_rsp_uop_id
                                             : bypass_rsp_uop_id_q;
  end

  always_ff @(posedge clk_i) begin
    if (!run_fabric_q) begin
      ic_mem_rsp_valid_q <= 1'b0;
      ic_mem_rsp_error_q <= 1'b0;
      dc_mem_rsp_valid_q <= 1'b0;
      dc_mem_rsp_error_q <= 1'b0;
      dcache_clean_req_q <= 1'b0;
      bypass_rsp_valid_q <= 1'b0;
      bypass_rsp_error_q <= 1'b0;
      bypass_rsp_data_q <= '0;
      bypass_rsp_seq_q <= '0;
      bypass_rsp_uop_id_q <= '0;
      store_stage_valid_q <= 1'b0;
      store_stage_addr_q <= '0;
      store_stage_wdata_q <= '0;
      store_stage_wstrb_q <= '0;
      store_stage_seq_q <= '0;
      store_stage_uop_id_q <= '0;
    end else begin
      ic_mem_rsp_valid_q <= ic_mem_req_valid && ic_mem_req_ready;
      ic_mem_rsp_error_q <= ic_mem_req_valid && ic_mem_req_ready &&
                            !addr_is_ram(ic_mem_req_addr);

      dc_mem_rsp_valid_q <= dc_mem_req_valid && dc_mem_req_ready &&
                            !dc_mem_req_write;
      dc_mem_rsp_error_q <= dc_mem_req_valid && dc_mem_req_ready &&
                            !dc_mem_req_write && !addr_is_ram(dc_mem_req_addr);

      // FENCE.I is rare and level-sensitive.  Latch its clean request at the
      // SoC boundary and hold it to completion, removing the ROB/commit cone
      // from every D-cache state and dirty-bit write input.
      if (dcache_clean_done)
        dcache_clean_req_q <= 1'b0;
      else if (dcache_clean_req_raw)
        dcache_clean_req_q <= 1'b1;

      unique case ({store_stage_push, store_stage_pop})
        2'b10: store_stage_valid_q <= 1'b1;
        2'b01: store_stage_valid_q <= 1'b0;
        default: store_stage_valid_q <= store_stage_valid_q;
      endcase
      // Prewrite payload whenever the elastic slot is available.  Its valid
      // bit alone is push-gated, so the EX/LQ acceptance cone no longer drives
      // CE on 80 payload flops.
      if (store_stage_ready) begin
        store_stage_addr_q <= selected_store_addr;
        store_stage_wdata_q <= selected_store_wdata;
        store_stage_wstrb_q <= selected_store_wstrb;
        store_stage_seq_q <= selected_store_seq;
        store_stage_uop_id_q <= selected_store_uop_id;
      end

      bypass_rsp_valid_q <= buffered_dmem_valid && !buffered_dmem_write &&
                            fabric_dmem_req_ready &&
                            !addr_is_ram(buffered_dmem_addr);
      // A valid-only response is consumed on this edge.  The payload can be
      // refreshed unconditionally from the registered FIFO head, eliminating
      // the long request-decode CE shared by every response bit.
      bypass_rsp_error_q <= !addr_is_mmio(buffered_dmem_addr) || mmio_rsp.error;
      bypass_rsp_data_q <= mmio_rsp.rdata;
      bypass_rsp_seq_q <= buffered_dmem_seq;
      bypass_rsp_uop_id_q <= buffered_dmem_uop_id;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (run_fabric_q) begin
      assert (!(dc_core_rsp_valid && bypass_rsp_valid_q))
        else $fatal(1, "D-cache and bypass responses collided");
      if (dc_fast_load_use) begin
        assert (core_dmem_req_valid && core_dmem_load_valid &&
                !core_dmem_req_write &&
                (core_dmem_fast_load_addr == core_dmem_req_addr) &&
                (core_dmem_fast_load_seq == core_dmem_req_seq) &&
                (core_dmem_fast_load_uop_id == core_dmem_req_uop_id))
          else $fatal(1, "fast D-cache lane lost canonical FIFO ownership");
      end
    end
  end
`endif
endmodule
