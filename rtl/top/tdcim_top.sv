/**
 * tdcim_top.sv - Phase 2 integration top, compiler-SRAM version
 *
 * Instantiates: Ibex (ibex_top for synthesis, ibex_top_tracing for simulation),
 * the simple_system bus, IMEM (16 KiB, 4 x sram_1024x32) shared by the instruction
 * port and the data bus through obi_arb_2to1, DMEM (4 KiB, 1 x sram_1024x32),
 * simulator_ctrl (simulation only), timer, and macro_csr + systolic array.
 *
 * Memory map (matches fw/linker/16k_4k.ld, no firmware changes needed):
 *   0x0002_0000  SimCtrl  1 KiB   (console; synthesizable stub in SYNTHESIS)
 *   0x0003_0000  Timer    1 KiB
 *   0x0010_0000  IMEM    16 KiB   (FLASH region: .isr_vector/.text/.rodata/.data LMA)
 *   0x0018_0000  DMEM     4 KiB   (SRAM region: .data/.bss/stack)
 *   0x4000_0000  Macro    4 KiB
 *
 * Only the existing ARM macro sram_1024x32 is used (5 instances).
 *
 * Synthesis: compile with SYNTHESIS defined (Genus: read_hdl -define SYNTHESIS).
 */

`timescale 1ns/1ps

// Firmware preload prefix can be given from the xrun command line:
//   +define+MEM_INIT_PREFIX=\"<dir>/tdcim_fw\"
`ifdef MEM_INIT_PREFIX
  `define TDCIM_MEM_INIT_PREFIX `MEM_INIT_PREFIX
`else
  `define TDCIM_MEM_INIT_PREFIX ""
`endif

`ifdef SYNTHESIS
  `define TDCIM_IBEX_TOP ibex_top
`else
  `define TDCIM_IBEX_TOP ibex_top_tracing
`endif

