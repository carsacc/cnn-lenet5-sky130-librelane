// tb_spi_interface.sv — SPI slave testbench for spi_interface
// Mirrors tb_host_interface.sv: write/readback all memory targets + CSR tests
//
// Compile:
//   iverilog -g2012 -o tb_spi_interface.out \
//     rtl/modules/tb_spi_interface.sv rtl/modules/spi_interface.v \
//     rtl/modules/param_memory.v rtl/modules/activation_buffer.v \
//     rtl/macros/sky130_sram_1rw1r_32x2048_8/sky130_sram_1rw1r_32x2048_8.v \
//     rtl/macros/sky130_sram_1rw1r_32x1024_8/sky130_sram_1rw1r_32x1024_8.v
//   vvp tb_spi_interface.out
`timescale 1ns/1ps

module tb_spi_interface;

    // ================================================================
    // SPI timing parameters  (1 MHz SPI, 15 MHz core)
    // ================================================================
    parameter SPI_HALF = 500;     // ns  → 1 MHz SPI clock
    parameter CS_GAP   = 2000;    // ns  inter-transaction gap (> mem latency)

    // ================================================================
    // Signals
    // ================================================================
    reg         clk, reset;
    reg         spi_sclk, spi_cs_n, spi_mosi;
    wire        spi_miso;

    wire [10:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    wire        mem_we;
    wire        mem_request;
    wire [1:0]  mem_target;

    reg  [31:0] mem_rdata;
    reg         mem_valid;

    wire        accel_start;
    reg         accel_done;
    reg  [3:0]  accel_pred_class;
    reg         accel_classification_valid;

    // ================================================================
    // DUT
    // ================================================================
    spi_interface dut (
        .clk(clk), .reset(reset),
        .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_request(mem_request), .mem_target(mem_target),
        .mem_rdata(mem_rdata), .mem_valid(mem_valid),
        .accel_start(accel_start),
        .accel_done(accel_done),
        .accel_pred_class(accel_pred_class),
        .accel_classification_valid(accel_classification_valid)
    );

    // ================================================================
    // Memory instances  (same as tb_host_interface)
    // ================================================================
    wire [31:0] pm_dout;  wire pm_valid;
    param_memory u_param (
        .clk(clk), .reset(reset),
        .addr(mem_addr), .din(mem_wdata),
        .read_writeb(~mem_we),
        .request(mem_request && mem_target == 2'd0),
        .dout(pm_dout), .valid(pm_valid)
    );

    wire [31:0] ba_dout;  wire ba_valid;
    activation_buffer u_buf_a (
        .clk(clk), .reset(reset),
        .addr(mem_addr), .din(mem_wdata), .wmask(mem_wmask),
        .read_writeb(~mem_we),
        .request(mem_request && mem_target == 2'd1),
        .dout(ba_dout), .valid(ba_valid)
    );

    wire [31:0] bb_dout;  wire bb_valid;
    activation_buffer u_buf_b (
        .clk(clk), .reset(reset),
        .addr(mem_addr), .din(mem_wdata), .wmask(mem_wmask),
        .read_writeb(~mem_we),
        .request(mem_request && mem_target == 2'd2),
        .dout(bb_dout), .valid(bb_valid)
    );

    // Suppress SRAM traces
    defparam u_param.sram.VERBOSE = 0;
    defparam u_buf_a.sram.VERBOSE = 0;
    defparam u_buf_b.sram.VERBOSE = 0;

    // Memory read mux
    always @(*) begin
        case (mem_target)
            2'd0: begin mem_rdata = pm_dout; mem_valid = pm_valid; end
            2'd1: begin mem_rdata = ba_dout; mem_valid = ba_valid; end
            2'd2: begin mem_rdata = bb_dout; mem_valid = bb_valid; end
            default: begin mem_rdata = 32'd0; mem_valid = 1'b0; end
        endcase
    end

    // ================================================================
    // Clock: 15 MHz  (66.67 ns period)
    // ================================================================
    initial clk = 0;
    always #33.33 clk = ~clk;

    // ================================================================
    // Counters
    // ================================================================
    integer pass_count = 0;
    integer fail_count = 0;

    task check32(input string label, input [31:0] got, input [31:0] exp);
        if (got === exp) begin
            pass_count++;
        end else begin
            $display("FAIL %s: got 0x%08h, exp 0x%08h @ %0t", label, got, exp, $time);
            fail_count++;
        end
    endtask

    // ================================================================
    // SPI master helper tasks
    // ================================================================

    // Low-level: clock one full SPI transaction (56 SCLK edges).
    // Returns the 32 MISO bits captured during the data phase.
    task automatic spi_transact(input [55:0] frame, output [31:0] miso_data);
        integer i;
        reg [31:0] cap;
        begin
            cap = 32'd0;
            spi_cs_n = 0;
            #(SPI_HALF);                         // CS setup
            for (i = 55; i >= 0; i = i - 1) begin
                spi_mosi = frame[i];             // drive MOSI while SCLK low
                #(SPI_HALF);
                spi_sclk = 1;                    // rising edge — slave samples MOSI
                #1;
                if (i < 32)
                    cap[i] = spi_miso;            // master samples MISO (data phase)
                #(SPI_HALF - 1);
                spi_sclk = 0;                    // falling edge — slave drives MISO
            end
            #(SPI_HALF);
            spi_cs_n = 1;                        // CS de-assert
            #(CS_GAP);                           // inter-transaction gap
            miso_data = cap;
        end
    endtask

    // Write a 32-bit word at byte address (16 bits).
    task automatic spi_write(input [15:0] addr, input [31:0] data);
        reg [55:0] frame;
        reg [31:0] dummy;
        begin
            frame = {8'h80, addr, data};         // CMD bit7=1 (write)
            spi_transact(frame, dummy);
        end
    endtask

    // Raw SPI read — sends one read transaction. MISO returns the
    // PREVIOUS read's data (pipeline). Returns captured MISO bits.
    task automatic spi_read_raw(input [15:0] addr, output [31:0] miso_data);
        reg [55:0] frame;
        begin
            frame = {8'h00, addr, 32'd0};        // CMD bit7=0 (read)
            spi_transact(frame, miso_data);
        end
    endtask

    // Pipeline read — two transactions: first triggers fetch, second
    // returns the fetched data.  Uses CSR reserved addr (0x600C, reads 0)
    // as the flush address to avoid side effects.
    task automatic spi_read_data(input [15:0] addr, output [31:0] data);
        reg [31:0] dummy;
        begin
            spi_read_raw(addr,   dummy);         // trigger fetch → returns stale
            spi_read_raw(16'h600C, data);        // flush → returns addr's data
        end
    endtask

    // ================================================================
    // Main test
    // ================================================================
    reg [31:0] rd;
    reg [31:0] rd_stale;

    initial begin
        $dumpfile("rtl/sim/tb_spi_interface.vcd");
        $dumpvars(0, tb_spi_interface);

        // Init SPI
        spi_sclk = 0;
        spi_cs_n = 1;
        spi_mosi = 0;
        accel_done = 0;
        accel_pred_class = 4'd0;
        accel_classification_valid = 0;

        // Reset
        reset = 1;
        repeat (6) @(posedge clk);
        #1; reset = 0;
        repeat (4) @(posedge clk); #1;

        // =============================================
        // Test 1: param_memory write/readback
        // =============================================
        $display("\n--- Test 1: param_memory write/readback ---");
        spi_write(16'h0000, 32'hCAFE_BABE);          // word 0
        spi_write(16'h0804, 32'hDEAD_BEEF);          // word 0x201

        spi_read_data(16'h0000, rd);
        check32("PM rd[0x000]", rd, 32'hCAFE_BABE);

        spi_read_data(16'h0804, rd);
        check32("PM rd[0x804]", rd, 32'hDEAD_BEEF);

        // =============================================
        // Test 2: buf_A write/readback
        // =============================================
        $display("\n--- Test 2: buf_A write/readback ---");
        spi_write(16'h2000, 32'hAABB_CCDD);
        spi_read_data(16'h2000, rd);
        check32("BA rd[0]", rd, 32'hAABB_CCDD);

        // =============================================
        // Test 3: buf_B write/readback
        // =============================================
        $display("\n--- Test 3: buf_B write/readback ---");
        spi_write(16'h4000, 32'h1234_5678);
        spi_write(16'h4004, 32'h9ABC_DEF0);
        spi_read_data(16'h4000, rd);
        check32("BB rd[0]", rd, 32'h1234_5678);
        spi_read_data(16'h4004, rd);
        check32("BB rd[1]", rd, 32'h9ABC_DEF0);

        // =============================================
        // Test 4: CSR CTRL write/read
        // =============================================
        $display("\n--- Test 4: CSR CTRL ---");
        spi_write(16'h6000, 32'h0000_0001);           // start=1
        spi_read_data(16'h6000, rd);
        check32("CTRL=1", rd, 32'h0000_0001);
        check32("accel_start=1", {31'd0, accel_start}, 32'h0000_0001);

        spi_write(16'h6000, 32'h0000_0000);           // start=0
        spi_read_data(16'h6000, rd);
        check32("CTRL=0", rd, 32'h0000_0000);
        check32("accel_start=0", {31'd0, accel_start}, 32'h0000_0000);

        // =============================================
        // Test 5: Memory stall during inference
        // =============================================
        $display("\n--- Test 5: Memory stall ---");
        spi_write(16'h6000, 32'h0000_0001);           // start inference
        // Write to memory — should be silently ignored
        spi_write(16'h0000, 32'hFFFF_FFFF);
        // Read memory — should get DEAD_DEAD (blocked)
        spi_read_data(16'h0000, rd);
        check32("stall rd=DEAD", rd, 32'hDEAD_DEAD);
        // CSR reads still work
        spi_read_data(16'h6000, rd);
        check32("CSR during inf", rd, 32'h0000_0001);
        // Stop inference
        spi_write(16'h6000, 32'h0000_0000);

        // Verify memory NOT corrupted by stalled write
        spi_read_data(16'h0000, rd);
        check32("PM intact", rd, 32'hCAFE_BABE);

        // =============================================
        // Test 6: STATUS / RESULT
        // =============================================
        $display("\n--- Test 6: STATUS/RESULT ---");
        accel_done = 1;
        accel_classification_valid = 1;
        accel_pred_class = 4'd7;
        repeat (4) @(posedge clk); #1;

        spi_read_data(16'h6004, rd);
        check32("STATUS done+cv", rd, 32'h0000_0003);
        spi_read_data(16'h6008, rd);
        check32("RESULT=7", rd, 32'h0000_0007);

        accel_pred_class = 4'd3;
        accel_done = 0;
        accel_classification_valid = 0;
        repeat (4) @(posedge clk); #1;

        spi_read_data(16'h6004, rd);
        check32("STATUS idle", rd, 32'h0000_0000);
        spi_read_data(16'h6008, rd);
        check32("RESULT=3", rd, 32'h0000_0003);

        // =============================================
        // Test 7: Write to RO CSRs (silent ignore)
        // =============================================
        $display("\n--- Test 7: Write to RO CSRs ---");
        spi_write(16'h6004, 32'hFFFF_FFFF);
        spi_write(16'h6008, 32'hFFFF_FFFF);
        spi_read_data(16'h6004, rd);
        check32("STATUS unchanged", rd, 32'h0000_0000);
        spi_read_data(16'h6008, rd);
        check32("RESULT unchanged", rd, 32'h0000_0003);

        // =============================================
        // Test 8: Pipeline read verification
        // =============================================
        $display("\n--- Test 8: Pipeline read demo ---");
        spi_write(16'h2004, 32'h1111_1111);
        spi_write(16'h2008, 32'h2222_2222);
        // First raw read → returns stale (0 or previous read_data)
        spi_read_raw(16'h2004, rd_stale);
        // Second raw read → returns 0x1111_1111 (addr 0x2004)
        spi_read_raw(16'h2008, rd);
        check32("pipe rd[2004]", rd, 32'h1111_1111);
        // Third raw read → returns 0x2222_2222 (addr 0x2008)
        spi_read_raw(16'h600C, rd);
        check32("pipe rd[2008]", rd, 32'h2222_2222);

        // =============================================
        // Test 9: Back-to-back writes
        // =============================================
        $display("\n--- Test 9: Back-to-back writes ---");
        spi_write(16'h200C, 32'hAAAA_AAAA);
        spi_write(16'h2010, 32'hBBBB_BBBB);
        spi_write(16'h2014, 32'hCCCC_CCCC);
        spi_read_data(16'h200C, rd);
        check32("B2B rd[3]", rd, 32'hAAAA_AAAA);
        spi_read_data(16'h2010, rd);
        check32("B2B rd[4]", rd, 32'hBBBB_BBBB);
        spi_read_data(16'h2014, rd);
        check32("B2B rd[5]", rd, 32'hCCCC_CCCC);

        // =============================================
        // Test 10: Reserved CSR reads 0
        // =============================================
        $display("\n--- Test 10: Reserved CSR ---");
        spi_read_data(16'h600C, rd);
        check32("Reserved CSR", rd, 32'h0000_0000);

        // =============================================
        // Summary
        // =============================================
        $display("\n========================================");
        $display("  PASS: %0d / %0d", pass_count, pass_count + fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  FAILURES: %0d", fail_count);
        $display("========================================\n");
        $finish;
    end

    // Timeout
    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
