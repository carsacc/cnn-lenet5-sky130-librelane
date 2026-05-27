// tb_top_obi.sv — Comprehensive CNN Top-Level Testbench (OBI interface)
// Phases: A) Host readback  B) Back-to-back  C) Reset mid-inference
//         D) CSR corners    E) Multi-image   F) Freq sweep   G) Summary
// Supports RTL and gate-level simulation (-DPOSTSYNTH for GLS).
//
// Run from rtl/sim/:
//   iverilog -g2012 -o tb_top_obi.out ../modules/tb_top_obi.sv ...
//   vvp tb_top_obi.out +NUM_IMAGES=3
`timescale 1ns/1ps

module tb_top_obi;

    // ================================================================
    // Configuration (plusargs with defaults)
    // ================================================================
    integer cfg_num_images;
    integer cfg_shuffle;
    integer cfg_seed;
    integer cfg_timeout;
    integer cfg_stop_on_fail;
    integer cfg_dump_vcd;
    integer cfg_clk_period_ns;
    integer cfg_freq_sweep;
    integer cfg_freq_min_ns;
    integer cfg_freq_max_ns;
    integer cfg_freq_step_ns;

    // ================================================================
    // Configurable clock generator
    // ================================================================
    real half_period;
    reg clk;
    initial begin
        half_period = 5.0;
        clk = 0;
    end
    always #(half_period) clk = ~clk;

    task automatic set_clock_freq(input real period_ns);
        $display("  Clock: period=%.1f ns (%.1f MHz)", period_ns, 1000.0 / period_ns);
        half_period = period_ns / 2.0;
    endtask

    // ================================================================
    // OBI master signals
    // ================================================================
    reg         obi_req;
    wire        obi_gnt;
    reg  [31:0] obi_addr;
    reg         obi_we;
    reg  [3:0]  obi_be;
    reg  [31:0] obi_wdata;
    wire        obi_rvalid;
    wire [31:0] obi_rdata;

    // ================================================================
    // Reset
    // ================================================================
    reg reset;

    // ================================================================
    // DUT
    // ================================================================
    cnn_top u_dut (
        .clk       (clk),
        .reset     (reset),
        .obi_req   (obi_req),
        .obi_gnt   (obi_gnt),
        .obi_addr  (obi_addr),
        .obi_we    (obi_we),
        .obi_be    (obi_be),
        .obi_wdata (obi_wdata),
        .obi_rvalid(obi_rvalid),
        .obi_rdata (obi_rdata)
    );

    // Silence SRAM debug traces (VERBOSE=0)
`ifdef POSTSYNTH
    defparam u_dut.\u_param.sram .VERBOSE = 0;
    defparam u_dut.\u_buf.sram .VERBOSE = 0;
`else
    defparam u_dut.u_param.sram.VERBOSE = 0;
    defparam u_dut.u_buf.sram.VERBOSE = 0;
`endif

    // ================================================================
    // OBI master tasks
    // ================================================================
    task automatic obi_write(input [31:0] addr, input [31:0] data, input [3:0] be);
        begin
            @(posedge clk); #1;
            obi_req   = 1;
            obi_addr  = addr;
            obi_we    = 1;
            obi_be    = be;
            obi_wdata = data;
            while (!obi_gnt) @(posedge clk);
            @(posedge clk); #1;
            obi_req = 0;
            while (!obi_rvalid) @(posedge clk);
            @(posedge clk); #1;
        end
    endtask

    task automatic obi_read(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk); #1;
            obi_req   = 1;
            obi_addr  = addr;
            obi_we    = 0;
            obi_be    = 4'b1111;
            obi_wdata = 32'd0;
            while (!obi_gnt) @(posedge clk);
            @(posedge clk); #1;
            obi_req = 0;
            while (!obi_rvalid) @(posedge clk);
            data = obi_rdata;
            @(posedge clk); #1;
        end
    endtask

    // ================================================================
    // Backdoor memory access
    // ================================================================
