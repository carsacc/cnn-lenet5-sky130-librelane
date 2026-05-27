// tb_layer_sequencer.sv — Integration testbench for layer_sequencer
// Test 1: Smoke test (all-zero weights) → done asserts, pred_class=0
// Test 2: Full MNIST inference with real trained weights
`timescale 1ns/1ps

module tb_layer_sequencer;

    // ================================================================
    // Clock / Reset
    // ================================================================
    reg clk, reset;
    initial clk = 0;
    always #5 clk = ~clk; // 100 MHz

    // ================================================================
    // DUT signals
    // ================================================================
    reg         start;
    wire        done_w;

    // Unified activation buffer (1024 words: A-region 0-511, B-region 512-1023)
    wire [10:0] buf_addr;
    wire [31:0] buf_din;
    wire [3:0]  buf_wmask;
    wire        buf_request;
    wire        buf_read_writeb;
    wire [31:0] buf_dout;
    wire        buf_valid;

    wire [10:0] param_addr;
    wire        param_request;
    wire        param_read_writeb;
    wire [31:0] param_dout;
    wire        param_valid;

    wire [3:0]  pred_class_out;
    wire        classification_valid;

    // ================================================================
    // DUT
    // ================================================================
    layer_sequencer u_dut (
        .clk                (clk),
        .reset              (reset),
        .start              (start),
        .done               (done_w),
        // Unified buffer
        .buf_addr           (buf_addr),
        .buf_din            (buf_din),
        .buf_wmask          (buf_wmask),
        .buf_request        (buf_request),
        .buf_read_writeb    (buf_read_writeb),
        .buf_dout           (buf_dout),
        .buf_valid          (buf_valid),
        // Param
        .param_addr         (param_addr),
        .param_request      (param_request),
        .param_read_writeb  (param_read_writeb),
        .param_dout         (param_dout),
        .param_valid        (param_valid),
        // Classification
        .pred_class_out     (pred_class_out),
        .classification_valid(classification_valid)
    );

    // ================================================================
    // External memories
    // ================================================================
    // Unified 1024-word buffer: words 0-511 = A-region, 512-1023 = B-region
    activation_buffer #(.SRAM_ADDR_WIDTH(10)) u_buf (
        .clk        (clk),
        .reset      (reset),
        .addr       (buf_addr),
        .din        (buf_din),
        .wmask      (buf_wmask),
        .read_writeb(buf_read_writeb),
        .request    (buf_request),
        .dout       (buf_dout),
        .valid      (buf_valid)
    );

    param_memory u_param (
        .clk        (clk),
        .reset      (reset),
        .addr       (param_addr),
        .din        (32'd0),
        .read_writeb(param_read_writeb),
        .request    (param_request),
        .dout       (param_dout),
        .valid      (param_valid)
    );

    // ================================================================
    // Backdoor memory access tasks
    // ================================================================
    // Unified 1024-word buf: A-region offset=0, B-region offset=512
    task automatic preload_buf(input [10:0] addr, input [31:0] data);
        u_buf.sram.mem[addr[9:0]] = data;
    endtask

    // Convenience wrappers matching old naming (offset applied for B-region)
    task automatic preload_buf_a(input [10:0] addr, input [31:0] data);
        u_buf.sram.mem[addr[9:0]] = data;
    endtask

    task automatic preload_buf_b(input [10:0] addr, input [31:0] data);
        u_buf.sram.mem[11'd512 + addr[9:0]] = data;
    endtask

    function automatic [31:0] read_buf(input [10:0] addr);
        read_buf = u_buf.sram.mem[addr[9:0]];
    endfunction

    function automatic [31:0] read_buf_b(input [10:0] addr);
        read_buf_b = u_buf.sram.mem[11'd512 + addr[9:0]];
    endfunction

    // param_memory: single 2048-word SRAM
    task automatic preload_param(input [10:0] addr, input [31:0] data);
        u_param.sram.mem[addr] = data;
    endtask

    function automatic [31:0] read_param(input [10:0] addr);
        read_param = u_param.sram.mem[addr];
    endfunction

    // Adjust Conv1 biases to absorb model_input_zp.
    // Python does: acc = sum((pixel - input_zp) * weight) + bias
    // Hardware:    acc = sum(pixel * weight) + bias
    // Fix: bias_adj = bias - input_zp * sum(weights_for_channel)
    // Conv1 is OC-parallel: 2 oc_steps × 4 lanes, 9 kernel positions
    // Weights at 0x002..0x00A (oc0-3) and 0x00B..0x013 (oc4-7)
    // Biases at 0x014..0x01B (1 per channel)
    task automatic adjust_conv1_biases;
        integer input_zp;
        integer oc, k;
        integer weight_word;
        integer w_signed;
        integer weight_sum;
        integer bias_val;
        integer bias_adj;
        begin
            // Read input_zp from param word 0x001, byte 0
            input_zp = read_param(11'h001) & 32'hFF;
            $display("  Input ZP = %0d", input_zp);

            for (oc = 0; oc < 8; oc = oc + 1) begin
                weight_sum = 0;
                for (k = 0; k < 9; k = k + 1) begin
                    // oc0-3: addr 0x002+k, oc4-7: addr 0x00B+k
                    if (oc < 4)
                        weight_word = read_param(11'h002 + k[10:0]);
                    else
                        weight_word = read_param(11'h00B + k[10:0]);
                    // Extract byte for this oc within the group of 4
                    // Extract byte and sign-extend manually (Icarus-safe)
                    case (oc % 4)
                        0: w_signed = weight_word[7:0];
                        1: w_signed = (weight_word >> 8) & 32'hFF;
                        2: w_signed = (weight_word >> 16) & 32'hFF;
                        3: w_signed = (weight_word >> 24) & 32'hFF;
                    endcase
                    // Manual sign extension from 8 bits
                    if (w_signed[7]) w_signed = w_signed | 32'hFFFFFF00;
                    weight_sum = weight_sum + w_signed;
                end
                // Read original bias (32-bit signed)
                bias_val = read_param(11'h014 + oc[10:0]);
                bias_adj = bias_val - input_zp * weight_sum;
                // Debug: uncomment to see per-channel bias adjustment
                // $display("    oc%0d: sum_w=%0d bias=%0d bias_adj=%0d",
                //          oc, weight_sum, bias_val, bias_adj);
                preload_param(11'h014 + oc[10:0], bias_adj[31:0]);
            end
            $display("  Conv1 biases adjusted for input_zp=%0d", input_zp);
        end
    endtask

    // ================================================================
    // Test helpers
    // ================================================================
    integer pass_count, fail_count;
    integer total_pass, total_fail;

    task automatic clear_all_memories;
        integer i;
        for (i = 0; i < 2048; i = i + 1)
            preload_param(i[10:0], 32'd0);
        for (i = 0; i < 1024; i = i + 1)
            preload_buf(i[10:0], 32'd0);
    endtask

    task automatic do_reset;
        begin
            reset = 1; start = 0;
            repeat (5) @(posedge clk);
            #1; reset = 0;
            @(posedge clk); #1;
        end
    endtask

    // Silence SRAM debug traces
    defparam u_buf.sram.VERBOSE   = 0;
    defparam u_param.sram.VERBOSE          = 0;

    // ================================================================
    // VCD dump
    // ================================================================
    initial begin
        $dumpfile("rtl/sim/tb_layer_sequencer.vcd");
        $dumpvars(0, tb_layer_sequencer);
    end

    // ================================================================
    // Main test sequence
    // ================================================================
    initial begin
        total_pass = 0;
        total_fail = 0;

        // ============================================================
        // TEST 1: Smoke test — all-zero weights
        // ============================================================
        $display("\n========================================");
        $display("TEST 1: Smoke test (zero weights)");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        clear_all_memories();

        // Load input image in buf A-region: 196 packed words (4×128 per word)
        begin : blk_t1_load
            integer i;
            for (i = 0; i < 196; i = i + 1)
                preload_buf_a(i[10:0], {8'd128, 8'd128, 8'd128, 8'd128});
        end

        do_reset();

        // Start inference
        start = 1;
        @(posedge clk); #1;

        // Wait for done with timeout
        begin : blk_t1_wait
            integer timeout;
            timeout = 0;
            while (!done_w && timeout < 2_000_000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2_000_000) begin
                $display("FAIL: Test 1 TIMEOUT after %0d cycles", timeout);
                fail_count = fail_count + 1;
            end else begin
                $display("  Inference completed in %0d cycles", timeout);
                pass_count = pass_count + 1;
            end
        end

        // Check prediction
        if (pred_class_out == 4'd0) begin
            $display("  PASS: pred_class=%0d (expected 0 for zero weights)", pred_class_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: pred_class=%0d (expected 0)", pred_class_out);
            fail_count = fail_count + 1;
        end

        start = 0;
        repeat (5) @(posedge clk);

        $display("Test 1 results: %0d PASS, %0d FAIL", pass_count, fail_count);
        total_pass = total_pass + pass_count;
        total_fail = total_fail + fail_count;

        // ============================================================
        // TEST 2: Full MNIST inference (real trained weights, image_0)
        // ============================================================
        $display("\n========================================");
        $display("TEST 2: Full MNIST inference (image_0)");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        clear_all_memories();

        // Load param memory from hex file
        begin : blk_t2_param
            reg [31:0] param_init [0:2047];
            integer i;
            $readmemh("datos_hex_std/PARAM_MEM_32x2048.hex", param_init);
            for (i = 0; i < 2048; i = i + 1)
                preload_param(i[10:0], param_init[i]);
            $display("  Loaded 2048 param words");
        end

        // Load MNIST image_0 — pack 4 pixels per 32-bit word into A-region (196 words)
        begin : blk_t2_img
            reg [7:0] img_pixels [0:783];
            integer i;
            $readmemh("datos_hex_std/test_images/image_0.hex", img_pixels);
            for (i = 0; i < 196; i = i + 1)
                preload_buf_a(i[10:0], {img_pixels[i*4+3], img_pixels[i*4+2],
                                        img_pixels[i*4+1], img_pixels[i*4]});
            $display("  Loaded 196 packed words (784 pixels) into buf A-region");
        end

        adjust_conv1_biases();

        do_reset();

        // Start inference
        start = 1;
        @(posedge clk); #1;

        // Wait for done with timeout
        begin : blk_t2_wait
            integer timeout;
            timeout = 0;
            while (!done_w && timeout < 2_000_000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2_000_000) begin
                $display("  FAIL: Test 2 TIMEOUT after %0d cycles", timeout);
                fail_count = fail_count + 1;
            end else begin
                $display("  Inference completed in %0d cycles", timeout);
                pass_count = pass_count + 1;
            end
        end

        // Expected label for image_0 is 7
        begin : blk_t2_check
            integer expected_label;
            expected_label = 7;
            if (pred_class_out == expected_label[3:0]) begin
                $display("  PASS: pred_class=%0d matches expected label=%0d",
                         pred_class_out, expected_label);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: pred_class=%0d expected=%0d",
                         pred_class_out, expected_label);
                fail_count = fail_count + 1;
            end
        end

        start = 0;
        repeat (5) @(posedge clk);

        $display("Test 2 results: %0d PASS, %0d FAIL", pass_count, fail_count);
        total_pass = total_pass + pass_count;
        total_fail = total_fail + fail_count;

        // ============================================================
        // TEST 3: Second MNIST image (image_1) for regression
        // ============================================================
        $display("\n========================================");
        $display("TEST 3: Full MNIST inference (image_1)");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        // Clear unified buffer + reload params
        begin : blk_t3_clear
            reg [31:0] param_init [0:2047];
            integer i;
            $readmemh("datos_hex_std/PARAM_MEM_32x2048.hex", param_init);
            for (i = 0; i < 2048; i = i + 1)
                preload_param(i[10:0], param_init[i]);
            for (i = 0; i < 1024; i = i + 1)
                preload_buf(i[10:0], 32'd0);
        end

        // Load image_1 — pack 4 pixels per word into A-region (196 words)
        begin : blk_t3_img
            reg [7:0] img_pixels [0:783];
            integer i;
            $readmemh("datos_hex_std/test_images/image_1.hex", img_pixels);
            for (i = 0; i < 196; i = i + 1)
                preload_buf_a(i[10:0], {img_pixels[i*4+3], img_pixels[i*4+2],
                                        img_pixels[i*4+1], img_pixels[i*4]});
            $display("  Loaded image_1 (196 packed words) into buf A-region");
        end

        adjust_conv1_biases();

        do_reset();

        start = 1;
        @(posedge clk); #1;

        begin : blk_t3_wait
            integer timeout;
            timeout = 0;
            while (!done_w && timeout < 2_000_000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 2_000_000) begin
                $display("  FAIL: Test 3 TIMEOUT after %0d cycles", timeout);
                fail_count = fail_count + 1;
            end else begin
                $display("  Inference completed in %0d cycles", timeout);
                pass_count = pass_count + 1;
            end
        end

        // Expected label for image_1 is 2
        begin : blk_t3_check
            integer expected_label;
            expected_label = 2;
            if (pred_class_out == expected_label[3:0]) begin
                $display("  PASS: pred_class=%0d matches expected label=%0d",
                         pred_class_out, expected_label);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: pred_class=%0d expected=%0d",
                         pred_class_out, expected_label);
                fail_count = fail_count + 1;
            end
        end

        start = 0;
        repeat (5) @(posedge clk);

        $display("Test 3 results: %0d PASS, %0d FAIL", pass_count, fail_count);
        total_pass = total_pass + pass_count;
        total_fail = total_fail + fail_count;

        // ============================================================
        // Summary
        // ============================================================
        $display("\n========================================");
        $display("FINAL SUMMARY: %0d PASS, %0d FAIL out of %0d tests",
                 total_pass, total_fail, total_pass + total_fail);
        $display("========================================\n");

        if (total_fail == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

endmodule
