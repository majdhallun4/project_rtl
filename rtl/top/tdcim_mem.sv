// =============================================================================
// tdcim_mem.sv  -  Compiler-SRAM memory subsystem for tdcim_top
//
//   imem_obi     : 16 KiB code memory   = 4 x sram_1024x32  (existing macro)
//   dmem_obi     :  4 KiB data memory   = 1 x sram_1024x32  (existing macro)
//   obi_arb_2to1 : shares imem between Ibex instr port and the data bus
//
// Why this shape:
//   * Only ONE macro type is used: the existing sram_1024x32 (no write mask).
//     5 instances total: 4 for IMEM, 1 for DMEM.
//   * The ARM macros are single-port; Ibex has two ports -> IMEM needs an arbiter.
//   * Byte/halfword stores to DMEM are done as read-modify-write:
//        cycle 1 : read old word      (gnt_o = 0 -> Ibex holds req/addr/wdata)
//        cycle 2 : write merged word  (gnt_o = 1)
//     The simple_system `bus` has no device_gnt input, so tdcim_top gates Ibex's
//     data_gnt_i with dmem gnt_o. Reads and full-word stores are 1 cycle.
//   * rvalid is returned one cycle after every granted request (reads AND writes).
//   * IMEM is only written by the loader (full-word writes allowed); sub-word
//     writes to IMEM are dropped and answered with err (-> store access fault).
// =============================================================================

// -----------------------------------------------------------------------------
// Tie values for the compiler macros' margin pins. They MUST equal the
// `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA/EMAW/EMAS_VALUE defines at the top of the
// generated sram_*.v. Synthesis only sees these constants; in simulation the
// wrappers compare them against the defines and stop with $fatal on mismatch.
// -----------------------------------------------------------------------------
package sram_tie_pkg;
  localparam logic [2:0] EMA  = 3'd7;
  localparam logic [1:0] EMAW = 2'd3;
  localparam logic       EMAS = 1'b1;
endpackage

