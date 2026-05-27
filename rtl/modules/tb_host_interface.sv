// tb_host_interface.sv — OBI slave testbench for host_interface
`timescale 1ns/1ps

module tb_host_interface;

    reg         clk, reset;
    reg         obi_req;
    wire        obi_gnt;
    reg  [31:0] obi_addr;
    reg         obi_we;
    reg  [3:0]  obi_be;
    reg  [31:0] obi_wdata;
    wire        obi_rvalid;
    wire [31:0] obi_rdata;

    wire [10:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    wire        mem_we;
    wire        mem_request;
    wire [1:0]  mem_target;

    // Muxed memory signals
    reg  [31:0] mem_rdata;
    reg         mem_valid;

    wire        accel_start;
    reg         accel_done;
    reg  [3:0]  accel_pred_class;
    reg         accel_classification_valid;

    // --- DUT ---
    host_interface dut (
        .clk(clk), .reset(reset),
        .obi_req(obi_req), .obi_gnt(obi_gnt),
        .obi_addr(obi_addr), .obi_we(obi_we),
        .obi_be(obi_be), .obi_wdata(obi_wdata),
        .obi_rvalid(obi_rvalid), .obi_rdata(obi_rdata),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask), .mem_we(mem_we),
        .mem_request(mem_request), .mem_target(mem_target),
        .mem_rdata(mem_rdata), .mem_valid(mem_valid),
        .accel_start(accel_start),
        .accel_done(accel_done),
        .accel_pred_class(accel_pred_class),
        .accel_classification_valid(accel_classification_valid)
    );

    // --- Three memory instances ---
    // param_memory
    wire [31:0] pm_dout;
    wire        pm_valid;
    param_memory u_param (
        .clk(clk), .reset(reset),
        .addr(mem_addr),
        .din(mem_wdata),
        .read_writeb(~mem_we),
        .request(mem_request && mem_target == 2'd0),
        .dout(pm_dout),
        .valid(pm_valid)
    );

    // buf_A (activation_buffer)
    wire [31:0] ba_dout;
    wire        ba_valid;
    activation_buffer u_buf_a (
        .clk(clk), .reset(reset),
        .addr(mem_addr),
        .din(mem_wdata),
        .wmask(mem_wmask),
        .read_writeb(~mem_we),
        .request(mem_request && mem_target == 2'd1),
        .dout(ba_dout),
        .valid(ba_valid)
    );

    // buf_B (activation_buffer)
    wire [31:0] bb_dout;
    wire        bb_valid;
    activation_buffer u_buf_b (
        .clk(clk), .reset(reset),
        .addr(mem_addr),
        .din(mem_wdata),
        .wmask(mem_wmask),
        .read_writeb(~mem_we),
        .request(mem_request && mem_target == 2'd2),
        .dout(bb_dout),
        .valid(bb_valid)
    );

    // Suppress SRAM verbose output
    defparam u_param.sram_0.VERBOSE = 0;
    defparam u_param.sram_1.VERBOSE = 0;
    defparam u_param.sram_2.VERBOSE = 0;
    defparam u_param.sram_3.VERBOSE = 0;
    defparam u_buf_a.sram_0.VERBOSE = 0;
    defparam u_buf_a.sram_1.VERBOSE = 0;
    defparam u_buf_a.sram_2.VERBOSE = 0;
    defparam u_buf_a.sram_3.VERBOSE = 0;
    defparam u_buf_b.sram_0.VERBOSE = 0;
    defparam u_buf_b.sram_1.VERBOSE = 0;
    defparam u_buf_b.sram_2.VERBOSE = 0;
    defparam u_buf_b.sram_3.VERBOSE = 0;

    // Memory read mux — select based on mem_target latched in DUT
    always @(*) begin
        case (mem_target)
            2'd0: begin mem_rdata = pm_dout; mem_valid = pm_valid; end
            2'd1: begin mem_rdata = ba_dout; mem_valid = ba_valid; end
            2'd2: begin mem_rdata = bb_dout; mem_valid = bb_valid; end
            default: begin mem_rdata = 32'd0; mem_valid = 1'b0; end
        endcase
    end

    // --- Clock ---
    initial clk = 0;
    always #5 clk = ~clk;

    // --- Counters ---
    integer pass_count = 0;
    integer fail_count = 0;

    // --- Helper: check ---
    task check32(input string label, input [31:0] got, input [31:0] exp);
        if (got === exp) begin
            pass_count++;
        end else begin
            $display("FAIL %s: got 0x%08h, exp 0x%08h @ %0t", label, got, exp, $time);
            fail_count++;
        end
    endtask

    // --- OBI Write task ---
    task obi_write(input [31:0] addr, input [31:0] data, input [3:0] be);
        begin
            @(posedge clk); #1;
            obi_addr  = addr;
            obi_wdata = data;
            obi_we    = 1;
            obi_be    = be;
            obi_req   = 1;
            // Wait for grant
            while (!obi_gnt) begin
                @(posedge clk); #1;
            end
            // Grant received at this posedge — address phase done
            @(posedge clk); #1;
            obi_req = 0;
            // Wait for rvalid
            while (!obi_rvalid) begin
                @(posedge clk); #1;
            end
            @(posedge clk); #1;
        end
    endtask

    // --- OBI Read task ---
    task obi_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(posedge clk); #1;
            obi_addr = addr;
            obi_we   = 0;
            obi_be   = 4'b1111;
            obi_req  = 1;
            // Wait for grant
            while (!obi_gnt) begin
                @(posedge clk); #1;
            end
            @(posedge clk); #1;
            obi_req = 0;
            // Wait for rvalid
            while (!obi_rvalid) begin
                @(posedge clk); #1;
            end
            rdata = obi_rdata;
            @(posedge clk); #1;
        end
    endtask

    // --- Main test ---
    reg [31:0] rd;
    initial begin
        $dumpfile("rtl/sim/tb_host_interface.vcd");
        $dumpvars(0, tb_host_interface);

        // Init
        obi_req   = 0;
        obi_addr  = 0;
        obi_we    = 0;
        obi_be    = 4'b1111;
        obi_wdata = 0;
        accel_done = 0;
        accel_pred_class = 4'd0;
        accel_classification_valid = 0;

        // Reset
        reset = 1;
        repeat (4) @(posedge clk);
        #1; reset = 0;
        repeat (2) @(posedge clk); #1;

        // =============================================
        // Test 1: param_memory write/readback
        // =============================================
        $display("\n--- Test 1: param_memory write/readback ---");
        // Write word at addr 0x0000 (word 0, bank 0)
        obi_write(32'h0000_0000, 32'hCAFE_BABE, 4'b1111);
        // Write word at addr 0x0804 (word 0x201 = bank 1, word 1)
        obi_write(32'h0000_0804, 32'hDEAD_BEEF, 4'b1111);
        // Read back
        obi_read(32'h0000_0000, rd);
        check32("PM rd[0x000]", rd, 32'hCAFE_BABE);
        obi_read(32'h0000_0804, rd);
        check32("PM rd[0x804]", rd, 32'hDEAD_BEEF);

        // =============================================
        // Test 2: buf_A write/readback with byte masking
        // =============================================
        $display("\n--- Test 2: buf_A byte masking ---");
        // Write full word
        obi_write(32'h0000_2000, 32'hAABB_CCDD, 4'b1111);
        // Overwrite only byte 1 (bits [15:8])
        obi_write(32'h0000_2000, 32'h0000_FF00, 4'b0010);
        // Read back — expect byte 1 replaced
        obi_read(32'h0000_2000, rd);
        check32("BA byte mask", rd, 32'hAABB_FFDD);

        // =============================================
        // Test 3: buf_B write/readback
        // =============================================
        $display("\n--- Test 3: buf_B write/readback ---");
        obi_write(32'h0000_4000, 32'h1234_5678, 4'b1111);
        obi_write(32'h0000_4004, 32'h9ABC_DEF0, 4'b1111);
        obi_read(32'h0000_4000, rd);
        check32("BB rd[0]", rd, 32'h1234_5678);
        obi_read(32'h0000_4004, rd);
        check32("BB rd[1]", rd, 32'h9ABC_DEF0);

        // =============================================
        // Test 4: CSR CTRL write/read
        // =============================================
        $display("\n--- Test 4: CSR CTRL ---");
        // Write start=1
        obi_write(32'h0000_6000, 32'h0000_0001, 4'b1111);
        // Read CTRL back
        obi_read(32'h0000_6000, rd);
        check32("CTRL=1", rd, 32'h0000_0001);
        // Check accel_start output
        check32("accel_start=1", {31'd0, accel_start}, 32'h0000_0001);
        // Write start=0
        obi_write(32'h0000_6000, 32'h0000_0000, 4'b1111);
        obi_read(32'h0000_6000, rd);
        check32("CTRL=0", rd, 32'h0000_0000);
        check32("accel_start=0", {31'd0, accel_start}, 32'h0000_0000);

        // =============================================
        // Test 5: Memory stall during inference
        // =============================================
        $display("\n--- Test 5: Memory stall during inference ---");
        // Start inference
        obi_write(32'h0000_6000, 32'h0000_0001, 4'b1111);
        // Try memory access — should NOT get grant
        @(posedge clk); #1;
        obi_addr  = 32'h0000_0000; // param memory
        obi_we    = 0;
        obi_be    = 4'b1111;
        obi_req   = 1;
        @(posedge clk); #1;
        check32("stall gnt=0", {31'd0, obi_gnt}, 32'd0);
        obi_req = 0;
        @(posedge clk); #1;
        // CSR read should still work
        obi_read(32'h0000_6000, rd);
        check32("CSR during inf", rd, 32'h0000_0001);
        // Stop inference for remaining tests
        obi_write(32'h0000_6000, 32'h0000_0000, 4'b1111);

        // =============================================
        // Test 6: STATUS/RESULT with mock accel signals
        // =============================================
        $display("\n--- Test 6: STATUS/RESULT ---");
        accel_done = 1;
        accel_classification_valid = 1;
        accel_pred_class = 4'd7;
        @(posedge clk); #1;
        obi_read(32'h0000_6004, rd);
        check32("STATUS done+cv", rd, 32'h0000_0003);
        obi_read(32'h0000_6008, rd);
        check32("RESULT=7", rd, 32'h0000_0007);
        // Change prediction
        accel_pred_class = 4'd3;
        accel_done = 0;
        accel_classification_valid = 0;
        @(posedge clk); #1;
        obi_read(32'h0000_6004, rd);
        check32("STATUS idle", rd, 32'h0000_0000);
        obi_read(32'h0000_6008, rd);
        check32("RESULT=3", rd, 32'h0000_0003);

        // =============================================
        // Test 7: Write to read-only CSRs (silent ignore)
        // =============================================
        $display("\n--- Test 7: Write to RO CSRs ---");
        obi_write(32'h0000_6004, 32'hFFFF_FFFF, 4'b1111);
        obi_write(32'h0000_6008, 32'hFFFF_FFFF, 4'b1111);
        // STATUS/RESULT should be unchanged (driven by accel signals)
        obi_read(32'h0000_6004, rd);
        check32("STATUS unchanged", rd, 32'h0000_0000);
        obi_read(32'h0000_6008, rd);
        check32("RESULT unchanged", rd, 32'h0000_0003);

        // =============================================
        // Test 8: Back-to-back transactions
        // =============================================
        $display("\n--- Test 8: Back-to-back ---");
        obi_write(32'h0000_2008, 32'h1111_1111, 4'b1111);
        obi_write(32'h0000_200C, 32'h2222_2222, 4'b1111);
        obi_write(32'h0000_2010, 32'h3333_3333, 4'b1111);
        obi_read(32'h0000_2008, rd);
        check32("B2B rd[2]", rd, 32'h1111_1111);
        obi_read(32'h0000_200C, rd);
        check32("B2B rd[3]", rd, 32'h2222_2222);
        obi_read(32'h0000_2010, rd);
        check32("B2B rd[4]", rd, 32'h3333_3333);

        // =============================================
        // Test 9: Reserved CSR reads 0
        // =============================================
        $display("\n--- Test 9: Reserved CSR ---");
        obi_read(32'h0000_600C, rd);
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
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
