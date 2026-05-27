`timescale 1ns/1ps

module tb_data_bus;

    // Clock / Reset
    reg        clk;
    reg        reset;
    initial clk = 0;
    always #5 clk = ~clk;

    // DUT signals
    reg        is_ic_mode;

    reg [31:0] pixel_din;
    reg        pixel_load;
    reg [1:0]  pixel_byte_sel;
    wire [31:0] pixel_word;

    reg [31:0] weight_din;
    reg        weight_load;
    wire [31:0] weights_word;

    reg [31:0] bias_din;
    reg        bias_load;
    reg [1:0]  bias_lane_sel;
    wire signed [31:0] bias_0, bias_1, bias_2, bias_3;

    reg [31:0] mult_din;
    reg        mult_load;
    reg [1:0]  mult_lane_sel;
    wire signed [31:0] mult_0, mult_1, mult_2, mult_3;

    reg [7:0]  shift_din;
    reg        shift_load;
    wire [7:0] shift_amt;

    reg [31:0] zp_din;
    reg        zp_load;
    wire [7:0] zp_0, zp_1, zp_2, zp_3;

    reg [31:0] result_din;
    reg        result_valid;
    reg [1:0]  result_byte_pos;
    wire [31:0] result_dout;
    wire [3:0]  result_wmask;

    // Counters
    integer pass_count;
    integer fail_count;
    integer test_num;

    // DUT
    data_bus #(
        .DATA_WIDTH(8), .ACC_WIDTH(32)
    ) dut (
        .clk(clk), .reset(reset),
        .is_ic_mode(is_ic_mode),
        .pixel_din(pixel_din), .pixel_load(pixel_load),
        .pixel_byte_sel(pixel_byte_sel), .pixel_word(pixel_word),
        .weight_din(weight_din), .weight_load(weight_load),
        .weights_word(weights_word),
        .bias_din(bias_din), .bias_load(bias_load),
        .bias_lane_sel(bias_lane_sel),
        .bias_0(bias_0), .bias_1(bias_1), .bias_2(bias_2), .bias_3(bias_3),
        .mult_din(mult_din), .mult_load(mult_load),
        .mult_lane_sel(mult_lane_sel),
        .mult_0(mult_0), .mult_1(mult_1), .mult_2(mult_2), .mult_3(mult_3),
        .shift_din(shift_din), .shift_load(shift_load), .shift_amt(shift_amt),
        .zp_din(zp_din), .zp_load(zp_load),
        .zp_0(zp_0), .zp_1(zp_1), .zp_2(zp_2), .zp_3(zp_3),
        .result_din(result_din), .result_valid(result_valid),
        .result_byte_pos(result_byte_pos),
        .result_dout(result_dout), .result_wmask(result_wmask)
    );

    // ---- Helper tasks ----
    task automatic check32(input string label, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("  [%0d] FAIL %-20s got=0x%08X  exp=0x%08X", pass_count+fail_count, label, got, exp);
            fail_count = fail_count + 1;
        end else begin
            $display("  [%0d] PASS %-20s got=0x%08X  exp=0x%08X", pass_count+fail_count, label, got, exp);
            pass_count = pass_count + 1;
        end
    endtask

    task automatic check8(input string label, input [7:0] got, input [7:0] exp);
        if (got !== exp) begin
            $display("  [%0d] FAIL %-20s got=0x%02X      exp=0x%02X", pass_count+fail_count, label, got, exp);
            fail_count = fail_count + 1;
        end else begin
            $display("  [%0d] PASS %-20s got=0x%02X      exp=0x%02X", pass_count+fail_count, label, got, exp);
            pass_count = pass_count + 1;
        end
    endtask

    task automatic check4(input string label, input [3:0] got, input [3:0] exp);
        if (got !== exp) begin
            $display("  [%0d] FAIL %-20s got=4'b%04b  exp=4'b%04b", pass_count+fail_count, label, got, exp);
            fail_count = fail_count + 1;
        end else begin
            $display("  [%0d] PASS %-20s got=4'b%04b  exp=4'b%04b", pass_count+fail_count, label, got, exp);
            pass_count = pass_count + 1;
        end
    endtask

    task automatic deassert_all;
        pixel_load   <= 0;
        weight_load  <= 0;
        bias_load    <= 0;
        mult_load    <= 0;
        shift_load   <= 0;
        zp_load      <= 0;
        result_valid <= 0;
    endtask

    // ---- Main test ----
    initial begin
        $dumpfile("rtl/sim/tb_data_bus.vcd");
        $dumpvars(0, tb_data_bus);

        pass_count = 0;
        fail_count = 0;
        test_num   = 0;

        // Initialize all inputs
        is_ic_mode      = 0;
        pixel_din       = 0; pixel_load = 0; pixel_byte_sel = 0;
        weight_din      = 0; weight_load = 0;
        bias_din        = 0; bias_load = 0; bias_lane_sel = 0;
        mult_din        = 0; mult_load = 0; mult_lane_sel = 0;
        shift_din       = 0; shift_load = 0;
        zp_din          = 0; zp_load = 0;
        result_din      = 0; result_valid = 0; result_byte_pos = 0;

        // Reset
        reset = 1;
        @(posedge clk); @(posedge clk);
        #1; reset = 0;
        @(posedge clk); #1;

        // ==================================================================
        // TEST 1: Pixel OC mode — byte selection
        // ==================================================================
        test_num = 1;
        $display("=== Test %0d: Pixel OC mode (byte selection) ===", test_num);
        is_ic_mode = 0;
        pixel_din  = 32'hDDCCBBAA;
        pixel_load = 1;
        @(posedge clk); #1;
        pixel_load = 0;

        // Check each byte selection
        pixel_byte_sel = 2'd0;
        #1; check32("byte0", pixel_word, {24'b0, 8'hAA});

        pixel_byte_sel = 2'd1;
        #1; check32("byte1", pixel_word, {24'b0, 8'hBB});

        pixel_byte_sel = 2'd2;
        #1; check32("byte2", pixel_word, {24'b0, 8'hCC});

        pixel_byte_sel = 2'd3;
        #1; check32("byte3", pixel_word, {24'b0, 8'hDD});

        @(posedge clk); #1;

        // ==================================================================
        // TEST 2: Pixel IC mode — full word passthrough
        // ==================================================================
        test_num = 2;
        $display("=== Test %0d: Pixel IC mode (word passthrough) ===", test_num);
        is_ic_mode = 1;
        pixel_din  = 32'h04030201;
        pixel_load = 1;
        @(posedge clk); #1;
        pixel_load = 0;
        #1;

        check32("ic_word", pixel_word, 32'h04030201);
        @(posedge clk); #1;

        // Verify byte_sel is ignored in IC mode
        pixel_byte_sel = 2'd2;
        #1; check32("ic_ignore_sel", pixel_word, 32'h04030201);

        @(posedge clk); #1;

        // ==================================================================
        // TEST 3: Weight register — load and hold
        // ==================================================================
        test_num = 3;
        $display("=== Test %0d: Weight register ===", test_num);
        is_ic_mode = 0;

        // Load first value
        weight_din  = 32'hCAFEBABE;
        weight_load = 1;
        @(posedge clk); #1;
        weight_load = 0;
        #1;
        check32("w_load1", weights_word, 32'hCAFEBABE);

        // Verify hold (no load)
        weight_din = 32'hDEADBEEF;  // din changes but load=0
        @(posedge clk); #1;
        check32("w_hold", weights_word, 32'hCAFEBABE);

        // Load second value
        weight_load = 1;
        @(posedge clk); #1;
        weight_load = 0;
        #1;
        check32("w_load2", weights_word, 32'hDEADBEEF);

        @(posedge clk); #1;

        // ==================================================================
        // TEST 4: Config registers (bias, mult, shift, zp)
        // ==================================================================
        test_num = 4;
        $display("=== Test %0d: Config registers (bias, mult, shift, zp) ===", test_num);
        begin : blk_test4
            integer lane;
            integer bias_vals [0:3];
            integer mult_vals [0:3];

            bias_vals[0] = 32'h00000100;  // +256
            bias_vals[1] = 32'hFFFFFF00;  // -256 (signed)
            bias_vals[2] = 32'h00007FFF;  // +32767
            bias_vals[3] = 32'hFFFF8000;  // -32768

            mult_vals[0] = 32'h00001234;
            mult_vals[1] = 32'h00005678;
            mult_vals[2] = 32'hFFFFABCD;
            mult_vals[3] = 32'h0000EF01;

            // Load 4 biases, one per lane
            for (lane = 0; lane < 4; lane = lane + 1) begin
                bias_din      = bias_vals[lane];
                bias_lane_sel = lane[1:0];
                bias_load     = 1;
                @(posedge clk); #1;
            end
            bias_load = 0;
            #1;

            check32("bias_0", bias_0, bias_vals[0]);
            check32("bias_1", bias_1, bias_vals[1]);
            check32("bias_2", bias_2, bias_vals[2]);
            check32("bias_3", bias_3, bias_vals[3]);

            // Load 4 mults, one per lane
            for (lane = 0; lane < 4; lane = lane + 1) begin
                mult_din      = mult_vals[lane];
                mult_lane_sel = lane[1:0];
                mult_load     = 1;
                @(posedge clk); #1;
            end
            mult_load = 0;
            #1;

            check32("mult_0", mult_0, mult_vals[0]);
            check32("mult_1", mult_1, mult_vals[1]);
            check32("mult_2", mult_2, mult_vals[2]);
            check32("mult_3", mult_3, mult_vals[3]);

            // Load shift
            shift_din  = 8'hA5;
            shift_load = 1;
            @(posedge clk); #1;
            shift_load = 0;
            #1;
            check8("shift", shift_amt, 8'hA5);

            // Load zero-points (packed word)
            zp_din  = 32'hD4C3B2A1;  // zp3=D4, zp2=C3, zp1=B2, zp0=A1
            zp_load = 1;
            @(posedge clk); #1;
            zp_load = 0;
            #1;
            check8("zp_0", zp_0, 8'hA1);
            check8("zp_1", zp_1, 8'hB2);
            check8("zp_2", zp_2, 8'hC3);
            check8("zp_3", zp_3, 8'hD4);
        end
        @(posedge clk); #1;

        // ==================================================================
        // TEST 5: Result OC mode — passthrough
        // ==================================================================
        test_num = 5;
        $display("=== Test %0d: Result OC mode (passthrough) ===", test_num);
        is_ic_mode     = 0;
        result_din     = 32'hAABBCCDD;
        result_valid   = 1;
        result_byte_pos = 2'd0;  // ignored in OC mode
        #1;

        check32("res_oc_dout", result_dout, 32'hAABBCCDD);
        check4("res_oc_wmask", result_wmask, 4'b1111);

        result_valid = 0;
        @(posedge clk); #1;

        // ==================================================================
        // TEST 6: Result IC mode — byte replicate + wmask
        // ==================================================================
        test_num = 6;
        $display("=== Test %0d: Result IC mode (byte replicate + wmask) ===", test_num);
        is_ic_mode   = 1;
        result_din   = 32'h00000042;
        result_valid = 1;
        begin : blk_test6
            integer pos;
            reg [3:0] exp_wmask;
            for (pos = 0; pos < 4; pos = pos + 1) begin
                result_byte_pos = pos[1:0];
                exp_wmask = (4'b0001 << pos);
                #1;
                check32($sformatf("res_ic_dout_pos%0d", pos), result_dout, 32'h42424242);
                check4($sformatf("res_ic_wmask_pos%0d", pos), result_wmask, exp_wmask);
            end
        end

        result_valid = 0;
        @(posedge clk); #1;

        // ==================================================================
        // TEST 7: Reset clears all registers
        // ==================================================================
        test_num = 7;
        $display("=== Test %0d: Reset clears all registers ===", test_num);

        // First ensure registers have non-zero values (from previous tests)
        // Apply reset
        reset = 1;
        @(posedge clk); @(posedge clk);
        #1; reset = 0;
        @(posedge clk); #1;

        is_ic_mode = 0;
        pixel_byte_sel = 0;
        #1;

        check32("rst_pixel",   pixel_word,   32'h0);
        check32("rst_weight",  weights_word,  32'h0);
        check32("rst_bias0",   bias_0,        32'h0);
        check32("rst_bias1",   bias_1,        32'h0);
        check32("rst_bias2",   bias_2,        32'h0);
        check32("rst_bias3",   bias_3,        32'h0);
        check32("rst_mult0",   mult_0,        32'h0);
        check32("rst_mult1",   mult_1,        32'h0);
        check32("rst_mult2",   mult_2,        32'h0);
        check32("rst_mult3",   mult_3,        32'h0);
        check8("rst_shift",    shift_amt,     8'h0);
        check8("rst_zp0",      zp_0,          8'h0);
        check8("rst_zp1",      zp_1,          8'h0);
        check8("rst_zp2",      zp_2,          8'h0);
        check8("rst_zp3",      zp_3,          8'h0);

        // ==================================================================
        // SUMMARY
        // ==================================================================
        $display("");
        $display("====================================");
        $display("  TOTAL: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $display("====================================");

        $finish;
    end

endmodule
