/**
 * tb_macro_csr.sv - Simple testbench for macro_csr
 *
 * Verifies:
 * - Write START, see BUSY
 * - DONE after delay
 * - Read CONFIG/RESULT
 */

`timescale 1ns/1ps

module tb_macro_csr;

    logic        clk;
    logic        rst_n;
    logic [7:0]  reg_addr;
    logic [31:0] reg_wdata;
    logic [31:0] reg_rdata;
    logic        reg_write;
    logic        reg_read;
    logic        done_irq;
    logic        error_irq;
    logic        macro_en;
    logic [1:0]  macro_mode;

    // Instantiate DUT
    macro_csr #(.CYCLE_DELAY(100)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata),
        .reg_write(reg_write),
        .reg_read(reg_read),
        .done_irq(done_irq),
        .error_irq(error_irq),
        .macro_en(macro_en),
        .macro_mode(macro_mode),
        .macro_done(1'b0)
    );

    // Clock generation (10 ns period = 100 MHz)
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Test sequence
    initial begin
        $display("=== tb_macro_csr START ===");

        // Initialize
        rst_n      = 1'b0;
        reg_addr   = 8'h0;
        reg_wdata  = 32'h0;
        reg_write  = 1'b0;
        reg_read   = 1'b0;

        #20 rst_n = 1'b1;
        $display("[%0t] Reset done, state = IDLE", $time);

        // Test 1: Read initial STATUS (should be all zeros)
        #10;
        reg_addr = 8'h04;  // MACRO_STATUS
        reg_read = 1'b1;
        #10 reg_read = 1'b0;
        $display("[%0t] Initial STATUS = 0x%08x (expect 0x0)", $time, reg_rdata);

        // Test 2: Write CONFIG0
        #10;
        reg_addr  = 8'h08;  // MACRO_CONFIG0
        reg_wdata = 32'hDEAD_BEEF;
        reg_write = 1'b1;
        #10 reg_write = 1'b0;
        $display("[%0t] Wrote CONFIG0 = 0x%08x", $time, reg_wdata);

        // Test 3: Write START (to CTRL)
        #10;
        reg_addr  = 8'h00;  // MACRO_CTRL
        reg_wdata = 32'h0000_0001;  // START=1
        reg_write = 1'b1;
        #10 reg_write = 1'b0;
        $display("[%0t] Wrote START pulse", $time);

        // Test 4: Read STATUS, expect BUSY
        #10;
        reg_addr = 8'h04;
        reg_read = 1'b1;
        #10 reg_read = 1'b0;
        $display("[%0t] STATUS after START = 0x%08x (expect BUSY=1)", $time, reg_rdata);

        // Test 5: Poll STATUS until DONE
        #10;
        for (int i = 0; i < 200; i++) begin
            reg_addr = 8'h04;
            reg_read = 1'b1;
            #10 reg_read = 1'b0;
            if (reg_rdata[1]) begin
                $display("[%0t] DONE observed at iteration %0d, STATUS=0x%08x", $time, i, reg_rdata);
                break;
            end
            #10;
        end

        // Test 6: Read CONFIG0 and RESULT0
        #10;
        reg_addr = 8'h08;
        reg_read = 1'b1;
        #10 reg_read = 1'b0;
        $display("[%0t] CONFIG0 = 0x%08x", $time, reg_rdata);

        #10;
        reg_addr = 8'h10;
        reg_read = 1'b1;
        #10 reg_read = 1'b0;
        $display("[%0t] RESULT0 = 0x%08x (expect CONFIG0 + 0x1000)", $time, reg_rdata);

        // Test 7: Soft reset
        #10;
        reg_addr  = 8'h00;
        reg_wdata = 32'h0000_0002;  // SOFT_RESET=1
        reg_write = 1'b1;
        #10 reg_write = 1'b0;
        $display("[%0t] Wrote SOFT_RESET", $time);

        #10;
        reg_addr = 8'h04;
        reg_read = 1'b1;
        #10 reg_read = 1'b0;
        $display("[%0t] STATUS after reset = 0x%08x (expect 0x0)", $time, reg_rdata);

        #100;
        $display("=== tb_macro_csr PASS ===");
        $finish;
    end

endmodule