`ifdef POSTSYNTH
    task automatic preload_param(input [10:0] addr, input [31:0] data);
        u_dut.\u_param.sram .mem[addr] = data;
    endtask

    task automatic preload_buf_a(input [10:0] addr, input [31:0] data);
        u_dut.\u_buf.sram .mem[addr[9:0]] = data;
    endtask

    task automatic preload_buf_b(input [10:0] addr, input [31:0] data);
        u_dut.\u_buf.sram .mem[11'd512 + addr[9:0]] = data;
    endtask

    function automatic [31:0] read_param(input [10:0] addr);
        read_param = u_dut.\u_param.sram .mem[addr];
    endfunction

    function automatic [31:0] read_buf_b(input [10:0] addr);
        read_buf_b = u_dut.\u_buf.sram .mem[11'd512 + addr[9:0]];
    endfunction
`else
    task automatic preload_param(input [10:0] addr, input [31:0] data);
        u_dut.u_param.sram.mem[addr] = data;
    endtask

    task automatic preload_buf_a(input [10:0] addr, input [31:0] data);
        u_dut.u_buf.sram.mem[addr[9:0]] = data;
    endtask

    task automatic preload_buf_b(input [10:0] addr, input [31:0] data);
        u_dut.u_buf.sram.mem[11'd512 + addr[9:0]] = data;
    endtask

    function automatic [31:0] read_param(input [10:0] addr);
        read_param = u_dut.u_param.sram.mem[addr];
    endfunction

    function automatic [31:0] read_buf_b(input [10:0] addr);
        read_buf_b = u_dut.u_buf.sram.mem[11'd512 + addr[9:0]];
    endfunction
`endif

    // ================================================================
    // Helper tasks
    // ================================================================
    task automatic clear_all_memories;
        integer i;
        for (i = 0; i < 2048; i = i + 1)
            preload_param(i[10:0], 32'd0);
        for (i = 0; i < 1024; i = i + 1)
            preload_buf_a(i[10:0], 32'd0);  // clears both A-region and B-region
    endtask

    task automatic do_reset;
        begin
            reset = 1;
            obi_req = 0; obi_addr = 0; obi_we = 0; obi_be = 0; obi_wdata = 0;
            repeat (5) @(posedge clk);
            #1; reset = 0;
            @(posedge clk); #1;
        end
    endtask

    task automatic adjust_conv1_biases;
        integer input_zp, oc, k;
        integer weight_word, w_signed, weight_sum;
        integer bias_val, bias_adj;
        begin
            input_zp = read_param(11'h001) & 32'hFF;
            for (oc = 0; oc < 8; oc = oc + 1) begin
                weight_sum = 0;
                for (k = 0; k < 9; k = k + 1) begin
                    if (oc < 4)
                        weight_word = read_param(11'h002 + k[10:0]);
                    else
                        weight_word = read_param(11'h00B + k[10:0]);
                    case (oc % 4)
                        0: w_signed = weight_word[7:0];
                        1: w_signed = (weight_word >> 8) & 32'hFF;
                        2: w_signed = (weight_word >> 16) & 32'hFF;
                        3: w_signed = (weight_word >> 24) & 32'hFF;
                    endcase
                    if (w_signed[7]) w_signed = w_signed | 32'hFFFFFF00;
                    weight_sum = weight_sum + w_signed;
                end
                bias_val = read_param(11'h014 + oc[10:0]);
                bias_adj = bias_val - input_zp * weight_sum;
                preload_param(11'h014 + oc[10:0], bias_adj[31:0]);
            end
        end
    endtask

    // ================================================================
    // Module-level work arrays (Icarus-safe: avoids automatic arrays)
    // ================================================================
    reg [31:0] work_param [0:2047];
    reg [7:0]  work_img   [0:783];
    reg [7:0]  work_logit [0:9];
    reg [7:0]  work_gap   [0:31];
    reg [7:0]  work_label [0:0];
    reg [8*256-1:0] work_path;

    // Load params + image + adjust biases (uses module-level arrays)
    task load_all_data(input integer img_id);
        integer i;
        begin
            // Clear entire unified buffer (1024 words covers A and B regions)
            for (i = 0; i < 1024; i = i + 1)
                preload_buf_a(i[10:0], 32'd0);
            $readmemh("../../datos_hex_std/PARAM_MEM_32x2048.hex", work_param);
            for (i = 0; i < 2048; i = i + 1)
                preload_param(i[10:0], work_param[i]);
            $sformat(work_path, "../../datos_hex_std/test_images/image_%0d.hex", img_id);
            $readmemh(work_path, work_img);
            // Pack 4 pixels per 32-bit word into A-region (196 words)
            for (i = 0; i < 196; i = i + 1)
                preload_buf_a(i[10:0], {work_img[i*4+3], work_img[i*4+2],
                                        work_img[i*4+1], work_img[i*4]});
            adjust_conv1_biases();
        end
    endtask

    // Start inference, poll until done, return HW cycle count and result
    task automatic run_inference_poll(output integer cycles, output reg [3:0] result);
        reg [31:0] status_val, result_val;
        integer poll_cnt;
        realtime t_start, t_end;
        begin
            obi_write(32'h6000, 32'h0000_0001, 4'b1111);
            t_start = $realtime;
            poll_cnt = 0;
            status_val = 0;
            while (!(status_val & 32'h1) && poll_cnt < cfg_timeout) begin
                obi_read(32'h6004, status_val);
                poll_cnt = poll_cnt + 1;
            end
            t_end = $realtime;
            // Convert simulation time delta to clock cycles
            cycles = (t_end - t_start) / (half_period * 2.0);
            if (poll_cnt >= cfg_timeout) begin
                $display("  TIMEOUT after %0d polls!", poll_cnt);
                result = 4'hF;
            end else begin
                obi_read(32'h6008, result_val);
                result = result_val[3:0];
            end
            obi_write(32'h6000, 32'h0000_0000, 4'b1111);
        end
    endtask

    // Load expected label from file
    task load_label(input integer img_id, output reg [3:0] label);
        begin
            $sformat(work_path, "../../datos_hex_std/test_images/image_%0d_label.txt", img_id);
            $readmemh(work_path, work_label);
            label = work_label[0][3:0];
        end
    endtask

    // ================================================================
    // Test counters
    // ================================================================
    integer total_pass, total_fail;
    integer phase_pass, phase_fail;
    integer pa_pass, pa_fail;
    integer pb_pass, pb_fail;
    integer pc_pass, pc_fail;
    integer pd_pass, pd_fail;
    integer pe_pass, pe_fail, pe_correct, pe_tested;
    integer pf_pass, pf_fail;
    real    pf_max_fmax_mhz;

    // ================================================================
    // Main test sequence
    // ================================================================
    initial begin
        // ============================================================
        // Parse plusargs
        // ============================================================
        if (!$value$plusargs("NUM_IMAGES=%d", cfg_num_images))     cfg_num_images   = 10;
        if (!$value$plusargs("SHUFFLE=%d", cfg_shuffle))           cfg_shuffle      = 1;
        if (!$value$plusargs("SEED=%d", cfg_seed))                 cfg_seed         = $random;
        if (!$value$plusargs("TIMEOUT=%d", cfg_timeout))           cfg_timeout      = 2000000;
        if (!$value$plusargs("STOP_ON_FAIL=%d", cfg_stop_on_fail)) cfg_stop_on_fail = 0;
        if (!$value$plusargs("DUMP_VCD=%d", cfg_dump_vcd))         cfg_dump_vcd     = 0;
        if (!$value$plusargs("CLK_PERIOD_NS=%d", cfg_clk_period_ns)) cfg_clk_period_ns = 10;
        if (!$value$plusargs("FREQ_SWEEP=%d", cfg_freq_sweep))     cfg_freq_sweep   = 0;
        if (!$value$plusargs("FREQ_MIN_NS=%d", cfg_freq_min_ns))   cfg_freq_min_ns  = 4;
        if (!$value$plusargs("FREQ_MAX_NS=%d", cfg_freq_max_ns))   cfg_freq_max_ns  = 20;
        if (!$value$plusargs("FREQ_STEP_NS=%d", cfg_freq_step_ns)) cfg_freq_step_ns = 2;

        if (cfg_num_images < 1)  cfg_num_images = 1;
        if (cfg_num_images > 20) cfg_num_images = 20;

        $display("================================================================");
        $display("tb_top_obi — Comprehensive CNN Testbench (OBI)");
        $display("================================================================");
        $display("  NUM_IMAGES   = %0d", cfg_num_images);
        $display("  SHUFFLE      = %0d (seed=%0d)", cfg_shuffle, cfg_seed);
        $display("  TIMEOUT      = %0d polls", cfg_timeout);
        $display("  STOP_ON_FAIL = %0d", cfg_stop_on_fail);
        $display("  CLK_PERIOD   = %0d ns (%.1f MHz)",
                 cfg_clk_period_ns, 1000.0 / cfg_clk_period_ns);
        if (cfg_freq_sweep)
            $display("  FREQ_SWEEP   = ON (%0d -> %0d ns, step %0d)",
                     cfg_freq_max_ns, cfg_freq_min_ns, cfg_freq_step_ns);
        else
            $display("  FREQ_SWEEP   = OFF");
        $display("");

        if (cfg_dump_vcd) begin
            $dumpfile("tb_top_obi.vcd");
            $dumpvars(0, tb_top_obi);
        end

        set_clock_freq(cfg_clk_period_ns * 1.0);

        total_pass = 0;
        total_fail = 0;
        pf_max_fmax_mhz = 0.0;

        // ============================================================
        // PHASE A: Host Data Readback Test (image_0)
        // ============================================================
        begin : phase_a
            reg [31:0] rd_data;
            reg [3:0]  result;
            integer    cycles, i;
            integer    logit_pass, gap_pass, conv3_nz;
            reg [7:0]  got_byte, exp_byte;

            $display("========================================");
            $display("PHASE A: Host Data Readback (image_0)");
            $display("========================================");
            phase_pass = 0;
            phase_fail = 0;

            // Run inference on image_0
            load_all_data(0);
            do_reset();
            run_inference_poll(cycles, result);

            if (result == 4'd7) begin
                $display("  PASS: Inference result=%0d (expected 7), %0d cycles", result, cycles);
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: Inference result=%0d, expected 7", result);
                phase_fail = phase_fail + 1;
            end

            // --- Read FC logits via OBI (3 words at buf_B addrs 104-106) ---
            // OBI addr = 0x4000 + word_addr * 4
            // Logit packing: word N has {class[N*4+3], class[N*4+2], class[N*4+1], class[N*4+0]}
            // Tolerance ±2 LSB: HW rounding (truncation) vs Python (round-half-to-even)
            $readmemh("../../datos_hex_std/logits_image_0.hex", work_logit);
            logit_pass = 0;
            for (i = 0; i < 3; i = i + 1) begin : blk_fc_rd
                reg [31:0] fc_word;
                integer b, diff;
                obi_read(32'h4000 + (104 + i) * 4, fc_word);
                for (b = 0; b < 4; b = b + 1) begin
                    if (i * 4 + b < 10) begin
                        got_byte = fc_word[b*8 +: 8];
                        exp_byte = work_logit[i*4 + b];
                        diff = $signed({1'b0, got_byte}) - $signed({1'b0, exp_byte});
                        if (diff < 0) diff = -diff;
                        if (diff <= 2) begin
                            logit_pass = logit_pass + 1;
                        end else begin
                            $display("  FAIL: FC logit[%0d] = 0x%02X, expected 0x%02X (diff=%0d)",
                                     i*4+b, got_byte, exp_byte, diff);
                            phase_fail = phase_fail + 1;
                        end
                    end
                end
            end
            $display("  FC logits: %0d/10 within tolerance (+-2)", logit_pass);
            phase_pass = phase_pass + logit_pass;

            // --- Read GAP values via OBI (32 words at buf_B addrs 72-103) ---
            // GAP value in byte 0 of each word ({24'd0, gap_value})
            // Tolerance ±2 LSB for same rounding reasons
            $readmemh("../../datos_hex_std/golden/gap_image_0.hex", work_gap);
            gap_pass = 0;
            for (i = 0; i < 32; i = i + 1) begin : blk_gap_rd
                integer diff;
                obi_read(32'h4000 + (72 + i) * 4, rd_data);
                got_byte = rd_data[7:0];
                exp_byte = work_gap[i];
                diff = $signed({1'b0, got_byte}) - $signed({1'b0, exp_byte});
                if (diff < 0) diff = -diff;
                if (diff <= 2) begin
                    gap_pass = gap_pass + 1;
                end else begin
                    $display("  FAIL: GAP[%0d] = 0x%02X, expected 0x%02X (diff=%0d)",
                             i, got_byte, exp_byte, diff);
                    phase_fail = phase_fail + 1;
                end
            end
            $display("  GAP values: %0d/32 within tolerance (+-2)", gap_pass);
            phase_pass = phase_pass + gap_pass;

            // --- Dump Conv3 por canal en formato golden (32 ficheros, 9 lineas) ---
            // Layout buf_B[0..71]: 9 posiciones espaciales row-major, 8 palabras por
            // posicion (4 OC empaquetados por palabra). Genera ficheros compatibles
            // con datos_hex_std/golden/conv3_relu_image_0_oc{0..31}.hex.
            begin : blk_conv3_dump
                integer fd_arr [0:31];
                integer oc, sp, oc_group, byte_idx;
                reg [31:0] w;
                reg [8*64-1:0] fname;
                conv3_nz = 0;
                for (oc = 0; oc < 32; oc = oc + 1) begin
                    $sformat(fname, "rtl_conv3_relu_image_0_oc%0d.hex", oc);
                    fd_arr[oc] = $fopen(fname, "w");
                end
                for (sp = 0; sp < 9; sp = sp + 1) begin
                    for (oc_group = 0; oc_group < 8; oc_group = oc_group + 1) begin
                        obi_read(32'h4000 + (sp * 8 + oc_group) * 4, w);
                        if (w != 32'd0) conv3_nz = conv3_nz + 1;
                        for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1) begin
                            oc = oc_group * 4 + byte_idx;
                            $fwrite(fd_arr[oc], "%02x\n", w[byte_idx*8 +: 8]);
                        end
                    end
                end
                for (oc = 0; oc < 32; oc = oc + 1) $fclose(fd_arr[oc]);
                if (conv3_nz > 0) begin
                    $display("  PASS: Conv3 dump: %0d/72 non-zero words -> rtl_conv3_relu_image_0_oc{0..31}.hex",
                             conv3_nz);
                    phase_pass = phase_pass + 1;
                end else begin
                    $display("  FAIL: Conv3 dump: all 72 words zero");
                    phase_fail = phase_fail + 1;
                end
            end

            pa_pass = phase_pass;
            pa_fail = phase_fail;
            total_pass = total_pass + phase_pass;
            total_fail = total_fail + phase_fail;
            $display("Phase A: %0d PASS, %0d FAIL\n", pa_pass, pa_fail);
            if (cfg_stop_on_fail && pa_fail > 0) begin
                $display("STOP_ON_FAIL: aborting"); $finish;
            end
        end

        // ============================================================
        // PHASE B: Back-to-Back Inference Stress Test
        // ============================================================
        begin : phase_b
            integer bb_imgs [0:2];
            integer bb_labels [0:2];
            reg [3:0] result, exp_label;
            integer cycles, i;

            $display("========================================");
            $display("PHASE B: Back-to-Back Inference (3 images, no reset)");
            $display("========================================");
            phase_pass = 0;
            phase_fail = 0;

            bb_imgs[0] = 0; bb_labels[0] = 7;
            bb_imgs[1] = 1; bb_labels[1] = 2;
            bb_imgs[2] = 2; bb_labels[2] = 1;

            for (i = 0; i < 3; i = i + 1) begin
                load_all_data(bb_imgs[i]);
                if (i == 0) do_reset();
                // No reset for subsequent iterations — tests state cleanup
                run_inference_poll(cycles, result);
                exp_label = bb_labels[i][3:0];
                if (result == exp_label) begin
                    $display("  PASS: image_%0d result=%0d (expected %0d), %0d cycles",
                             bb_imgs[i], result, exp_label, cycles);
                    phase_pass = phase_pass + 1;
                end else begin
                    $display("  FAIL: image_%0d result=%0d, expected %0d",
                             bb_imgs[i], result, exp_label);
                    phase_fail = phase_fail + 1;
                end
            end

            pb_pass = phase_pass;
            pb_fail = phase_fail;
            total_pass = total_pass + phase_pass;
            total_fail = total_fail + phase_fail;
            $display("Phase B: %0d PASS, %0d FAIL\n", pb_pass, pb_fail);
            if (cfg_stop_on_fail && pb_fail > 0) begin
                $display("STOP_ON_FAIL: aborting"); $finish;
            end
        end

        // ============================================================
        // PHASE C: Reset Mid-Inference Test
        // ============================================================
        begin : phase_c
            reg [31:0] rd_data;
            reg [3:0]  result;
            integer cycles;

            $display("========================================");
            $display("PHASE C: Reset Mid-Inference Recovery");
            $display("========================================");
            phase_pass = 0;
            phase_fail = 0;

            // Load and start inference
            load_all_data(0);
            do_reset();
            obi_write(32'h6000, 32'h0000_0001, 4'b1111);

            // Let inference run ~1000 cycles, then assert reset
            repeat (1000) @(posedge clk);
            $display("  Asserting reset mid-inference...");
            reset = 1;
            repeat (5) @(posedge clk);
            #1; reset = 0;
            @(posedge clk); #1;

            // Verify CSR defaults after reset
            obi_read(32'h6004, rd_data); // STATUS
            if (rd_data == 32'd0) begin
                $display("  PASS: STATUS=0 after mid-inference reset");
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: STATUS=0x%08X after reset, expected 0", rd_data);
                phase_fail = phase_fail + 1;
            end

            obi_read(32'h6008, rd_data); // RESULT
            if (rd_data == 32'd0) begin
                $display("  PASS: RESULT=0 after mid-inference reset");
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: RESULT=0x%08X after reset, expected 0", rd_data);
                phase_fail = phase_fail + 1;
            end

            // Reload, re-reset, run fresh inference
            load_all_data(0);
            do_reset();
            run_inference_poll(cycles, result);
            if (result == 4'd7) begin
                $display("  PASS: Recovery inference result=%0d (expected 7), %0d cycles",
                         result, cycles);
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: Recovery inference result=%0d, expected 7", result);
                phase_fail = phase_fail + 1;
            end

            pc_pass = phase_pass;
            pc_fail = phase_fail;
            total_pass = total_pass + phase_pass;
            total_fail = total_fail + phase_fail;
            $display("Phase C: %0d PASS, %0d FAIL\n", pc_pass, pc_fail);
            if (cfg_stop_on_fail && pc_fail > 0) begin
                $display("STOP_ON_FAIL: aborting"); $finish;
            end
        end

        // ============================================================
        // PHASE D: CSR Corner Cases
        // ============================================================
        begin : phase_d
            reg [31:0] rd_data;
            reg [31:0] param_snap [0:5];
            integer i;

            $display("========================================");
            $display("PHASE D: CSR Corner Cases");
            $display("========================================");
            phase_pass = 0;
            phase_fail = 0;

            do_reset();

            // D1: Write to read-only STATUS register
            obi_read(32'h6004, rd_data); // Read current STATUS
            obi_write(32'h6004, 32'hFFFF_FFFF, 4'b1111); // Write to RO reg
            obi_read(32'h6004, rd_data);
            if (rd_data == 32'd0) begin
                $display("  PASS: STATUS unchanged after write (0x%08X)", rd_data);
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: STATUS=0x%08X after write to RO reg, expected 0", rd_data);
                phase_fail = phase_fail + 1;
            end

            // D2: Write to read-only RESULT register
            obi_write(32'h6008, 32'hFFFF_FFFF, 4'b1111);
            obi_read(32'h6008, rd_data);
            if (rd_data == 32'd0) begin
                $display("  PASS: RESULT unchanged after write (0x%08X)", rd_data);
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: RESULT=0x%08X after write to RO reg, expected 0", rd_data);
                phase_fail = phase_fail + 1;
            end

            // D3: Read undefined/reserved CSR address 0x600C
            obi_read(32'h600C, rd_data);
            if (rd_data == 32'd0) begin
                $display("  PASS: Reserved CSR 0x600C = 0 (0x%08X)", rd_data);
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: Reserved CSR 0x600C = 0x%08X, expected 0", rd_data);
                phase_fail = phase_fail + 1;
            end

            // D4: Back-to-back CSR reads (CTRL, STATUS, RESULT in rapid succession)
            begin : blk_d4
                reg [31:0] rd_ctrl, rd_status, rd_result;
                obi_read(32'h6000, rd_ctrl);
                obi_read(32'h6004, rd_status);
                obi_read(32'h6008, rd_result);
                // All should be valid (0 after reset)
                if (rd_ctrl == 32'd0 && rd_status == 32'd0 && rd_result == 32'd0) begin
                    $display("  PASS: Back-to-back CSR reads all valid");
                    phase_pass = phase_pass + 1;
                end else begin
                    $display("  FAIL: B2B CSR reads: CTRL=0x%08X STATUS=0x%08X RESULT=0x%08X",
                             rd_ctrl, rd_status, rd_result);
                    phase_fail = phase_fail + 1;
                end
            end

            // D5: CTRL write with byte-enable=0001 (only byte 0)
            obi_write(32'h6000, 32'h0000_0001, 4'b0001);
            obi_read(32'h6000, rd_data);
            if (rd_data[0] == 1'b1) begin
                $display("  PASS: CTRL byte-enable write works (0x%08X)", rd_data);
                phase_pass = phase_pass + 1;
            end else begin
                $display("  FAIL: CTRL=0x%08X after be=0001 write, expected bit 0 set", rd_data);
                phase_fail = phase_fail + 1;
            end
            // Clear CTRL
            obi_write(32'h6000, 32'h0000_0000, 4'b1111);

            // D6: Param memory integrity after inference
            // Snapshot first 6 param words, run inference, verify unchanged
            load_all_data(0);
            for (i = 0; i < 6; i = i + 1)
                param_snap[i] = read_param(i[10:0]);
            do_reset();
            begin : blk_d6_run
                reg [3:0] res;
                integer cyc;
                run_inference_poll(cyc, res);
            end
            begin : blk_d6_check
                integer ok;
                ok = 1;
                for (i = 0; i < 6; i = i + 1) begin
                    if (read_param(i[10:0]) !== param_snap[i]) begin
                        $display("  FAIL: param[%0d] changed: 0x%08X -> 0x%08X",
                                 i, param_snap[i], read_param(i[10:0]));
                        ok = 0;
                    end
                end
                if (ok) begin
                    $display("  PASS: Param memory intact after inference (6 words checked)");
                    phase_pass = phase_pass + 1;
                end else begin
                    phase_fail = phase_fail + 1;
                end
            end

            pd_pass = phase_pass;
            pd_fail = phase_fail;
            total_pass = total_pass + phase_pass;
            total_fail = total_fail + phase_fail;
            $display("Phase D: %0d PASS, %0d FAIL\n", pd_pass, pd_fail);
            if (cfg_stop_on_fail && pd_fail > 0) begin
                $display("STOP_ON_FAIL: aborting"); $finish;
            end
        end

        // ============================================================
        // PHASE E: Multi-Image Inference Loop
        // ============================================================
        begin : phase_e
            integer image_order [0:19];
            integer i, j, tmp;
            reg [3:0] result, exp_label;
            integer cycles;
            integer cycle_total, cycle_min, cycle_max;

            $display("========================================");
            $display("PHASE E: Multi-Image Inference (N=%0d)", cfg_num_images);
            $display("========================================");
            phase_pass = 0;
            phase_fail = 0;
            pe_correct = 0;
            pe_tested  = 0;
            cycle_total = 0;
            cycle_min = cfg_timeout;
            cycle_max = 0;

            // Build image order array
            for (i = 0; i < 20; i = i + 1)
                image_order[i] = i;

            // Fisher-Yates shuffle (if enabled)
            if (cfg_shuffle) begin
                // Seed the RNG
                tmp = $random(cfg_seed);
                for (i = cfg_num_images - 1; i > 0; i = i - 1) begin
                    j = $unsigned($random) % (i + 1);
                    tmp = image_order[i];
                    image_order[i] = image_order[j];
                    image_order[j] = tmp;
                end
                $display("  Shuffled order (first 10): %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                         image_order[0], image_order[1], image_order[2], image_order[3],
                         image_order[4], image_order[5], image_order[6], image_order[7],
                         image_order[8], image_order[9]);
            end

            for (i = 0; i < cfg_num_images; i = i + 1) begin
                load_all_data(image_order[i]);
                do_reset();
                run_inference_poll(cycles, result);
                load_label(image_order[i], exp_label);
                pe_tested = pe_tested + 1;

                if (cycles < cfg_timeout) begin
                    cycle_total = cycle_total + cycles;
                    if (cycles < cycle_min) cycle_min = cycles;
                    if (cycles > cycle_max) cycle_max = cycles;
                end

                if (result == exp_label) begin
                    $display("  PASS: image_%0d -> %0d (expected %0d) [%0d cycles]",
                             image_order[i], result, exp_label, cycles);
                    phase_pass = phase_pass + 1;
                    pe_correct = pe_correct + 1;
                end else begin
                    $display("  FAIL: image_%0d -> %0d (expected %0d) [%0d cycles]",
                             image_order[i], result, exp_label, cycles);
                    phase_fail = phase_fail + 1;
                    if (cfg_stop_on_fail) begin
                        $display("STOP_ON_FAIL: aborting"); $finish;
                    end
                end
            end

            $display("  Accuracy: %0d/%0d (%.1f%%)",
                     pe_correct, pe_tested,
                     pe_tested > 0 ? (100.0 * pe_correct) / pe_tested : 0.0);
            if (pe_tested > 0)
                $display("  Cycle stats: min=%0d avg=%0d max=%0d cycles",
                         cycle_min, cycle_total / pe_tested, cycle_max);

            pe_pass = phase_pass;
            pe_fail = phase_fail;
            total_pass = total_pass + phase_pass;
            total_fail = total_fail + phase_fail;
            $display("Phase E: %0d PASS, %0d FAIL\n", pe_pass, pe_fail);
        end

        // ============================================================
        // PHASE F: Frequency Sweep (optional)
        // ============================================================
        begin : phase_f
            integer period_ns;
            reg [3:0] result;
            integer cycles;
            integer last_pass_period;
            integer first_fail_period;

            pf_pass = 0;
            pf_fail = 0;
            last_pass_period = 0;
            first_fail_period = 0;

            if (cfg_freq_sweep) begin
                $display("========================================");
                $display("PHASE F: Frequency Sweep (%0d -> %0d ns, step %0d)",
                         cfg_freq_max_ns, cfg_freq_min_ns, cfg_freq_step_ns);
                $display("========================================");

                period_ns = cfg_freq_max_ns;
                while (period_ns >= cfg_freq_min_ns) begin
                    set_clock_freq(period_ns * 1.0);

                    load_all_data(0);
                    do_reset();
                    run_inference_poll(cycles, result);

                    if (result == 4'd7 && cycles < cfg_timeout) begin
                        $display("  %0d.0 ns (%.1f MHz): PASS (%0d cycles)",
                                 period_ns, 1000.0 / period_ns, cycles);
                        pf_pass = pf_pass + 1;
                        last_pass_period = period_ns;
                    end else begin
                        $display("  %0d.0 ns (%.1f MHz): FAIL (result=%0d, %0d polls)",
                                 period_ns, 1000.0 / period_ns, result, cycles);
                        pf_fail = pf_fail + 1;
                        if (first_fail_period == 0)
                            first_fail_period = period_ns;
                    end
                    period_ns = period_ns - cfg_freq_step_ns;
                end

                if (last_pass_period > 0)
                    pf_max_fmax_mhz = 1000.0 / last_pass_period;
                else
                    pf_max_fmax_mhz = 0.0;

                if (first_fail_period > 0)
                    $display("  Max passing: %0d ns (%.1f MHz), first fail: %0d ns",
                             last_pass_period, pf_max_fmax_mhz, first_fail_period);
                else
                    $display("  All frequencies passed (max tested: %0d ns = %.1f MHz)",
                             cfg_freq_min_ns, 1000.0 / cfg_freq_min_ns);

                // Restore nominal clock
                set_clock_freq(cfg_clk_period_ns * 1.0);

                // Freq sweep is informational — does not affect overall verdict
                $display("Phase F: %0d PASS, %0d FAIL (informational)\n", pf_pass, pf_fail);
            end else begin
                $display("PHASE F: Frequency Sweep SKIPPED (+FREQ_SWEEP=0)\n");
            end
        end

        // ============================================================
        // PHASE G: Summary
        // ============================================================
        $display("================================================================");
        $display("COMPREHENSIVE TEST SUMMARY");
        $display("================================================================");
        $display("");
        $display("Phase A — Host Readback:        %0s (%0d/%0d checks)",
                 pa_fail == 0 ? "PASS" : "FAIL", pa_pass, pa_pass + pa_fail);
        $display("Phase B — Back-to-Back:         %0s (%0d/%0d inferences)",
                 pb_fail == 0 ? "PASS" : "FAIL", pb_pass, pb_pass + pb_fail);
        $display("Phase C — Reset Mid-Inference:  %0s (%0d/%0d checks)",
                 pc_fail == 0 ? "PASS" : "FAIL", pc_pass, pc_pass + pc_fail);
        $display("Phase D — CSR Corner Cases:     %0s (%0d/%0d checks)",
                 pd_fail == 0 ? "PASS" : "FAIL", pd_pass, pd_pass + pd_fail);
        $display("Phase E — Multi-Image (N=%0d):  %0s %0d/%0d (%.1f%% accuracy)",
                 pe_tested, pe_fail == 0 ? "PASS" : "FAIL",
                 pe_correct, pe_tested,
                 pe_tested > 0 ? (100.0 * pe_correct) / pe_tested : 0.0);
        if (cfg_freq_sweep)
            $display("Phase F — Freq Sweep:           %0s (Max Fmax = %.1f MHz)",
                     pf_fail == 0 ? "PASS" : "FAIL", pf_max_fmax_mhz);
        else
            $display("Phase F — Freq Sweep:           SKIPPED");
        $display("");
        $display("FINAL: %0d PASS, %0d FAIL out of %0d total checks",
                 total_pass, total_fail, total_pass + total_fail);
        $display("");
        if (total_fail == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("================================================================");

        $finish;
    end

endmodule
