// tb_gap_fc_layer_ctrl.sv — Integration testbench for gap_fc_layer_ctrl
// Instantiates: gap_fc_layer_ctrl + param_memory + activation_buffer (single, muxed) +
//               data_bus + compute_top
// Test 1: GAP with identity values (32 OC, constant per channel)
// Test 2: GAP with varying spatial values
// Test 3: FC only (preload GAP results, skip GAP)
// Test 4: Full pipeline GAP -> FC -> ArgMax

`timescale 1ns/1ps

module tb_gap_fc_layer_ctrl;

    // ================================================================
    // Clock / Reset
    // ================================================================
    reg clk, reset;
    initial clk = 0;
    always #5 clk = ~clk;

    // ================================================================
    // DUT signals
    // ================================================================
    reg         start;
    wire        done;

    // Config
    reg  [10:0] cfg_gap_rd_base;
    reg  [10:0] cfg_gap_wr_base;
    reg  [10:0] cfg_fc_wr_base;
    reg  [10:0] cfg_fc_weight_base;
    reg  [10:0] cfg_fc_bias_base;
    reg  [10:0] cfg_fc_mult_base;
    reg  [10:0] cfg_fc_zp_base;
    reg  [7:0]  cfg_fc_shift;

    // Act buffer read (ctrl -> mux -> buffer)
    wire [10:0] act_rd_addr;
    wire        act_rd_request;
    wire        act_rd_read_writeb;
    wire [31:0] act_rd_dout;
    wire        act_rd_valid;

    // Act buffer write (ctrl -> mux -> buffer)
    wire [10:0] act_wr_addr;
    wire [31:0] act_wr_din;
    wire [3:0]  act_wr_wmask;
    wire        act_wr_request;
    wire        act_wr_read_writeb;
    wire        act_wr_valid;

    // Param memory
    wire [10:0] param_addr_ctrl;
    wire        param_request_ctrl;
    wire        param_read_writeb;
    wire [31:0] param_dout;
    wire        param_valid;

    // Data bus ctrl -> data_bus
    wire [31:0] db_pixel_din;
    wire        db_pixel_load;
    wire [1:0]  db_pixel_byte_sel;
    wire [31:0] db_weight_din;
    wire        db_weight_load;
    wire [31:0] db_bias_din;
    wire        db_bias_load;
    wire [1:0]  db_bias_lane_sel;
    wire [31:0] db_mult_din;
    wire        db_mult_load;
    wire [1:0]  db_mult_lane_sel;
    wire [7:0]  db_shift_din;
    wire        db_shift_load;
    wire [31:0] db_zp_din;
    wire        db_zp_load;

    // Compute top ctrl
    wire [1:0]  ct_compute_mode;
    wire        ct_gap_req;
    wire        ct_argmax_req;
    wire        ct_core_req;
    wire        ct_core_acc_clear;
    wire        ct_core_process_out;
    wire        ct_core_frame_start;
    wire [31:0] ct_data_out_32b;
    wire        ct_valid_out;
    wire [3:0]  ct_pred_class;
    wire        ct_classification_done;

    // Final outputs
    wire [3:0]  pred_class_out;
    wire        classification_valid;

    // Data bus outputs -> compute top
    wire [31:0] pixel_word;
    wire [31:0] weights_word;
    wire signed [31:0] bias_0, bias_1, bias_2, bias_3;
    wire signed [31:0] mult_0, mult_1, mult_2, mult_3;
    wire [7:0]  shift_amt;
    wire [7:0]  zp_0, zp_1, zp_2, zp_3;
    wire [31:0] result_dout;
    wire [3:0]  result_wmask;

    // ================================================================
    // Testbench buffer control: mux between TB preload and DUT
    // ================================================================
    reg         tb_mode;           // 1=TB controls act buffer, 0=DUT controls
    reg  [10:0] tb_act_addr;
    reg  [31:0] tb_act_din;
    reg  [3:0]  tb_act_wmask;
    reg         tb_act_read_writeb;
    reg         tb_act_request;
    wire [31:0] tb_act_dout;
    wire        tb_act_valid;

    // Muxed activation buffer signals
    wire [10:0] act_buf_addr;
    wire [31:0] act_buf_din;
    wire [3:0]  act_buf_wmask;
    wire        act_buf_read_writeb;
    wire        act_buf_request;
    wire [31:0] act_buf_dout;
    wire        act_buf_valid;

    // TB mode: testbench controls; DUT mode: controller controls (read or write)
    assign act_buf_addr = tb_mode ? tb_act_addr :
                          (act_wr_request ? act_wr_addr : act_rd_addr);
    assign act_buf_din  = tb_mode ? tb_act_din : act_wr_din;
    assign act_buf_wmask = tb_mode ? tb_act_wmask :
                           (act_wr_request ? act_wr_wmask : 4'b1111);
    assign act_buf_read_writeb = tb_mode ? tb_act_read_writeb :
                                 (act_wr_request ? 1'b0 : 1'b1);
    assign act_buf_request = tb_mode ? tb_act_request :
                             (act_rd_request | act_wr_request);

    assign act_rd_dout  = act_buf_dout;
    assign act_rd_valid = (~tb_mode & act_rd_request) ? act_buf_valid : 1'b0;
    assign act_wr_valid = (~tb_mode & act_wr_request) ? act_buf_valid : 1'b0;
    assign tb_act_dout  = act_buf_dout;
    assign tb_act_valid = (tb_mode) ? act_buf_valid : 1'b0;

    // Param memory mux for TB preload
    reg         tb_param_mode;
    reg  [10:0] tb_param_addr;
    reg  [31:0] tb_param_din;
    reg         tb_param_read_writeb;
    reg         tb_param_request;
    wire [31:0] tb_param_dout;
    wire        tb_param_valid_raw;

    wire [10:0] param_mem_addr;
    wire [31:0] param_mem_din;
    wire        param_mem_read_writeb;
    wire        param_mem_request;
    wire [31:0] param_mem_dout;
    wire        param_mem_valid;

    assign param_mem_addr        = tb_param_mode ? tb_param_addr : param_addr_ctrl;
    assign param_mem_din         = tb_param_mode ? tb_param_din : 32'd0;
    assign param_mem_read_writeb = tb_param_mode ? tb_param_read_writeb : param_read_writeb;
    assign param_mem_request     = tb_param_mode ? tb_param_request : param_request_ctrl;
    assign param_dout            = param_mem_dout;
    assign param_valid           = (~tb_param_mode) ? param_mem_valid : 1'b0;

    // ================================================================
    // DUT: gap_fc_layer_ctrl
    // ================================================================
    gap_fc_layer_ctrl u_ctrl (
        .clk(clk), .reset(reset),
        .start(start), .done(done),
        .cfg_gap_rd_base(cfg_gap_rd_base),
        .cfg_gap_wr_base(cfg_gap_wr_base),
        .cfg_fc_wr_base(cfg_fc_wr_base),
        .cfg_fc_weight_base(cfg_fc_weight_base),
        .cfg_fc_bias_base(cfg_fc_bias_base),
        .cfg_fc_mult_base(cfg_fc_mult_base),
        .cfg_fc_zp_base(cfg_fc_zp_base),
        .cfg_fc_shift(cfg_fc_shift),
        // Act read
        .act_rd_addr(act_rd_addr),
        .act_rd_request(act_rd_request),
        .act_rd_read_writeb(act_rd_read_writeb),
        .act_rd_dout(act_rd_dout),
        .act_rd_valid(act_rd_valid),
        // Act write
        .act_wr_addr(act_wr_addr),
        .act_wr_din(act_wr_din),
        .act_wr_wmask(act_wr_wmask),
        .act_wr_request(act_wr_request),
        .act_wr_read_writeb(act_wr_read_writeb),
        .act_wr_valid(act_wr_valid),
        // Param
        .param_addr(param_addr_ctrl),
        .param_request(param_request_ctrl),
        .param_read_writeb(param_read_writeb),
        .param_dout(param_dout),
        .param_valid(param_valid),
        // Data bus
        .db_pixel_din(db_pixel_din),
        .db_pixel_load(db_pixel_load),
        .db_pixel_byte_sel(db_pixel_byte_sel),
        .db_weight_din(db_weight_din),
        .db_weight_load(db_weight_load),
        .db_bias_din(db_bias_din),
        .db_bias_load(db_bias_load),
        .db_bias_lane_sel(db_bias_lane_sel),
        .db_mult_din(db_mult_din),
        .db_mult_load(db_mult_load),
        .db_mult_lane_sel(db_mult_lane_sel),
        .db_shift_din(db_shift_din),
        .db_shift_load(db_shift_load),
        .db_zp_din(db_zp_din),
        .db_zp_load(db_zp_load),
        // Compute top
        .ct_compute_mode(ct_compute_mode),
        .ct_gap_req(ct_gap_req),
        .ct_argmax_req(ct_argmax_req),
        .ct_core_req(ct_core_req),
        .ct_core_acc_clear(ct_core_acc_clear),
        .ct_core_process_out(ct_core_process_out),
        .ct_core_frame_start(ct_core_frame_start),
        .ct_data_out_32b(ct_data_out_32b),
        .ct_valid_out(ct_valid_out),
        .ct_pred_class(ct_pred_class),
        .ct_classification_done(ct_classification_done),
        // Final
        .pred_class_out(pred_class_out),
        .classification_valid(classification_valid)
    );

    // ================================================================
    // Data Bus
    // ================================================================
    data_bus u_data_bus (
        .clk(clk), .reset(reset),
        .is_ic_mode(1'b0),          // Always OC mode for GAP/FC/ArgMax
        .pixel_din(db_pixel_din),
        .pixel_load(db_pixel_load),
        .pixel_byte_sel(db_pixel_byte_sel),
        .pixel_word(pixel_word),
        .weight_din(db_weight_din),
        .weight_load(db_weight_load),
        .weights_word(weights_word),
        .bias_din(db_bias_din),
        .bias_load(db_bias_load),
        .bias_lane_sel(db_bias_lane_sel),
        .bias_0(bias_0), .bias_1(bias_1), .bias_2(bias_2), .bias_3(bias_3),
        .mult_din(db_mult_din),
        .mult_load(db_mult_load),
        .mult_lane_sel(db_mult_lane_sel),
        .mult_0(mult_0), .mult_1(mult_1), .mult_2(mult_2), .mult_3(mult_3),
        .shift_din(db_shift_din),
        .shift_load(db_shift_load),
        .shift_amt(shift_amt),
        .zp_din(db_zp_din),
        .zp_load(db_zp_load),
        .zp_0(zp_0), .zp_1(zp_1), .zp_2(zp_2), .zp_3(zp_3),
        .result_din(ct_data_out_32b),
        .result_valid(ct_valid_out),
        .result_byte_pos(2'd0),
        .result_dout(result_dout),
        .result_wmask(result_wmask)
    );

    // ================================================================
    // Compute Top
    // ================================================================
    compute_top u_compute (
        .clk(clk), .reset(reset),
        .compute_mode(ct_compute_mode),
        .is_parallel_ic(1'b0),       // OC-parallel for FC
        .core_req(ct_core_req),
        .core_acc_clear(ct_core_acc_clear),
        .core_process_out(ct_core_process_out),
        .core_frame_start(ct_core_frame_start),
        .core_relu_en(1'b1),         // ReLU on for FC
        .core_pool_en(1'b0),         // No pooling
        .core_img_width(6'd10),      // Don't care (pool off)
        .gap_req(ct_gap_req),
        .argmax_req(ct_argmax_req),
        .weights_word(weights_word),
        .pixel_word(pixel_word),
        .bias_0(bias_0), .bias_1(bias_1), .bias_2(bias_2), .bias_3(bias_3),
        .mult_0(mult_0), .mult_1(mult_1), .mult_2(mult_2), .mult_3(mult_3),
        .shift_amt(shift_amt),
        .zp_0(zp_0), .zp_1(zp_1), .zp_2(zp_2), .zp_3(zp_3),
        .data_out_32b(ct_data_out_32b),
        .valid_out(ct_valid_out),
        .pred_class(ct_pred_class),
        .classification_done(ct_classification_done)
    );

    // ================================================================
    // Activation Buffer (single, muxed for read and write)
    // ================================================================
    activation_buffer u_act_buf (
        .clk(clk), .reset(reset),
        .addr(act_buf_addr),
        .din(act_buf_din),
        .wmask(act_buf_wmask),
        .read_writeb(act_buf_read_writeb),
        .request(act_buf_request),
        .dout(act_buf_dout),
        .valid(act_buf_valid)
    );

    // ================================================================
    // Param Memory
    // ================================================================
    param_memory u_param (
        .clk(clk), .reset(reset),
        .addr(param_mem_addr),
        .din(param_mem_din),
        .read_writeb(param_mem_read_writeb),
        .request(param_mem_request),
        .dout(param_mem_dout),
        .valid(param_mem_valid)
    );

    // ================================================================
    // Helper: backdoor memory access
    // ================================================================
    task automatic preload_act(input [10:0] addr, input [31:0] data);
        // Backdoor write to activation buffer (single 1024-word SRAM)
        u_act_buf.sram.mem[addr[9:0]] = data;
    endtask

    function automatic [31:0] read_act(input [10:0] addr);
        // Backdoor read from activation buffer (single 1024-word SRAM)
        read_act = u_act_buf.sram.mem[addr[9:0]];
    endfunction

    task automatic preload_param(input [10:0] addr, input [31:0] data);
        // Backdoor write to param memory (single 2048-word SRAM)
        u_param.sram.mem[addr[10:0]] = data;
    endtask

    // ================================================================
    // Test infrastructure
    // ================================================================
    integer pass_cnt, fail_cnt, total_tests;

    task automatic check8(input string label, input [7:0] got, input [7:0] exp);
        total_tests = total_tests + 1;
        if (got === exp) begin
            pass_cnt = pass_cnt + 1;
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL %s: got=%02h (%0d) exp=%02h (%0d)",
                     label, got, $signed(got), exp, $signed(exp));
        end
    endtask

    task automatic check4(input string label, input [3:0] got, input [3:0] exp);
        total_tests = total_tests + 1;
        if (got === exp) begin
            pass_cnt = pass_cnt + 1;
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  FAIL %s: got=%0d exp=%0d", label, got, exp);
        end
    endtask

    // ================================================================
    // Main test
    // ================================================================
    initial begin
        $dumpfile("rtl/sim/tb_gap_fc_layer_ctrl.vcd");
        $dumpvars(0, tb_gap_fc_layer_ctrl);

        pass_cnt = 0;
        fail_cnt = 0;
        total_tests = 0;

        reset = 1; start = 0;
        tb_mode = 0; tb_param_mode = 0;
        tb_act_addr = 0; tb_act_din = 0; tb_act_wmask = 0;
        tb_act_read_writeb = 1; tb_act_request = 0;
        tb_param_addr = 0; tb_param_din = 0;
        tb_param_read_writeb = 1; tb_param_request = 0;
        cfg_gap_rd_base = 0; cfg_gap_wr_base = 0;
        cfg_fc_wr_base = 0; cfg_fc_weight_base = 0;
        cfg_fc_bias_base = 0; cfg_fc_mult_base = 0;
        cfg_fc_zp_base = 0; cfg_fc_shift = 0;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // ==============================================================
        $display("\n=== TEST 1: GAP with identity values (32 OC) ===");
        test1_gap_identity();

        // ==============================================================
        $display("\n=== TEST 2: GAP with varying spatial values ===");
        test2_gap_varying();

        // ==============================================================
        $display("\n=== TEST 3: FC only (preload GAP results) ===");
        test3_fc_only();

        // ==============================================================
        $display("\n=== TEST 4: Full pipeline GAP -> FC -> ArgMax ===");
        test4_full_pipeline();

        // ==============================================================
        $display("\n========================================");
        if (fail_cnt == 0)
            $display("ALL PASS: %0d / %0d tests passed", pass_cnt, total_tests);
        else
            $display("FAIL: %0d passed, %0d failed out of %0d", pass_cnt, fail_cnt, total_tests);
        $display("========================================\n");
        $finish;
    end

    // ================================================================
    // TEST 1: GAP with identity values
    //   Conv3 output: 3x3 spatial x 32 OC
    //   Each OC channel has constant value = (oc+1) across all 9 positions
    //   Expected GAP output = same value (avg of 9 identical = value)
    //   Only runs GAP phase (FC/ArgMax will run but we verify GAP output)
    // ================================================================
    task automatic test1_gap_identity();
        integer sp, oc, oc_group;
        integer saved_pass, saved_fail;
        saved_pass = pass_cnt;
        saved_fail = fail_cnt;

        // Reset DUT
        reset = 1;
        repeat (3) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // --- Preload Conv3 output: 9 spatial x 8 OC-words ---
        // Memory layout: addr = gap_rd_base + sp * 8 + oc_group
        // Each word has 4 OC bytes: {oc*4+3, oc*4+2, oc*4+1, oc*4+0} value
        // Value for OC channel c = c+1
        for (sp = 0; sp < 9; sp = sp + 1) begin
            for (oc_group = 0; oc_group < 8; oc_group = oc_group + 1) begin
                begin
                    reg [7:0] b0, b1, b2, b3;
                    b0 = 8'(oc_group * 4 + 1);     // OC oc_group*4 + 0
                    b1 = 8'(oc_group * 4 + 2);     // OC oc_group*4 + 1
                    b2 = 8'(oc_group * 4 + 3);     // OC oc_group*4 + 2
                    b3 = 8'(oc_group * 4 + 4);     // OC oc_group*4 + 3
                    preload_act(11'd0 + sp * 8 + oc_group, {b3, b2, b1, b0});
                end
            end
        end

        // Preload dummy FC params (won't verify FC output in this test)
        // Need bias, mult, zp, weights for FC to not stall
        for (oc = 0; oc < 12; oc = oc + 1) preload_param(11'd400 + oc, 32'd0); // bias
        for (oc = 0; oc < 12; oc = oc + 1) preload_param(11'd412 + oc, 32'd1); // mult
        for (oc = 0; oc < 3; oc = oc + 1)  preload_param(11'd424 + oc, 32'd0); // zp
        for (oc = 0; oc < 96; oc = oc + 1) preload_param(11'd0 + oc, 32'd0);   // weights

        // --- Configure ---
        cfg_gap_rd_base    = 11'd0;
        cfg_gap_wr_base    = 11'd100;   // GAP output at addr 100..131
        cfg_fc_wr_base     = 11'd200;
        cfg_fc_weight_base = 11'd0;
        cfg_fc_bias_base   = 11'd400;
        cfg_fc_mult_base   = 11'd412;
        cfg_fc_zp_base     = 11'd424;
        cfg_fc_shift       = 8'd0;

        // --- Start ---
        tb_mode = 0; tb_param_mode = 0;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // --- Wait for done ---
        wait (done == 1'b1);
        repeat (3) @(posedge clk);

        // --- Verify GAP output ---
        begin : blk_verify_t1
            integer oc_v;
            integer gap_golden;
            reg [7:0] g_byte, hw_byte;
            reg [31:0] hw_word;
            string label;

            for (oc_v = 0; oc_v < 32; oc_v = oc_v + 1) begin
                hw_word = read_act(11'd100 + oc_v);
                hw_byte = hw_word[7:0];  // GAP output in byte 0

                // Golden: average of 9 identical values (oc_v+1)
                // gap_unit: sum * 0x1C72 >> 16
                // sum = 9 * (oc_v+1)
                // avg = (9*(oc_v+1) * 0x1C72) >> 16
                gap_golden = (9 * (oc_v + 1) * 16'h1C72) >>> 16;
                // Clamp to signed 8-bit
                if (gap_golden > 127) gap_golden = 127;
                if (gap_golden < -128) gap_golden = -128;
                g_byte = gap_golden[7:0];

                $sformat(label, "T1_GAP[oc%0d]", oc_v);
                check8(label, hw_byte, g_byte);
            end
        end

        $display("  Test 1 done: %0d pass, %0d fail (cumulative)", pass_cnt, fail_cnt);
    endtask

    // ================================================================
    // TEST 2: GAP with varying spatial values
    //   Each channel c has spatial values: sp*4 + c (mod 128)
    //   Verify average computation
    // ================================================================
    task automatic test2_gap_varying();
        integer sp, oc, oc_group;
        integer saved_pass, saved_fail;
        saved_pass = pass_cnt;
        saved_fail = fail_cnt;

        // Reset DUT
        reset = 1;
        repeat (3) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // --- Preload Conv3 output with varying values ---
        for (sp = 0; sp < 9; sp = sp + 1) begin
            for (oc_group = 0; oc_group < 8; oc_group = oc_group + 1) begin
                begin
                    reg [7:0] b0, b1, b2, b3;
                    b0 = 8'((sp * 4 + oc_group * 4 + 0) % 64);
                    b1 = 8'((sp * 4 + oc_group * 4 + 1) % 64);
                    b2 = 8'((sp * 4 + oc_group * 4 + 2) % 64);
                    b3 = 8'((sp * 4 + oc_group * 4 + 3) % 64);
                    preload_act(11'd0 + sp * 8 + oc_group, {b3, b2, b1, b0});
                end
            end
        end

        // Dummy FC params
        for (oc = 0; oc < 12; oc = oc + 1) preload_param(11'd400 + oc, 32'd0);
        for (oc = 0; oc < 12; oc = oc + 1) preload_param(11'd412 + oc, 32'd1);
        for (oc = 0; oc < 3; oc = oc + 1)  preload_param(11'd424 + oc, 32'd0);
        for (oc = 0; oc < 96; oc = oc + 1) preload_param(11'd0 + oc, 32'd0);

        cfg_gap_rd_base    = 11'd0;
        cfg_gap_wr_base    = 11'd100;
        cfg_fc_wr_base     = 11'd200;
        cfg_fc_weight_base = 11'd0;
        cfg_fc_bias_base   = 11'd400;
        cfg_fc_mult_base   = 11'd412;
        cfg_fc_zp_base     = 11'd424;
        cfg_fc_shift       = 8'd0;

        tb_mode = 0; tb_param_mode = 0;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait (done == 1'b1);
        repeat (3) @(posedge clk);

        // --- Verify ---
        begin : blk_verify_t2
            integer oc_v, sp_v;
            integer gap_sum, gap_golden;
            integer px_signed;
            reg [7:0] px_byte, g_byte, hw_byte;
            reg [31:0] hw_word;
            string label;

            for (oc_v = 0; oc_v < 32; oc_v = oc_v + 1) begin
                hw_word = read_act(11'd100 + oc_v);
                hw_byte = hw_word[7:0];

                // Golden: sum of 9 spatial values, then divide by 9
                gap_sum = 0;
                for (sp_v = 0; sp_v < 9; sp_v = sp_v + 1) begin
                    px_byte = 8'((sp_v * 4 + oc_v) % 64);
                    px_signed = $signed(px_byte);
                    gap_sum = gap_sum + px_signed;
                end
                // gap_unit: current_avg = (sum * 0x1C72) >> 16  (arithmetic shift from signed)
                gap_golden = (gap_sum * 16'h1C72) >>> 16;
                if (gap_golden > 127) gap_golden = 127;
                if (gap_golden < -128) gap_golden = -128;
                g_byte = gap_golden[7:0];

                $sformat(label, "T2_GAP[oc%0d]", oc_v);
                check8(label, hw_byte, g_byte);
            end
        end

        $display("  Test 2 done: %0d pass, %0d fail (cumulative)", pass_cnt, fail_cnt);
    endtask

    // ================================================================
    // TEST 3: FC only
    //   Preload GAP results directly, verify FC output
    //   bias=0, mult=1, shift=0, zp=0 (identity requant)
    //   Weights: simple known pattern
    //   GAP values: all 1 (so each FC neuron output = sum of 32 weights)
    // ================================================================
    task automatic test3_fc_only();
        integer i, g;
        integer saved_pass, saved_fail;
        saved_pass = pass_cnt;
        saved_fail = fail_cnt;

        // Reset DUT
        reset = 1;
        repeat (3) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // --- Preload GAP results at gap_wr_base ---
        // All GAP values = 1 (in byte 0 of each word)
        for (i = 0; i < 32; i = i + 1) begin
            preload_act(11'd100 + i, {24'd0, 8'd1});
        end

        // Also preload Conv3 data for GAP (identity: all same value per channel = 1)
        // GAP will still run, but we want it to produce value=1 for each channel
        // Value=1 across 9 positions: avg = (9*1*0x1C72)>>16 = 0x9*0x1C72 = 0xFF06 >> 16 = 0
        // Hmm, that gives 0 not 1. Let me preload GAP results directly and verify FC output
        // by checking after GAP overwrites.

        // Better approach: preload Conv3 to produce known GAP output, then verify FC.
        // For GAP value=1: need sum*0x1C72>>16 = 1 → sum = 65536/0x1C72 ≈ 9.0
        // So 9 pixels of value 1 gives sum=9, 9*7282 = 65538, >>16 = 0. Not 1.
        // Actually: (9 * 0x1C72) = 9 * 7282 = 65538 = 0x10002. >> 16 = 1. Yes!
        // So GAP value 1 = 9 pixels of value 1. That works.

        for (i = 0; i < 9; i = i + 1) begin
            for (g = 0; g < 8; g = g + 1) begin
                preload_act(11'd0 + i * 8 + g, {8'd1, 8'd1, 8'd1, 8'd1});
            end
        end

        // FC weights: group g, input i: weight_word = {w3, w2, w1, w0}
        // Use weight = 1 for all → each neuron output = 32
        // With identity requant + ReLU: output = 32
        for (g = 0; g < 3; g = g + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                preload_param(11'd0 + g * 32 + i, {8'd1, 8'd1, 8'd1, 8'd1});
            end
        end

        // FC bias = 0
        for (i = 0; i < 12; i = i + 1) preload_param(11'd400 + i, 32'd0);
        // FC mult = 1
        for (i = 0; i < 12; i = i + 1) preload_param(11'd412 + i, 32'd1);
        // FC zp = 0
        for (i = 0; i < 3; i = i + 1)  preload_param(11'd424 + i, 32'd0);

        cfg_gap_rd_base    = 11'd0;
        cfg_gap_wr_base    = 11'd100;
        cfg_fc_wr_base     = 11'd200;
        cfg_fc_weight_base = 11'd0;
        cfg_fc_bias_base   = 11'd400;
        cfg_fc_mult_base   = 11'd412;
        cfg_fc_zp_base     = 11'd424;
        cfg_fc_shift       = 8'd0;

        tb_mode = 0; tb_param_mode = 0;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait (done == 1'b1);
        repeat (3) @(posedge clk);

        // --- Verify GAP output first ---
        begin : blk_verify_t3_gap
            integer oc_v;
            reg [31:0] hw_word;
            reg [7:0] hw_byte;
            string label;

            for (oc_v = 0; oc_v < 32; oc_v = oc_v + 1) begin
                hw_word = read_act(11'd100 + oc_v);
                hw_byte = hw_word[7:0];
                // Each channel: 9 values of 1, sum=9, (9*0x1C72)>>16 = 1
                $sformat(label, "T3_GAP[oc%0d]", oc_v);
                check8(label, hw_byte, 8'd1);
            end
        end

        // --- Verify FC output ---
        begin : blk_verify_t3_fc
            integer grp, lane;
            integer fc_acc, fc_golden;
            reg [7:0] g_byte, hw_byte;
            reg [31:0] hw_word;
            string label;

            for (grp = 0; grp < 3; grp = grp + 1) begin
                hw_word = read_act(11'd200 + grp);
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if (grp * 4 + lane < 10) begin  // Only 10 valid neurons
                        hw_byte = hw_word[lane*8 +: 8];
                        // Golden: sum of 32 inputs (each=1) * weight (each=1) = 32
                        // Identity requant: result = 32
                        // ReLU: 32 > 0, passes through
                        fc_golden = 32;
                        if (fc_golden > 127) fc_golden = 127;
                        g_byte = fc_golden[7:0];
                        $sformat(label, "T3_FC[n%0d]", grp * 4 + lane);
                        check8(label, hw_byte, g_byte);
                    end
                end
            end
        end

        $display("  Test 3 done: %0d pass, %0d fail (cumulative)", pass_cnt, fail_cnt);
    endtask

    // ================================================================
    // TEST 4: Full pipeline GAP -> FC -> ArgMax
    //   Conv3 data chosen so that one specific class wins
    //   Verify pred_class_out matches expected
    // ================================================================
    task automatic test4_full_pipeline();
        integer sp, g, i, lane;
        integer saved_pass, saved_fail;
        saved_pass = pass_cnt;
        saved_fail = fail_cnt;

        // Reset DUT
        reset = 1;
        repeat (3) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // --- Preload Conv3 output ---
        // OC channel c: value = (c == 5) ? 9 : 1 across all spatial positions
        // After GAP: channel 5 = (9*9*0x1C72)>>16 = (81*7282)>>16 = 589842>>16 = 8 (approx 9)
        //            others   = (9*1*0x1C72)>>16 = 1
        for (sp = 0; sp < 9; sp = sp + 1) begin
            for (g = 0; g < 8; g = g + 1) begin
                begin
                    reg [7:0] b0, b1, b2, b3;
                    b0 = (g * 4 + 0 == 5) ? 8'd9 : 8'd1;
                    b1 = (g * 4 + 1 == 5) ? 8'd9 : 8'd1;
                    b2 = (g * 4 + 2 == 5) ? 8'd9 : 8'd1;
                    b3 = (g * 4 + 3 == 5) ? 8'd9 : 8'd1;
                    preload_act(11'd0 + sp * 8 + g, {b3, b2, b1, b0});
                end
            end
        end

        // --- FC weights: neuron n gets weight=1 for all inputs ---
        // But neuron 7 (target winner) gets weight=3 for input channel 5
        // and weight=1 for others.
        // All others get weight=1 for all channels.
        // So neuron 7 output = 31*1 + 1*3*gap[5] = 31 + 3*9 = 31+27 = 58
        //    others = 31*1 + 1*1*gap[5] = 31 + 9 = 40 (or similar)
        // Actually let's make it simpler:
        // All weights = 0 except:
        //   neuron n: weight for input n = 1 (identity)
        //   This way neuron n output = gap[n]
        // Then neuron 5 output = 9, others = 1
        // ArgMax should pick class 5.
        //
        // But wait, FC has 10 neurons from 32 inputs. We need a clear winner.
        // Approach: weight[group][input] word has byte for each neuron in group
        // For each group g, input i: w[g*4+lane] for input i
        // Set: w = 0 everywhere except w[neuron=5, input=5] = 100
        //   neuron 5 is in group 1 (neurons 4-7), lane 1
        //   For group 1, input 5: weight word byte 1 = 100, rest = 0
        for (g = 0; g < 3; g = g + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                begin
                    reg [31:0] wword;
                    wword = 32'd0;
                    if (g == 1 && i == 5)
                        wword = {8'd0, 8'd0, 8'd100, 8'd0}; // lane 1 = 100
                    preload_param(11'd0 + g * 32 + i, wword);
                end
            end
        end

        // FC bias = 0
        for (i = 0; i < 12; i = i + 1) preload_param(11'd400 + i, 32'd0);
        // FC mult = 1
        for (i = 0; i < 12; i = i + 1) preload_param(11'd412 + i, 32'd1);
        // FC zp = 0
        for (i = 0; i < 3; i = i + 1)  preload_param(11'd424 + i, 32'd0);

        cfg_gap_rd_base    = 11'd0;
        cfg_gap_wr_base    = 11'd100;
        cfg_fc_wr_base     = 11'd200;
        cfg_fc_weight_base = 11'd0;
        cfg_fc_bias_base   = 11'd400;
        cfg_fc_mult_base   = 11'd412;
        cfg_fc_zp_base     = 11'd424;
        cfg_fc_shift       = 8'd0;

        tb_mode = 0; tb_param_mode = 0;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait (done == 1'b1);
        repeat (3) @(posedge clk);

        // --- Verify GAP ---
        begin : blk_verify_t4_gap
            integer oc_v, gap_sum, gap_golden;
            reg [7:0] g_byte, hw_byte;
            reg [31:0] hw_word;
            string label;

            for (oc_v = 0; oc_v < 32; oc_v = oc_v + 1) begin
                hw_word = read_act(11'd100 + oc_v);
                hw_byte = hw_word[7:0];

                if (oc_v == 5) begin
                    gap_sum = 9 * 9; // 81
                end else begin
                    gap_sum = 9 * 1; // 9
                end
                gap_golden = (gap_sum * 16'h1C72) >>> 16;
                if (gap_golden > 127) gap_golden = 127;
                if (gap_golden < -128) gap_golden = -128;
                g_byte = gap_golden[7:0];

                $sformat(label, "T4_GAP[oc%0d]", oc_v);
                check8(label, hw_byte, g_byte);
            end
        end

        // --- Verify FC ---
        begin : blk_verify_t4_fc
            integer grp, ln, neuron;
            integer fc_acc, fc_golden;
            integer gap_val, w_val;
            integer inp;
            reg [7:0] g_byte, hw_byte;
            reg [31:0] hw_word;
            string label;

            for (grp = 0; grp < 3; grp = grp + 1) begin
                hw_word = read_act(11'd200 + grp);
                for (ln = 0; ln < 4; ln = ln + 1) begin
                    neuron = grp * 4 + ln;
                    if (neuron < 10) begin
                        hw_byte = hw_word[ln*8 +: 8];

                        // Compute golden FC output for this neuron
                        fc_acc = 0;
                        for (inp = 0; inp < 32; inp = inp + 1) begin
                            // GAP value for input 'inp'
                            if (inp == 5)
                                gap_val = (9 * 9 * 16'h1C72) >>> 16;
                            else
                                gap_val = (9 * 1 * 16'h1C72) >>> 16;
                            if (gap_val > 127) gap_val = 127;
                            if (gap_val < -128) gap_val = -128;
                            // gap_val is signed 8-bit, sign-extend for accumulation
                            gap_val = $signed(gap_val[7:0]);

                            // Weight for this neuron, this input
                            if (grp == 1 && ln == 1 && inp == 5)
                                w_val = 100;
                            else
                                w_val = 0;

                            fc_acc = fc_acc + gap_val * w_val;
                        end

                        // Identity requant + ReLU: clamp to [0, 127]
                        fc_golden = fc_acc;
                        if (fc_golden > 127) fc_golden = 127;
                        if (fc_golden < 0) fc_golden = 0;  // ReLU
                        g_byte = fc_golden[7:0];

                        $sformat(label, "T4_FC[n%0d]", neuron);
                        check8(label, hw_byte, g_byte);
                    end
                end
            end
        end

        // --- Verify ArgMax ---
        begin : blk_verify_t4_argmax
            string label;
            // Neuron 5 should be the winner (only non-zero FC output)
            $sformat(label, "T4_ArgMax");
            check4(label, pred_class_out, 4'd5);
        end

        $display("  Test 4 done: %0d pass, %0d fail (cumulative)", pass_cnt, fail_cnt);
    endtask

    // Timeout
    initial begin
        #50000000;
        $display("TIMEOUT!");
        $finish;
    end

endmodule