// =============================================================================
// IMEM : 16 KiB, 4 banks of sram_1024x32.  addr[13:12] = bank, addr[11:2] = word
// =============================================================================
module imem_obi (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o
);
  logic [3:0]  cen_n;
  logic        wen_n;
  logic [1:0]  bank, bank_q;
  logic        wr_ok;
  logic [31:0] q [4];

  assign bank  = addr_i[13:12];
  assign wr_ok = we_i & (be_i == 4'hF);
  assign wen_n = ~wr_ok;
  assign gnt_o = req_i;                       // always ready

  always_comb begin
    cen_n = 4'hF;
    if (req_i && (!we_i || wr_ok)) begin      // X on req_i in sim -> CEN stays 1
      cen_n[bank] = 1'b0;
    end
  end

  for (genvar b = 0; b < 4; b++) begin : gen_bank
    sram_1024x32 u_mem (
      .Q(q[b]), .CLK(clk_i), .CEN(cen_n[b]), .WEN(wen_n),
      .A(addr_i[11:2]), .D(wdata_i),
      .EMA(sram_tie_pkg::EMA), .EMAW(sram_tie_pkg::EMAW), .EMAS(sram_tie_pkg::EMAS),
      .RET1N(1'b1)
    );
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_o <= 1'b0;
      err_o    <= 1'b0;
      bank_q   <= '0;
    end else begin
      rvalid_o <= req_i;
      err_o    <= req_i & we_i & ~wr_ok;      // sub-word store to code memory
      if (req_i) bank_q <= bank;
    end
  end

  assign rdata_o = q[bank_q];

`ifndef SYNTHESIS
`ifdef SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA_VALUE
  initial begin
    if (sram_tie_pkg::EMA  != `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA_VALUE  ||
        sram_tie_pkg::EMAW != `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAW_VALUE ||
        sram_tie_pkg::EMAS != `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAS_VALUE)
      $fatal(1, "sram_tie_pkg EMA/EMAW/EMAS = %0d/%0d/%0d, macro requires %0d/%0d/%0d -> fix sram_tie_pkg",
             sram_tie_pkg::EMA, sram_tie_pkg::EMAW, sram_tie_pkg::EMAS,
             `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA_VALUE,
             `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAW_VALUE,
             `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAS_VALUE);
  end
`endif
`endif

`ifndef SYNTHESIS
  // Backdoor load. Files: <prefix>_imem_b0..3.memb (1024 lines, 32-bit binary).
  // Call while CEN is high (i.e. during reset).
  task automatic load(input logic [8*200-1:0] prefix);
    gen_bank[0].u_mem.loadmem({prefix, "_imem_b0.memb"});
    gen_bank[1].u_mem.loadmem({prefix, "_imem_b1.memb"});
    gen_bank[2].u_mem.loadmem({prefix, "_imem_b2.memb"});
    gen_bank[3].u_mem.loadmem({prefix, "_imem_b3.memb"});
  endtask
`endif
endmodule


// =============================================================================
// DMEM : 4 KiB, 1 x sram_1024x32, read-modify-write for sub-word stores.
// addr[11:2] = word
// =============================================================================
module dmem_obi (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        req_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [31:0] addr_i,
  input  logic [31:0] wdata_i,
  output logic        gnt_o,      // LOW for one cycle on a sub-word store
  output logic        rvalid_o,
  output logic [31:0] rdata_o,
  output logic        err_o
);
  logic        cen_n, wen_n;
  logic [31:0] d, q;
  logic        partial_wr;
  logic        rmw_q;             // 1 = old word is on Q, write merged word now
  logic [31:0] bit_mask;

  assign partial_wr = req_i & we_i & (be_i != 4'hF);
  assign bit_mask   = {{8{be_i[3]}}, {8{be_i[2]}}, {8{be_i[1]}}, {8{be_i[0]}}};

  always_comb begin
    cen_n = 1'b1;
    wen_n = 1'b1;
    d     = wdata_i;
    gnt_o = 1'b0;
    if (req_i) begin                        // X on req_i in sim -> CEN stays 1
      cen_n = 1'b0;
      if (!we_i) begin                      // read
        gnt_o = 1'b1;
      end else if (be_i == 4'hF) begin      // full-word store
        wen_n = 1'b0;
        gnt_o = 1'b1;
      end else if (!rmw_q) begin            // RMW phase 1: read old word, stall
        wen_n = 1'b1;
      end else begin                        // RMW phase 2: write merged word
        wen_n = 1'b0;
        d     = (q & ~bit_mask) | (wdata_i & bit_mask);
        gnt_o = 1'b1;
      end
    end
  end

  sram_1024x32 u_mem (
    .Q(q), .CLK(clk_i), .CEN(cen_n), .WEN(wen_n),
    .A(addr_i[11:2]), .D(d),
    .EMA(sram_tie_pkg::EMA), .EMAW(sram_tie_pkg::EMAW), .EMAS(sram_tie_pkg::EMAS),
    .RET1N(1'b1)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rmw_q    <= 1'b0;
      rvalid_o <= 1'b0;
    end else begin
      rmw_q    <= partial_wr & ~rmw_q;
      rvalid_o <= req_i & gnt_o;
    end
  end

  assign rdata_o = q;
  assign err_o   = 1'b0;

`ifndef SYNTHESIS
`ifdef SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA_VALUE
  initial begin
    if (sram_tie_pkg::EMA  != `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA_VALUE  ||
        sram_tie_pkg::EMAW != `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAW_VALUE ||
        sram_tie_pkg::EMAS != `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAS_VALUE)
      $fatal(1, "sram_tie_pkg EMA/EMAW/EMAS = %0d/%0d/%0d, macro requires %0d/%0d/%0d -> fix sram_tie_pkg",
             sram_tie_pkg::EMA, sram_tie_pkg::EMAW, sram_tie_pkg::EMAS,
             `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMA_VALUE,
             `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAW_VALUE,
             `SRAM_SP_HSC_RVT_RVT_ARM_REF_EMAS_VALUE);
  end
`endif
`endif

`ifndef SYNTHESIS
  // Backdoor load. File: <prefix>_dmem.memb (1024 lines, 32-bit binary).
  task automatic load(input logic [8*200-1:0] prefix);
    u_mem.loadmem({prefix, "_dmem.memb"});
  endtask
`endif
endmodule


// =============================================================================
// obi_arb_2to1 : data (priority) + instr -> one always-ready slave
// With data priority, the data master is always granted in its request cycle,
// which is exactly what the simple_system bus requires (it has no device_gnt).
// Instruction fetch simply waits one cycle when it collides.
// =============================================================================
module obi_arb_2to1 (
  input  logic        clk_i,
  input  logic        rst_ni,
  // master D: from bus (device side)
  input  logic        d_req_i,
  input  logic        d_we_i,
  input  logic [3:0]  d_be_i,
  input  logic [31:0] d_addr_i,
  input  logic [31:0] d_wdata_i,
  output logic        d_gnt_o,
  output logic        d_rvalid_o,
  output logic [31:0] d_rdata_o,
  output logic        d_err_o,
  // master I: Ibex instruction port
  input  logic        i_req_i,
  input  logic [31:0] i_addr_i,
  output logic        i_gnt_o,
  output logic        i_rvalid_o,
  output logic [31:0] i_rdata_o,
  output logic        i_err_o,
  // slave
  output logic        s_req_o,
  output logic        s_we_o,
  output logic [3:0]  s_be_o,
  output logic [31:0] s_addr_o,
  output logic [31:0] s_wdata_o,
  input  logic        s_gnt_i,
  input  logic        s_rvalid_i,
  input  logic [31:0] s_rdata_i,
  input  logic        s_err_i
);
  logic sel_d, owner_d_q;

  assign sel_d     = d_req_i;
  assign s_req_o   = d_req_i | i_req_i;
  assign s_we_o    = sel_d & d_we_i;
  assign s_be_o    = sel_d ? d_be_i   : 4'hF;
  assign s_addr_o  = sel_d ? d_addr_i : i_addr_i;
  assign s_wdata_o = d_wdata_i;

  assign d_gnt_o   = s_gnt_i &  sel_d;
  assign i_gnt_o   = s_gnt_i & ~sel_d & i_req_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)                 owner_d_q <= 1'b0;
    else if (s_req_o && s_gnt_i) owner_d_q <= sel_d;
  end

  assign d_rvalid_o = s_rvalid_i &  owner_d_q;
  assign i_rvalid_o = s_rvalid_i & ~owner_d_q;
  assign d_rdata_o  = s_rdata_i;
  assign i_rdata_o  = s_rdata_i;
  assign d_err_o    = s_err_i  &  owner_d_q;
  assign i_err_o    = s_err_i  & ~owner_d_q;
endmodule
