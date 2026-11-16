/**
 * macro_csr.sv - TD-CiM macro control/status registers + data plane
 *
 * Phase 3: CSR block extended with A/B/C matrix data registers for
 * systolic-array macro integration (tms4517/2D-Systolic-Array-Multiplier, N=4).
 * - Registers: CTRL, STATUS, CONFIG0/1, RESULT0/1, IRQ_EN, IRQ_STATUS
 * - Data plane: A_DATA, B_DATA (firmware-writable operands),
 *               C_DATA (result, populated from macro output on DONE)
 * - Sequencer: Simple state machine (IDLE -> BUSY -> DONE on macro_done)
 * - Interface: Memory-mapped read/write (32-bit data bus, 12-bit byte address)
 *
 * Memory map (per docs/MEMORY_MAP.md):
 *   0x000: MACRO_CTRL      [0]=START, [1]=SOFT_RESET, [3:2]=MODE
 *   0x004: MACRO_STATUS    [0]=BUSY, [1]=DONE, [2]=ERROR
 *   0x008: MACRO_CONFIG0   Timing parameter 0
 *   0x00C: MACRO_CONFIG1   Timing parameter 1
 *   0x010: MACRO_RESULT0   Readout/TDC result low (legacy placeholder)
 *   0x014: MACRO_RESULT1   Readout/TDC result high (legacy placeholder)
 *   0x018: MACRO_IRQ_EN    [0]=DONE_EN, [1]=ERROR_EN
 *   0x01C: MACRO_IRQ_STATUS Write-1-to-clear flags
 *   0x100-0x13C: A_DATA[0:15]  Operand matrix A, 16 words (4x4, N=4)
 *   0x300-0x33C: B_DATA[0:15]  Operand matrix B, 16 words (4x4, N=4)
 *   0x500-0x53C: C_DATA[0:15]  Result matrix C, 16 words (read-only,
 *                              latched from macro output on DONE)
 */

