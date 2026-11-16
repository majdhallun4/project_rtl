/**
 * bus_decoder.sv - Simple address decoder for macro CSRs
 *
 * This module is the Phase 2 bus decoder that routes CPU memory accesses
 * into the macro control CSR region.
 *
 * Current mapping:
 *   0x4000_0000 - 0x4000_00FF : macro CSR region
 */

// Timescale only for simulation: the vendor RTL (Ibex/prim/systolic array)
// has none, so a timescale here would leak into later files in the list.
`ifndef SYNTHESIS
`timescale 1ns/1ps
`endif

module bus_decoder #(
    parameter BASE_ADDR = 32'h4000_0000,
    parameter ADDR_MASK = 32'hFFFF_FF00
) (
    input  logic        clk,
    input  logic        rst_n,

    // CPU-side bus interface
    input  logic [31:0] addr_i,
    input  logic [31:0] wdata_i,
    input  logic        write_i,
    input  logic        read_i,
    output logic [31:0] rdata_o,
    output logic        valid_o,

    // Macro CSR slave interface
    output logic [7:0]  macro_addr_o,
    output logic [31:0] macro_wdata_o,
    output logic        macro_write_o,
    output logic        macro_read_o,
    input  logic [31:0] macro_rdata_i
);

    logic macro_sel;

    assign macro_sel = ((addr_i & ADDR_MASK) == BASE_ADDR);
    assign macro_addr_o = addr_i[7:0];
    assign macro_wdata_o = wdata_i;
    assign macro_write_o = write_i && macro_sel;
    assign macro_read_o  = read_i && macro_sel;

    assign rdata_o = macro_sel ? macro_rdata_i : 32'h0;
    assign valid_o = macro_sel && (write_i || read_i);

endmodule
