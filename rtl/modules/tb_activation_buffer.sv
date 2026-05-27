`timescale 1ns/1ps

module tb_activation_buffer;

    reg         clk, reset;
    reg  [10:0] addr;
    reg  [31:0] din;
    reg  [3:0]  wmask;
    reg         read_writeb;
    reg         request;
    wire [31:0] dout;
    wire        valid;

    activation_buffer dut (
        .clk(clk), .reset(reset),
        .addr(addr), .din(din), .wmask(wmask),
        .read_writeb(read_writeb), .request(request),
        .dout(dout), .valid(valid)
    );

    // Suppress SRAM verbose output
    defparam dut.sram_0.VERBOSE = 0;
    defparam dut.sram_1.VERBOSE = 0;
    defparam dut.sram_2.VERBOSE = 0;
    defparam dut.sram_3.VERBOSE = 0;

    always #5 clk = ~clk;

    integer errors;
    integer tests_passed;
    reg [31:0] read_data;

    // ----------------------------------------------------------------
    //  Helper tasks
    // ----------------------------------------------------------------
    task do_reset;
        reset = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        reset = 0;
        @(posedge clk); #1;
    endtask

    // Write one word (waits for valid ack, then deasserts request)
    task write_mem(input [10:0] address, input [31:0] data, input [3:0] mask);
        @(negedge clk);
        addr        = address;
        din         = data;
        wmask       = mask;
        read_writeb = 0;
        request     = 1;
        @(posedge clk); #1;          // delay 0→1
        @(posedge clk); #1;          // delay==1 → valid=1
        if (!valid) begin
            $display("  ERROR: write valid not asserted for addr=0x%0h", address);
            errors = errors + 1;
        end
        request = 0;
        @(posedge clk); #1;          // valid deasserts
    endtask

    // Read one word (waits for valid, stores result in read_data)
    task read_mem(input [10:0] address);
        @(negedge clk);
        addr        = address;
        read_writeb = 1;
        request     = 1;
        @(posedge clk); #1;          // delay 0→1
        @(posedge clk); #1;          // delay 1→2
        @(posedge clk); #1;          // delay==2 → valid=1
        if (!valid) begin
            $display("  ERROR: read valid not asserted for addr=0x%0h", address);
            errors = errors + 1;
        end
        read_data = dout;
        request = 0;
        @(posedge clk); #1;
    endtask

    // Check helper
    task check(input [31:0] got, input [31:0] expected, input [159:0] label);
        if (got === expected) begin
            tests_passed = tests_passed + 1;
        end else begin
            $display("  FAIL [%0s]: got=0x%08h expected=0x%08h", label, got, expected);
            errors = errors + 1;
        end
    endtask

    // ================================================================
    //  Main test sequence
    // ================================================================
    initial begin
        $dumpfile("rtl/sim/tb_activation_buffer.vcd");
        $dumpvars(0, tb_activation_buffer);

        clk = 0; reset = 0;
        addr = 0; din = 0; wmask = 4'b1111;
        read_writeb = 1; request = 0;
        errors = 0; tests_passed = 0;

        do_reset;

        // ============================================================
        //  Test 1: Byte-level writes
        // ============================================================
        $display("\n=== Test 1: Byte-level writes ===");
        // First write a known full word so no X bytes remain
        write_mem(11'd0, 32'h12345678, 4'b1111);

        // Overwrite individual bytes
        write_mem(11'd0, 32'h000000AA, 4'b0001);   // byte 0 → AA
        write_mem(11'd0, 32'h0000BB00, 4'b0010);   // byte 1 → BB
        write_mem(11'd0, 32'h00CC0000, 4'b0100);   // byte 2 → CC
        write_mem(11'd0, 32'hDD000000, 4'b1000);   // byte 3 → DD

        read_mem(11'd0);
        check(read_data, 32'hDDCCBBAA, "byte_all");

        // Partial byte overwrite: change only bytes 0 and 2
        write_mem(11'd0, 32'h00EE00FF, 4'b0101);
        read_mem(11'd0);
        check(read_data, 32'hDDEEBBFF, "byte_partial");

        // ============================================================
        //  Test 2: Full word writes
        // ============================================================
        $display("\n=== Test 2: Full word writes ===");
        begin : blk_t2
            integer i;
            integer exp;
            for (i = 0; i < 8; i = i + 1) begin
                exp = 32'hCAFE0000 + i;
                write_mem(i[10:0], exp[31:0], 4'b1111);
            end
            for (i = 0; i < 8; i = i + 1) begin
                exp = 32'hCAFE0000 + i;
                read_mem(i[10:0]);
                check(read_data, exp[31:0], "word_rw");
            end
        end

        // ============================================================
        //  Test 3: Cross-bank isolation
        // ============================================================
        $display("\n=== Test 3: Cross-bank access ===");
        // bank 0: addr 0, bank 1: addr 512, bank 2: addr 1024, bank 3: addr 1536
        write_mem(11'd0,    32'hAAAA_0000, 4'b1111);
        write_mem(11'd512,  32'hBBBB_1111, 4'b1111);
        write_mem(11'd1024, 32'hCCCC_2222, 4'b1111);
        write_mem(11'd1536, 32'hDDDD_3333, 4'b1111);

        read_mem(11'd0);
        check(read_data, 32'hAAAA_0000, "bank0");
        read_mem(11'd512);
        check(read_data, 32'hBBBB_1111, "bank1");
        read_mem(11'd1024);
        check(read_data, 32'hCCCC_2222, "bank2");
        read_mem(11'd1536);
        check(read_data, 32'hDDDD_3333, "bank3");

        // Verify bank 0 addr 0 not corrupted by other bank writes
        read_mem(11'd0);
        check(read_data, 32'hAAAA_0000, "bank0_iso");

        // ============================================================
        //  Test 4: Read latency — exactly 2 cycle warmup
        // ============================================================
        $display("\n=== Test 4: Read latency ===");
        write_mem(11'd5, 32'hDEAD_CAFE, 4'b1111);

        // Deassert everything, wait for idle
        request = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;

        begin : blk_t4
            integer cycle_count;
            // Start read
            @(negedge clk);
            addr = 11'd5;
            read_writeb = 1;
            request = 1;
            cycle_count = 0;

            // Count posedges until valid
            while (!valid) begin
                @(posedge clk); #1;
                cycle_count = cycle_count + 1;
                if (cycle_count > 10) begin
                    $display("  FAIL: valid never asserted (timeout)");
                    errors = errors + 1;
                    disable blk_t4;
                end
            end

            if (cycle_count == 3) begin
                tests_passed = tests_passed + 1;
            end else begin
                $display("  FAIL [latency]: expected 3 cycles, got %0d", cycle_count);
                errors = errors + 1;
            end
            check(dout, 32'hDEAD_CAFE, "lat_data");

            request = 0;
            @(posedge clk); #1;
        end

        // ============================================================
        //  Test 5: Streaming reads (pipeline throughput)
        // ============================================================
        $display("\n=== Test 5: Streaming reads ===");
        // Write 8 words to bank 0 addresses 10..17
        begin : blk_t5
            integer i, exp;
            integer stream_ok;
            for (i = 0; i < 8; i = i + 1) begin
                exp = 32'hF000_0000 + (i * 16'h0111);
                write_mem(11'd10 + i[10:0], exp[31:0], 4'b1111);
            end

            // Start streaming: hold request high, present addr=10 for
            // 2 warmup cycles, then increment each cycle.
            @(negedge clk);
            addr = 11'd10;
            read_writeb = 1;
            request = 1;

            // Warmup cycle 0 (delay 0→1)
            @(posedge clk); #1;
            // Warmup cycle 1 — keep addr=10 (delay 1→2)
            @(posedge clk); #1;

            // Cycle 2: delay==2, valid=1, dout should be mem[10]
            @(posedge clk); #1;
            exp = 32'hF000_0000;
            check(dout, exp[31:0], "stream_0");
            if (!valid) begin
                $display("  FAIL: stream valid not asserted at start");
                errors = errors + 1;
            end

            // In steady state (delay==2), output lags address change
            // by 1 cycle (SRAM pipeline). When we set addr=10+i, the
            // posedge that follows produces mem[10+i-1].
            // Loop i=1..8: expect mem[10+(i-1)].
            // i=8 uses addr held at 17 to flush the last value.
            stream_ok = 1;
            for (i = 1; i <= 8; i = i + 1) begin
                if (i < 8)
                    addr = 11'd10 + i[10:0];
                // else keep addr=17 to flush last pipeline stage
                @(posedge clk); #1;
                exp = 32'hF000_0000 + ((i - 1) * 16'h0111);
                if (!valid) begin
                    $display("  FAIL: stream valid gap at i=%0d", i);
                    errors = errors + 1;
                    stream_ok = 0;
                end
                if (dout !== exp[31:0]) begin
                    $display("  FAIL [stream_%0d]: got=0x%08h expected=0x%08h", i, dout, exp[31:0]);
                    errors = errors + 1;
                    stream_ok = 0;
                end
            end
            if (stream_ok) begin
                tests_passed = tests_passed + 8; // 8 streaming checks
            end

            request = 0;
            @(posedge clk); #1;
        end

        // ============================================================
        //  Summary
        // ============================================================
        $display("\n========================================");
        if (errors == 0)
            $display("ALL TESTS PASSED (%0d checks)", tests_passed);
        else
            $display("FAILED: %0d errors, %0d passed", errors, tests_passed);
        $display("========================================\n");
        $finish;
    end

endmodule