module tdcim_top #(
  // Kept only so the existing tb_tdcim_top.sv compiles unchanged. Not used any more.
  parameter string SRAMInitFile = "",
  // Backdoor-load prefix for simulation, e.g. "build/main" loads
  // build/main_imem_b0..3.memb and build/main_dmem.memb (see vmem_split.py).
  // Empty = no preload. Ignored in synthesis.
  parameter MemInitPrefix = `TDCIM_MEM_INIT_PREFIX
) (
  input logic IO_CLK,
  input logic IO_RST_N
);

  // Parameters and device indices
  localparam int Imem      = 0;
  localparam int SimCtrl   = 1;
  localparam int Timer     = 2;
  localparam int Macro     = 3;
  localparam int Dmem      = 4;
  localparam int NrDevices = 5;
  localparam int NrHosts   = 1;

  // Top-level clocks / reset
  logic clk_sys;
  logic rst_sys_n;
  assign clk_sys   = IO_CLK;
  assign rst_sys_n = IO_RST_N;

  // Host (core) side signals
  logic           host_req    [NrHosts];
  logic           host_gnt    [NrHosts];
  logic [31:0]    host_addr   [NrHosts];
  logic           host_we     [NrHosts];
  logic [ 3:0]    host_be     [NrHosts];
  logic [31:0]    host_wdata  [NrHosts];
  logic           host_rvalid [NrHosts];
  logic [31:0]    host_rdata  [NrHosts];
  logic           host_err    [NrHosts];

  // Device (slave) side signals
  logic           device_req    [NrDevices];
  logic [31:0]    device_addr   [NrDevices];
  logic           device_we     [NrDevices];
  logic [ 3:0]    device_be     [NrDevices];
  logic [31:0]    device_wdata  [NrDevices];
  logic           device_rvalid [NrDevices];
  logic [31:0]    device_rdata  [NrDevices];
  logic           device_err    [NrDevices];

  // Device address map
  logic [31:0] cfg_device_addr_base [NrDevices];
  logic [31:0] cfg_device_addr_mask [NrDevices];
  assign cfg_device_addr_base[Imem]    = 32'h0010_0000;  // code memory
  assign cfg_device_addr_mask[Imem]    = ~32'h3FFF;      // 16 KiB
  assign cfg_device_addr_base[SimCtrl] = 32'h0002_0000;  // simulator control (console)
  assign cfg_device_addr_mask[SimCtrl] = ~32'h3FF;       // 1 KiB
  assign cfg_device_addr_base[Timer]   = 32'h0003_0000;  // timer
  assign cfg_device_addr_mask[Timer]   = ~32'h3FF;       // 1 KiB
  assign cfg_device_addr_base[Macro]   = 32'h4000_0000;  // macro CSR region
  assign cfg_device_addr_mask[Macro]   = ~32'hFFF;       // 4 KiB (A/B/C data blocks)
  assign cfg_device_addr_base[Dmem]    = 32'h0018_0000;  // data memory
  assign cfg_device_addr_mask[Dmem]    = ~32'hFFF;       // 4 KiB

  // Instruction fetch signals (Ibex instr port -> obi_arb_2to1 -> IMEM)
  logic        instr_req;
  logic        instr_gnt;
  logic        instr_rvalid;
  logic [31:0] instr_addr;
  logic [31:0] instr_rdata;
  logic        instr_err;

  // Data-port grant. The simple_system bus grants every request immediately
  // (it has no device_gnt input). DMEM needs one extra cycle for byte/halfword
  // stores (read-modify-write), so its gnt is merged in here. The bus itself
  // needs no change: its response select is re-registered every cycle and Ibex
  // holds req/addr/be/wdata stable until gnt, so the rvalid of the granted
  // (second) cycle is routed back correctly.
  logic data_gnt;
  logic dmem_gnt;
  assign data_gnt = host_gnt[0] & ~(device_req[Dmem] & ~dmem_gnt);

  // simple bus
  bus #(.NrDevices(NrDevices), .NrHosts(NrHosts), .DataWidth(32), .AddressWidth(32)) u_bus (
    .clk_i               (clk_sys),
    .rst_ni              (rst_sys_n),
    .host_req_i          (host_req),
    .host_gnt_o          (host_gnt),
    .host_addr_i         (host_addr),
    .host_we_i           (host_we),
    .host_be_i           (host_be),
    .host_wdata_i        (host_wdata),
    .host_rvalid_o       (host_rvalid),
    .host_rdata_o        (host_rdata),
    .host_err_o          (host_err),
    .device_req_o        (device_req),
    .device_addr_o       (device_addr),
    .device_we_o         (device_we),
    .device_be_o         (device_be),
    .device_wdata_o      (device_wdata),
    .device_rvalid_i     (device_rvalid),
    .device_rdata_i      (device_rdata),
    .device_err_i        (device_err),
    .cfg_device_addr_base(cfg_device_addr_base),
    .cfg_device_addr_mask(cfg_device_addr_mask)
  );

  // Ibex (single hart). ibex_top_tracing = ibex_top + trace logging (sim only).
  `TDCIM_IBEX_TOP u_ibex_top (
    .clk_i                     (clk_sys),
    .rst_ni                    (rst_sys_n),
    .test_en_i                 (1'b0),
    .scan_rst_ni               (1'b1),
    .ram_cfg_icache_tag_i      (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),
    .ram_cfg_rsp_icache_tag_o  (),
    .ram_cfg_icache_data_i     (prim_ram_1p_pkg::RAM_1P_CFG_DEFAULT),
    .ram_cfg_rsp_icache_data_o (),
    .hart_id_i                 (32'b0),
    .boot_addr_i               (32'h0010_0000),
    .instr_req_o               (instr_req),
    .instr_gnt_i               (instr_gnt),
    .instr_rvalid_i            (instr_rvalid),
    .instr_addr_o              (instr_addr),
    .instr_rdata_i             (instr_rdata),
    .instr_rdata_intg_i        (7'b0),
    .instr_err_i               (instr_err),
    .data_req_o                (host_req[0]),
    .data_gnt_i                (data_gnt),
    .data_rvalid_i             (host_rvalid[0]),
    .data_we_o                 (host_we[0]),
    .data_be_o                 (host_be[0]),
    .data_addr_o               (host_addr[0]),
    .data_wdata_o              (host_wdata[0]),
    .data_wdata_intg_o         (),
    .data_rdata_i              (host_rdata[0]),
    .data_rdata_intg_i         (7'b0),
    .data_err_i                (host_err[0]),
    .irq_software_i            (1'b0),
    .irq_timer_i               (1'b0),
    .irq_external_i            (1'b0),
    .irq_fast_i                (15'b0),
    .irq_nm_i                  (1'b0),
    .scramble_key_valid_i      ('0),
    .scramble_key_i            ('0),
    .scramble_nonce_i          ('0),
    .scramble_req_o            (),
    .debug_req_i               (1'b0),
    .crash_dump_o              (),
    .double_fault_seen_o       (),
    .fetch_enable_i            (ibex_pkg::IbexMuBiOn),
    .alert_minor_o             (),
    .alert_major_internal_o    (),
    .alert_major_bus_o         (),
    .core_sleep_o              (),
    .lockstep_cmp_en_o         (),
    .data_req_shadow_o         (),
    .data_we_shadow_o          (),
    .data_be_shadow_o          (),
    .data_addr_shadow_o        (),
    .data_wdata_shadow_o       (),
    .data_wdata_intg_shadow_o  (),
    .instr_req_shadow_o        (),
    .instr_addr_shadow_o       ()
  );

  // ---------------------------------------------------------------------------
  // IMEM (device 0) - shared by bus (data port: .rodata, .data LMA) and instr port
  // ---------------------------------------------------------------------------
  logic        imem_req, imem_we, imem_gnt, imem_rvalid, imem_err;
  logic [3:0]  imem_be;
  logic [31:0] imem_addr, imem_wdata, imem_rdata;
  logic        imem_bus_gnt_unused;

  obi_arb_2to1 u_imem_arb (
    .clk_i      (clk_sys),
    .rst_ni     (rst_sys_n),
    .d_req_i    (device_req[Imem]),
    .d_we_i     (device_we[Imem]),
    .d_be_i     (device_be[Imem]),
    .d_addr_i   (device_addr[Imem]),
    .d_wdata_i  (device_wdata[Imem]),
    .d_gnt_o    (imem_bus_gnt_unused),   // always = d_req (data has priority)
    .d_rvalid_o (device_rvalid[Imem]),
    .d_rdata_o  (device_rdata[Imem]),
    .d_err_o    (device_err[Imem]),
    .i_req_i    (instr_req),
    .i_addr_i   (instr_addr),
    .i_gnt_o    (instr_gnt),
    .i_rvalid_o (instr_rvalid),
    .i_rdata_o  (instr_rdata),
    .i_err_o    (instr_err),
    .s_req_o    (imem_req),
    .s_we_o     (imem_we),
    .s_be_o     (imem_be),
    .s_addr_o   (imem_addr),
    .s_wdata_o  (imem_wdata),
    .s_gnt_i    (imem_gnt),
    .s_rvalid_i (imem_rvalid),
    .s_rdata_i  (imem_rdata),
    .s_err_i    (imem_err)
  );

  imem_obi u_imem (
    .clk_i    (clk_sys),
    .rst_ni   (rst_sys_n),
    .req_i    (imem_req),
    .we_i     (imem_we),
    .be_i     (imem_be),
    .addr_i   (imem_addr),
    .wdata_i  (imem_wdata),
    .gnt_o    (imem_gnt),
    .rvalid_o (imem_rvalid),
    .rdata_o  (imem_rdata),
    .err_o    (imem_err)
  );

  // ---------------------------------------------------------------------------
  // DMEM (device 4) - data port only, 1 x sram_1024x32 with read-modify-write
  // ---------------------------------------------------------------------------
  dmem_obi u_dmem (
    .clk_i    (clk_sys),
    .rst_ni   (rst_sys_n),
    .req_i    (device_req[Dmem]),
    .we_i     (device_we[Dmem]),
    .be_i     (device_be[Dmem]),
    .addr_i   (device_addr[Dmem]),
    .wdata_i  (device_wdata[Dmem]),
    .gnt_o    (dmem_gnt),                // low 1 cycle on sub-word stores
    .rvalid_o (device_rvalid[Dmem]),
    .rdata_o  (device_rdata[Dmem]),
    .err_o    (device_err[Dmem])
  );

`ifndef SYNTHESIS
  // Backdoor preload while reset holds every CEN high.
  initial begin
    if (MemInitPrefix != "") begin
      #1;
      u_imem.load(MemInitPrefix);
      u_dmem.load(MemInitPrefix);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // simulator_ctrl (device 1) - uses $fopen/$fwrite/$finish -> simulation only.
  // In synthesis a stub answers every access so console writes never hang Ibex.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  simulator_ctrl #(.LogName("tdcim_top_sim.log")) u_simulator_ctrl (
    .clk_i     (clk_sys),
    .rst_ni    (rst_sys_n),
    .req_i     (device_req[SimCtrl]),
    .we_i      (device_we[SimCtrl]),
    .be_i      (device_be[SimCtrl]),
    .addr_i    (device_addr[SimCtrl]),
    .wdata_i   (device_wdata[SimCtrl]),
    .rvalid_o  (device_rvalid[SimCtrl]),
    .rdata_o   (device_rdata[SimCtrl])
  );
`else
  logic simctrl_rvalid_q;
  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) simctrl_rvalid_q <= 1'b0;
    else            simctrl_rvalid_q <= device_req[SimCtrl];
  end
  assign device_rvalid[SimCtrl] = simctrl_rvalid_q;
  assign device_rdata[SimCtrl]  = 32'h0;
`endif
  assign device_err[SimCtrl] = 1'b0;

  // timer (device 2)
  timer #(.DataWidth(32), .AddressWidth(32)) u_timer (
    .clk_i          (clk_sys),
    .rst_ni         (rst_sys_n),
    .timer_req_i    (device_req[Timer]),
    .timer_we_i     (device_we[Timer]),
    .timer_be_i     (device_be[Timer]),
    .timer_addr_i   (device_addr[Timer]),
    .timer_wdata_i  (device_wdata[Timer]),
    .timer_rvalid_o (device_rvalid[Timer]),
    .timer_rdata_o  (device_rdata[Timer]),
    .timer_err_o    (device_err[Timer]),
    .timer_intr_o   ()
  );

  // ---------------------------------------------------------------------------
  // Macro CSR (device 3) + systolic array  (unchanged)
  // ---------------------------------------------------------------------------
  logic [11:0] macro_addr;
  logic [31:0] macro_rdata;
  logic        macro_write;
  logic        macro_read;
  logic        done_irq;
  logic        error_irq;
  logic        macro_en;
  logic [1:0]  macro_mode;
  logic        macro_start;

  // Data plane between macro_csr and the systolic array.
  logic [31:0] macro_a_out [0:15];
  logic [31:0] macro_b_out [0:15];
  logic [31:0] macro_c_in  [0:15];

  // Packed operand/result matrices for topSystolicArray (N=4), row-major:
  // word i <-> [row][col] = [i/4][i%4].
  logic [3:0][3:0][7:0]  systolic_a;
  logic [3:0][3:0][7:0]  systolic_b;
  logic [3:0][3:0][31:0] systolic_c;
  logic                  systolic_valid_result;

  genvar gr, gc;
  generate
    for (gr = 0; gr < 4; gr++) begin : gen_row
      for (gc = 0; gc < 4; gc++) begin : gen_col
        assign systolic_a[gr][gc]  = macro_a_out[gr*4+gc][7:0];
        assign systolic_b[gr][gc]  = macro_b_out[gr*4+gc][7:0];
        assign macro_c_in[gr*4+gc] = systolic_c[gr][gc];
      end
    end
  endgenerate

  assign macro_addr  = device_addr[Macro][11:0];
  assign macro_write = device_req[Macro] &&  device_we[Macro];
  assign macro_read  = device_req[Macro] && !device_we[Macro];

  macro_csr #(.CYCLE_DELAY(100)) u_macro_csr (
    .clk        (clk_sys),
    .rst_n      (rst_sys_n),
    .reg_addr   (macro_addr),
    .reg_wdata  (device_wdata[Macro]),
    .reg_rdata  (macro_rdata),
    .reg_write  (macro_write),
    .reg_read   (macro_read),
    .done_irq   (done_irq),
    .error_irq  (error_irq),
    .macro_en   (macro_en),
    .macro_mode (macro_mode),
    .macro_done (systolic_valid_result),
    .macro_a_out(macro_a_out),
    .macro_b_out(macro_b_out),
    .macro_c_in (macro_c_in),
    .macro_start(macro_start)
  );

  // 4x4 systolic array (tms4517/2D-Systolic-Array-Multiplier); active-high async reset.
  topSystolicArray #(.N(4)) u_systolic_array (
    .i_clk         (clk_sys),
    .i_arst        (~rst_sys_n),
    .i_a           (systolic_a),
    .i_b           (systolic_b),
    .i_validInput  (macro_start),
    .o_c           (systolic_c),
    .o_validResult (systolic_valid_result)
  );

  // Registered macro response (rvalid one cycle after every request, incl. writes).
  logic        macro_rvalid_q;
  logic [31:0] macro_rdata_q;

  always_ff @(posedge clk_sys or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
      macro_rvalid_q <= 1'b0;
      macro_rdata_q  <= 32'h0;
    end else begin
      macro_rvalid_q <= device_req[Macro];
      if (device_req[Macro] && !device_we[Macro]) begin
        macro_rdata_q <= macro_rdata;
      end
    end
  end

  assign device_rdata[Macro]  = macro_rdata_q;
  assign device_rvalid[Macro] = macro_rvalid_q;
  assign device_err[Macro]    = 1'b0;

endmodule
