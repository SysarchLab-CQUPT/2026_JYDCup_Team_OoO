`timescale 1ns/1ps
module branch_checkpoints #(
  parameter int unsigned ENTRIES = 8
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              flush_i,
  input  core_types_pkg::rob_ptr_t          rob_tail_i,
  input  logic [1:0]                        alloc_valid_i,
  input  core_types_pkg::rob_ptr_t          alloc_rob_ptr_i [2],
  input  core_types_pkg::preg_t             alloc_map_i [2][32],
  output logic [1:0]                        alloc_accept_o,
  output logic [$clog2(ENTRIES):0]          alloc_id_o [2],
  output logic                              alloc_two_ready_o,
  input  logic                              release_valid_i,
  input  logic [$clog2(ENTRIES):0]          release_id_i,
  input  logic                              recovery_valid_i,
  input  logic [$clog2(ENTRIES):0]          recovery_id_i,
  output logic                              recovery_found_o,
  output core_types_pkg::preg_t             recovery_map_o [32],
  output logic [$clog2(ENTRIES+1)-1:0]      count_o
);
  import core_types_pkg::*;

  // ENTRIES is the architectural population limit.  Each physical bank needs
  // ENTRIES-1 rows: a dual allocation is legal only while total occupancy is
  // at most ENTRIES-2, so neither bank can then be full.  Seven rows per bank
  // are therefore the minimum that guarantees two atomic writes for an
  // eight-checkpoint machine; the former 4+4 split could strand both logical
  // free slots in one single-write bank.
  localparam int unsigned BANK_ENTRIES = ENTRIES - 1;
  localparam int unsigned INDEX_W = $clog2(BANK_ENTRIES);
  localparam int unsigned BANK_ID_BIT = $clog2(ENTRIES);
  localparam int unsigned COUNT_W = $clog2(ENTRIES+1);
  localparam int unsigned MAP_W = 32 * $bits(preg_t);

  // Two physical write banks allow two snapshots per cycle.  The combined
  // live population remains limited to ENTRIES; the high checkpoint-id bit
  // selects a bank and the remaining bits select its physical row.
  logic valid_bank0_q [BANK_ENTRIES], valid_bank1_q [BANK_ENTRIES];
  rob_ptr_t rob_ptr_bank0_q [BANK_ENTRIES], rob_ptr_bank1_q [BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [MAP_W-1:0] map_bank0_q [BANK_ENTRIES];
  (* ram_style = "distributed" *)
  logic [MAP_W-1:0] map_bank1_q [BANK_ENTRIES];

  logic [BANK_ENTRIES-1:0] free_bank0, free_bank1;
  logic [INDEX_W-1:0] first_free_bank0, first_free_bank1;
  logic free_bank0_found, free_bank1_found;
  logic [COUNT_W-1:0] bank0_count, bank1_count;
  logic [COUNT_W-1:0] count_q, recovery_count;

  logic map_bank0_we, map_bank1_we;
  logic [INDEX_W-1:0] map_bank0_waddr, map_bank1_waddr;
  logic [MAP_W-1:0] map_bank0_wdata, map_bank1_wdata;
  logic map_bank0_pending_q, map_bank1_pending_q;
  logic [INDEX_W-1:0] map_bank0_pending_addr_q;
  logic [INDEX_W-1:0] map_bank1_pending_addr_q;
  logic [MAP_W-1:0] map_bank0_pending_data_q;
  logic [MAP_W-1:0] map_bank1_pending_data_q;
  rob_ptr_t rob_ptr_bank0_wdata, rob_ptr_bank1_wdata;
  logic [MAP_W-1:0] alloc_map_flat [2];
  logic [MAP_W-1:0] recovery_map_bank0, recovery_map_bank1;
  rob_ptr_t recovery_rob_ptr;

  always_comb begin
    bank0_count = '0;
    bank1_count = '0;
    recovery_count = '0;
    for (int unsigned i = 0; i < BANK_ENTRIES; i++) begin
      bank0_count += valid_bank0_q[i];
      bank1_count += valid_bank1_q[i];
      if (valid_bank0_q[i] &&
          !(recovery_valid_i && recovery_found_o &&
            (rob_distance(rob_ptr_bank0_q[i], recovery_rob_ptr) <
             rob_distance(rob_tail_i, recovery_rob_ptr))))
        recovery_count += 1'b1;
      if (valid_bank1_q[i] &&
          !(recovery_valid_i && recovery_found_o &&
            (rob_distance(rob_ptr_bank1_q[i], recovery_rob_ptr) <
             rob_distance(rob_tail_i, recovery_rob_ptr))))
        recovery_count += 1'b1;
    end
  end

  // Admission consumes registered occupancy.  Recovery may still calculate a
  // multi-entry survivor count for count_q's D input, but that reduction no
  // longer feeds dispatch, IQ allocation, or predictor snapshot writes in the
  // same cycle.
  assign count_o = count_q;
  // With seven rows in each physical bank, total occupancy <= ENTRIES-2
  // guarantees that neither bank can be full.  Derive the dual-credit bit
  // directly from registered occupancy so the wide snapshot input cannot form
  // a procedural-block dependency back into top-level dispatch.
  assign alloc_two_ready_o = !flush_i && !recovery_valid_i &&
                             (count_q <= COUNT_W'(ENTRIES-2));

  always_comb begin
    for (int unsigned lane = 0; lane < 2; lane++) begin
      alloc_map_flat[lane] = '0;
      for (int unsigned r = 0; r < 32; r++)
        alloc_map_flat[lane][r*$bits(preg_t) +: $bits(preg_t)] =
          alloc_map_i[lane][r];
    end

    free_bank0 = '0;
    free_bank1 = '0;
    first_free_bank0 = '0;
    first_free_bank1 = '0;
    free_bank0_found = 1'b0;
    free_bank1_found = 1'b0;
    for (int unsigned i = 0; i < BANK_ENTRIES; i++) begin
      free_bank0[i] = !valid_bank0_q[i];
      free_bank1[i] = !valid_bank1_q[i];
    end
    for (int unsigned i = 0; i < BANK_ENTRIES; i++) begin
      if (!free_bank0_found && free_bank0[i]) begin
        free_bank0_found = 1'b1;
        first_free_bank0 = i[INDEX_W-1:0];
      end
      if (!free_bank1_found && free_bank1[i]) begin
        free_bank1_found = 1'b1;
        first_free_bank1 = i[INDEX_W-1:0];
      end
    end
    alloc_accept_o = '0;
    alloc_id_o[0] = '0;
    alloc_id_o[1] = '0;
    map_bank0_we = 1'b0;
    map_bank1_we = 1'b0;
    map_bank0_waddr = first_free_bank0;
    map_bank1_waddr = first_free_bank1;
    map_bank0_wdata = '0;
    map_bank1_wdata = '0;
    rob_ptr_bank0_wdata = '0;
    rob_ptr_bank1_wdata = '0;
    // A release becomes reusable on the following cycle.  Allocation is based
    // solely on registered valid bits, cutting resolve/release-to-snapshot
    // write-address feedback without changing checkpoint identity semantics.
    if (!flush_i && !recovery_valid_i && (|alloc_valid_i) &&
        (count_o < COUNT_W'(ENTRIES))) begin
      if (&alloc_valid_i) begin
        // A dual request is atomic.  If both physical write banks are not
        // available, the core splits dispatch instead of silently accepting
        // one branch without a recovery snapshot.
        if (alloc_two_ready_o) begin
          alloc_accept_o = 2'b11;
          alloc_id_o[0][BANK_ID_BIT] = 1'b0;
          alloc_id_o[0][INDEX_W-1:0] = first_free_bank0;
          alloc_id_o[1][BANK_ID_BIT] = 1'b1;
          alloc_id_o[1][INDEX_W-1:0] = first_free_bank1;
          map_bank0_we = 1'b1;
          map_bank1_we = 1'b1;
          map_bank0_wdata = alloc_map_flat[0];
          map_bank1_wdata = alloc_map_flat[1];
          rob_ptr_bank0_wdata = alloc_rob_ptr_i[0];
          rob_ptr_bank1_wdata = alloc_rob_ptr_i[1];
        end
      end else if ((bank0_count <= bank1_count) &&
                   free_bank0_found) begin
        alloc_accept_o[alloc_valid_i[0] ? 0 : 1] = 1'b1;
        alloc_id_o[alloc_valid_i[0] ? 0 : 1][BANK_ID_BIT] = 1'b0;
        alloc_id_o[alloc_valid_i[0] ? 0 : 1][INDEX_W-1:0] = first_free_bank0;
        map_bank0_we = 1'b1;
        map_bank0_wdata = alloc_map_flat[alloc_valid_i[0] ? 0 : 1];
        rob_ptr_bank0_wdata = alloc_rob_ptr_i[alloc_valid_i[0] ? 0 : 1];
      end else if (free_bank1_found) begin
        alloc_accept_o[alloc_valid_i[0] ? 0 : 1] = 1'b1;
        alloc_id_o[alloc_valid_i[0] ? 0 : 1][BANK_ID_BIT] = 1'b1;
        alloc_id_o[alloc_valid_i[0] ? 0 : 1][INDEX_W-1:0] = first_free_bank1;
        map_bank1_we = 1'b1;
        map_bank1_wdata = alloc_map_flat[alloc_valid_i[0] ? 0 : 1];
        rob_ptr_bank1_wdata = alloc_rob_ptr_i[alloc_valid_i[0] ? 0 : 1];
      end
    end

    recovery_found_o = recovery_id_i[BANK_ID_BIT]
                     ? valid_bank1_q[recovery_id_i[INDEX_W-1:0]]
                     : valid_bank0_q[recovery_id_i[INDEX_W-1:0]];
    recovery_map_bank0 = map_bank0_q[recovery_id_i[INDEX_W-1:0]];
    recovery_map_bank1 = map_bank1_q[recovery_id_i[INDEX_W-1:0]];
    if (map_bank0_pending_q &&
        (map_bank0_pending_addr_q == recovery_id_i[INDEX_W-1:0]))
      recovery_map_bank0 = map_bank0_pending_data_q;
    if (map_bank1_pending_q &&
        (map_bank1_pending_addr_q == recovery_id_i[INDEX_W-1:0]))
      recovery_map_bank1 = map_bank1_pending_data_q;
    for (int unsigned r = 0; r < 32; r++) begin
      recovery_map_o[r] = recovery_id_i[BANK_ID_BIT]
        ? recovery_map_bank1[r*$bits(preg_t) +: $bits(preg_t)]
        : recovery_map_bank0[r*$bits(preg_t) +: $bits(preg_t)];
    end
    recovery_rob_ptr = recovery_id_i[BANK_ID_BIT]
                     ? rob_ptr_bank1_q[recovery_id_i[INDEX_W-1:0]]
                     : rob_ptr_bank0_q[recovery_id_i[INDEX_W-1:0]];
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      map_bank0_pending_q <= 1'b0;
      map_bank1_pending_q <= 1'b0;
      map_bank0_pending_addr_q <= '0;
      map_bank1_pending_addr_q <= '0;
      map_bank0_pending_data_q <= '0;
      map_bank1_pending_data_q <= '0;
    end else begin
      if (map_bank0_pending_q)
        map_bank0_q[map_bank0_pending_addr_q] <= map_bank0_pending_data_q;
      if (map_bank1_pending_q)
        map_bank1_q[map_bank1_pending_addr_q] <= map_bank1_pending_data_q;
      map_bank0_pending_q <= map_bank0_we;
      map_bank1_pending_q <= map_bank1_we;
      if (map_bank0_we) begin
        map_bank0_pending_addr_q <= map_bank0_waddr;
        map_bank0_pending_data_q <= map_bank0_wdata;
      end
      if (map_bank1_we) begin
        map_bank1_pending_addr_q <= map_bank1_waddr;
        map_bank1_pending_data_q <= map_bank1_wdata;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      count_q <= '0;
      for (int unsigned i = 0; i < BANK_ENTRIES; i++) begin
        valid_bank0_q[i] <= 1'b0;
        valid_bank1_q[i] <= 1'b0;
      end
    end else if (recovery_valid_i && recovery_found_o) begin
      count_q <= recovery_count;
      for (int unsigned i = 0; i < BANK_ENTRIES; i++) begin
        if (valid_bank0_q[i] &&
            (rob_distance(rob_ptr_bank0_q[i], recovery_rob_ptr) <
             rob_distance(rob_tail_i, recovery_rob_ptr)))
          valid_bank0_q[i] <= 1'b0;
        if (valid_bank1_q[i] &&
            (rob_distance(rob_ptr_bank1_q[i], recovery_rob_ptr) <
             rob_distance(rob_tail_i, recovery_rob_ptr)))
          valid_bank1_q[i] <= 1'b0;
      end
    end else begin
      count_q <= count_q + COUNT_W'(map_bank0_we) + COUNT_W'(map_bank1_we) -
                 COUNT_W'(release_valid_i);
      if (release_valid_i) begin
        if (release_id_i[BANK_ID_BIT])
          valid_bank1_q[release_id_i[INDEX_W-1:0]] <= 1'b0;
        else
          valid_bank0_q[release_id_i[INDEX_W-1:0]] <= 1'b0;
      end
      if (map_bank0_we) begin
        valid_bank0_q[map_bank0_waddr] <= 1'b1;
        rob_ptr_bank0_q[map_bank0_waddr] <= rob_ptr_bank0_wdata;
      end
      if (map_bank1_we) begin
        valid_bank1_q[map_bank1_waddr] <= 1'b1;
        rob_ptr_bank1_q[map_bank1_waddr] <= rob_ptr_bank1_wdata;
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    assert (ENTRIES == 8 && ((ENTRIES & 1) == 0))
      else $fatal(1, "banked checkpoints require an even eight-entry capacity");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (count_o <= COUNT_W'(ENTRIES))
        else $fatal(1, "checkpoint population exceeded architectural capacity");
      assert (!(((alloc_valid_i == 2'b01) || (alloc_valid_i == 2'b10)) &&
                !flush_i && !recovery_valid_i &&
                (count_o < COUNT_W'(ENTRIES)) && !(|alloc_accept_o)))
        else $fatal(1, "checkpoint allocation rejected despite logical capacity");
      assert (!((&alloc_valid_i) &&
                alloc_two_ready_o &&
                (alloc_accept_o != 2'b11)))
        else $fatal(1, "dual checkpoint allocation rejected despite capacity");
      assert (!((&alloc_valid_i) && !alloc_two_ready_o &&
                (alloc_accept_o != 2'b00)))
        else $fatal(1, "dual checkpoint allocation was only partially accepted");
    end
  end
`endif
endmodule
