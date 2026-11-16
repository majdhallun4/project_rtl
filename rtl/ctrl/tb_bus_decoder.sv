`timescale 1ns/1ps

module tb_bus_decoder;
    logic        clk;
    logic        rst_n;
    logic [31:0] addr_i;
    logic [31:0] wdata_i;
    logic        write_i;
    logic        read_i;
    logic [31:0] rdata_o;
    logic        valid_o;

    logic [7:0]  macro_addr_o;
    logic [31:0] macro_wdata_o;
    logic        macro_write_o;
    logic        macro_read_o;
    logic [31:0] macro_rdata_i;

    bus_decoder dut (
        .clk(clk),
        .rst_n(rst_n),
        .addr_i(addr_i),
        .wdata_i(wdata_i),
        .write_i(write_i),
        .read_i(read_i),
        .rdata_o(rdata_o),
        .valid_o(valid_o),
        .macro_addr_o(macro_addr_o),
        .macro_wdata_o(macro_wdata_o),
        .macro_write_o(macro_write_o),
        .macro_read_o(macro_read_o),
        .macro_rdata_i(macro_rdata_i)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 0;
        addr_i = 32'h0;
        wdata_i = 32'h0;
        write_i = 0;
        read_i = 0;
        macro_rdata_i = 32'hCAFEBABE;

        #20 rst_n = 1;

        // Write to macro CSR region
        #10;
        addr_i = 32'h4000_0008;
        wdata_i = 32'hDEAD_BEEF;
        write_i = 1;
        #10;
        write_i = 0;
        $display("[%0t] write_i=%0b macro_sel=1 addr=%h macro_addr=%h macro_wdata=%h", $time, write_i, addr_i, macro_addr_o, macro_wdata_o);

        // Read from macro CSR region
        #10;
        addr_i = 32'h4000_0010;
        read_i = 1;
        #10;
        read_i = 0;
        $display("[%0t] read_i=%0b macro_sel=1 addr=%h macro_addr=%h rdata=%h valid=%0b", $time, read_i, addr_i, macro_addr_o, rdata_o, valid_o);

        // Read outside region
        #10;
        addr_i = 32'h5000_0000;
        read_i  = 1;
        #10;
        read_i  = 0;
        $display("[%0t] read outside region valid=%0b rdata=%h", $time, valid_o, rdata_o);

        #20;
        $display("=== tb_bus_decoder PASS ===");
        $finish;
    end
endmodule