// Timescale only for simulation: the vendor RTL (Ibex/prim/systolic array)
// has none, so a timescale here would leak into later files in the list.
`ifndef SYNTHESIS
`timescale 1ns/1ps
`endif

/* verilator lint_off UNUSEDPARAM */
module macro_csr #(
    parameter CYCLE_DELAY = 100  // Legacy (fake execution length); no longer used
) (
    input  logic        clk,
    input  logic        rst_n,

    // Memory-mapped register access (from bus decoder)
    input  logic [11:0] reg_addr,      // Byte address [11:0] (widened for A/B/C blocks)
    input  logic [31:0] reg_wdata,     // Write data
    output logic [31:0] reg_rdata,     // Read data
    input  logic        reg_write,     // Write strobe
    input  logic        reg_read,      // Read strobe

    // Interrupt outputs
    output logic        done_irq,      // To IRQ aggregator
    output logic        error_irq,     // To IRQ aggregator

    // Macro analog interface (placeholder)
    // - Real macro would have actual analog signals
    output logic        macro_en,      // Enable macro
    output logic [1:0]  macro_mode,    // Operating mode
    input  logic        macro_done,    // Status from macro (wire to o_validResult in Step 3)

    // Macro data plane interface (Step 3: wire to systolic array ports)
    output logic [31:0] macro_a_out [0:15],  // Operand A -> macro inputs
    output logic [31:0] macro_b_out [0:15],  // Operand B -> macro inputs
    input  logic [31:0] macro_c_in  [0:15],  // Result C <- macro outputs (latched on DONE)
    output logic         macro_start          // One-cycle pulse -> macro's i_validInput
);
/* verilator lint_on UNUSEDPARAM */

    // ===== Register File =====
    logic [31:0] macro_ctrl;
    logic [31:0] macro_status;
    logic [31:0] macro_config0;
    logic [31:0] macro_config1;
    logic [31:0] macro_result0;
    logic [31:0] macro_result1;
    logic [31:0] macro_irq_en;
    logic [31:0] macro_irq_status;

    // ===== Data plane register blocks (N=4, 16 words each) =====
    logic [31:0] a_data [0:15];  // 0x100-0x13C, firmware-writable
    logic [31:0] b_data [0:15];  // 0x300-0x33C, firmware-writable
    logic [31:0] c_data [0:15];  // 0x500-0x53C, read-only, latched on DONE

    // Word index into a 16-word block from a 12-bit byte address
    logic [3:0]  word_idx;
    assign word_idx = reg_addr[5:2];

    // Reads are combinational and side-effect free, so the read strobe is unused.
    logic unused_reg_read;
    assign unused_reg_read = reg_read;

    // ===== Control signals =====
    logic        start_pulse;           // START bit write (self-clearing)
    logic        soft_reset;            // Software reset
    logic [1:0]  mode;                  // Operating mode

    // ===== Sequencer state machine =====
    typedef enum logic [1:0] {
        IDLE   = 2'b00,
        BUSY   = 2'b01,
        DONE   = 2'b10
    } state_e;

    state_e       state, state_next;
    logic [31:0]  cycle_count, cycle_count_next;

    // ===== Wire assignments =====
    assign start_pulse = reg_write && (reg_addr == 12'h000) && reg_wdata[0];
    assign soft_reset  = macro_ctrl[1];
    assign mode        = macro_ctrl[3:2];

    // start_pulse is already exactly the one-cycle pulse the systolic
    // array's i_validInput needs (it's driven by a single register-write
    // strobe, not a level), so it's exposed directly.
    assign macro_start = start_pulse;

    // Data plane: stored operands feed the macro directly (Step 3 wires
    // these to the systolic array's input ports). Explicit loop instead of
    // a whole-array continuous assign, since unpacked-array assign is not
    // reliably supported the same way across simulators.
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            macro_a_out[i] = a_data[i];
            macro_b_out[i] = b_data[i];
        end
    end

    // Status bits
    assign macro_status[0] = (state == BUSY);                  // BUSY
    assign macro_status[1] = (state == DONE);                  // DONE
    assign macro_status[2] = 1'b0;                             // ERROR (placeholder)
    assign macro_status[31:3] = 29'b0;

    // Macro interface (output enable and mode)
    assign macro_en   = (state == BUSY);
    assign macro_mode = mode;

    // IRQ generation
    assign done_irq  = (state == DONE) && macro_irq_en[0];    // DONE_IRQ if DONE_EN set
    assign error_irq = macro_irq_status[1] && macro_irq_en[1]; // ERROR_IRQ if ERROR_EN set

    // ===== Synchronous logic: State machine =====
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cycle_count <= 32'h0;
        end else if (soft_reset) begin
            // Soft reset returns to IDLE
            state <= IDLE;
            cycle_count <= 32'h0;
        end else begin
            state <= state_next;
            cycle_count <= cycle_count_next;
        end
    end

    // ===== Next-state logic =====
    always_comb begin
        state_next = state;
        cycle_count_next = cycle_count;

        case (state)
            IDLE: begin
                if (start_pulse) begin
                    state_next = BUSY;
                    cycle_count_next = 32'h0;
                end
            end

            BUSY: begin
                if (macro_done) begin
                    // Real macro asserted completion (o_validResult)
                    state_next = DONE;
                end else begin
                    cycle_count_next = cycle_count + 1'b1;
                end
            end

            DONE: begin
                // Stay in DONE until next START (or reset)
                // Firmware reads STATUS, then writes START again
                if (start_pulse) begin
                    state_next = BUSY;
                    cycle_count_next = 32'h0;
                end
            end

            default: state_next = IDLE;
        endcase
    end

    // ===== Synchronous logic: Register writes =====
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            macro_ctrl       <= 32'h0;
            macro_config0    <= 32'h0;
            macro_config1    <= 32'h0;
            macro_result0    <= 32'h0;
            macro_result1    <= 32'h0;
            macro_irq_en     <= 32'h0;
            macro_irq_status <= 32'h0;
            for (int i = 0; i < 16; i++) begin
                a_data[i] <= 32'h0;
                b_data[i] <= 32'h0;
                c_data[i] <= 32'h0;
            end
        end else begin
            if (soft_reset) begin
                // Soft reset clears most regs
                macro_ctrl       <= 32'h0;
                macro_config0    <= 32'h0;
                macro_config1    <= 32'h0;
                macro_irq_en     <= 32'h0;
                macro_irq_status <= 32'h0;
                // Results preserved for readout
            end else if (reg_write) begin
                if (reg_addr inside {[12'h100:12'h13F]}) begin
                    // A_DATA: firmware-writable operand block
                    a_data[word_idx] <= reg_wdata;
                end else if (reg_addr inside {[12'h300:12'h33F]}) begin
                    // B_DATA: firmware-writable operand block
                    b_data[word_idx] <= reg_wdata;
                end else if (reg_addr inside {[12'h500:12'h53F]}) begin
                    // C_DATA: read-only, populated from macro_c_in on DONE below.
                    // Bus writes here are ignored (same convention as RESULT0/1).
                end else begin
                    case (reg_addr)
                        12'h000: begin
                            // MACRO_CTRL: START self-clears, SOFT_RESET and MODE persist
                            macro_ctrl[0] <= 1'b0;           // START auto-clear
                            macro_ctrl[1] <= reg_wdata[1];   // SOFT_RESET
                            macro_ctrl[3:2] <= reg_wdata[3:2]; // MODE
                        end
                        12'h004: begin
                            // MACRO_STATUS: Read-only, ignore writes
                        end
                        12'h008: begin
                            macro_config0 <= reg_wdata;
                        end
                        12'h00C: begin
                            macro_config1 <= reg_wdata;
                        end
                        12'h010: begin
                            // MACRO_RESULT0: Read-only for now
                        end
                        12'h014: begin
                            // MACRO_RESULT1: Read-only for now
                        end
                        12'h018: begin
                            macro_irq_en <= reg_wdata;
                        end
                        12'h01C: begin
                            // MACRO_IRQ_STATUS: Write-1-to-clear
                            macro_irq_status <= macro_irq_status & ~reg_wdata;
                        end
                        default: begin
                            // Unmapped address, do nothing
                        end
                    endcase
                end
            end

            // Auto-update results (fake macro computation, legacy placeholder)
            // In real design, these come from analog macroRESULT0
            if (state == DONE) begin
                macro_result0 <= macro_config0 + 32'h1000;  // Dummy: config0 + offset
                macro_result1 <= macro_config1 + 32'h2000;  // Dummy: config1 + offset
            end

            // Latch real macro result into C_DATA the cycle completion is seen.
            // Uses state==BUSY && macro_done (not state==DONE) so the value is
            // captured on the same edge the macro asserts it, one cycle before
            // the FSM itself reaches DONE.
            if (state == BUSY && macro_done) begin
                for (int i = 0; i < 16; i++) begin
                    c_data[i] <= macro_c_in[i];
                end
            end
        end
    end

    // ===== Combinational logic: Register reads =====
    always_comb begin
        if (reg_addr inside {[12'h100:12'h13F]}) begin
            reg_rdata = a_data[word_idx];
        end else if (reg_addr inside {[12'h300:12'h33F]}) begin
            reg_rdata = b_data[word_idx];
        end else if (reg_addr inside {[12'h500:12'h53F]}) begin
            reg_rdata = c_data[word_idx];
        end else begin
            case (reg_addr)
                12'h000: reg_rdata = macro_ctrl;
                12'h004: reg_rdata = macro_status;
                12'h008: reg_rdata = macro_config0;
                12'h00C: reg_rdata = macro_config1;
                12'h010: reg_rdata = macro_result0;
                12'h014: reg_rdata = macro_result1;
                12'h018: reg_rdata = macro_irq_en;
                12'h01C: reg_rdata = macro_irq_status;
                default: reg_rdata = 32'h0;
            endcase
        end
    end

endmodule
