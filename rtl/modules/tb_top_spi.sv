// tb_top_spi.sv — CNN Top-Level Testbench (SPI interface)
// ALL data loading, control, and readback is done through SPI.
//
// Run: bash rtl/sim/sim_cnn_top_spi.sh [NUM_IMAGES]
`timescale 1ns/1ps

module tb_top_spi;

    // ================================================================
    // Configuration
    // ================================================================
    integer cfg_num_images;
    integer cfg_timeout;
    integer cfg_dump_vcd;

    // ================================================================
    // SPI timing parameters
    // ================================================================
    parameter SPI_HALF = 500;      // ns → 1 MHz SPI clock
    parameter CS_GAP   = 2000;     // ns  inter-transaction gap

    // ================================================================
    // Clock: 15 MHz  (66.67 ns period)
    // ================================================================
    reg clk;
    initial clk = 0;
    always #33.33 clk = ~clk;

    // ================================================================
    // SPI master signals
    // ================================================================
    reg         spi_sclk;
    reg         spi_cs_n;
    reg         spi_mosi;
    wire        spi_miso;

    // ================================================================
    // SPI clock generator (free-running gated). Mas robusto en VCD/SDF
    // que toggling con #delay dentro de un task automatic. El sclk se
    // genera siempre en un always block; las tareas solo manipulan
    // sclk_enable para arrancar/parar el reloj.
    // ================================================================
    reg sclk_enable;
    initial begin
        spi_sclk    = 1'b0;
        sclk_enable = 1'b0;
    end
    always begin
        #(SPI_HALF);
        if (sclk_enable) spi_sclk = ~spi_sclk;
        else             spi_sclk = 1'b0;
    end

    // ================================================================
    // Reset
    // ================================================================
    reg reset;

    // ================================================================
    // DUT  (cnn_top compiled with -DUSE_SPI_INTERFACE)
    // ================================================================
`ifdef USE_POWER_PINS
    supply1 vccd1;
    supply0 vssd1;
`endif

    cnn_top u_dut (
        .clk       (clk),
        .reset     (reset),
        .spi_sclk  (spi_sclk),
        .spi_cs_n  (spi_cs_n),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso)
`ifdef USE_POWER_PINS
        , .vccd1 (vccd1)
        , .vssd1 (vssd1)
`endif
    );

    // Silence SRAM debug traces. En post-PnR la jerarquia esta aplastada
    // y los nombres usan identificadores escapados.
`ifdef POSTSYNTH
    defparam u_dut.\u_param.sram .VERBOSE = 0;
    defparam u_dut.\u_buf.sram .VERBOSE   = 0;
`else
    defparam u_dut.u_param.sram.VERBOSE = 0;
    defparam u_dut.u_buf.sram.VERBOSE   = 0;
`endif

    // ================================================================
    // SPI master helper tasks
    // ================================================================

    // Low-level: clock one 56-bit SPI transaction.
    // Pone el primer bit de mosi y arranca sclk_enable; cada
    // @(posedge spi_sclk) captura miso, cada @(negedge spi_sclk)
    // avanza al siguiente bit. Mode 0: mosi cambia en negedge,
    // se muestrea en posedge. El sclk lo genera el always block
    // de arriba (no se toca aqui directamente).
    task spi_transact(input [55:0] frame, output [31:0] miso_data);
        integer i;
        reg [31:0] cap;
        begin
            cap = 32'd0;
            spi_cs_n  = 0;
            spi_mosi  = frame[55];
            #(SPI_HALF);
            sclk_enable = 1'b1;
            for (i = 55; i >= 0; i = i - 1) begin
                @(posedge spi_sclk);
                #1;
                if (i < 32) cap[i] = spi_miso;
                @(negedge spi_sclk);
                if (i > 0) spi_mosi = frame[i-1];
            end
            sclk_enable = 1'b0;
            #(SPI_HALF);
            spi_cs_n = 1;
            #(CS_GAP);
            miso_data = cap;
        end
    endtask

    // SPI write (full word at byte address)
    task spi_write(input [15:0] addr, input [31:0] data);
        reg [55:0] frame;
        reg [31:0] dummy;
        begin
            frame = {8'h80, addr, data};
            spi_transact(frame, dummy);
        end
    endtask

    // SPI raw read — returns PREVIOUS read's data (pipeline)
    task spi_read_raw(input [15:0] addr, output [31:0] miso_data);
        reg [55:0] frame;
        begin
            frame = {8'h00, addr, 32'd0};
            spi_transact(frame, miso_data);
        end
    endtask

    // SPI pipeline read — 2 transactions: trigger fetch + capture result
    task spi_read_data(input [15:0] addr, output [31:0] data);
        reg [31:0] dummy;
        begin
            spi_read_raw(addr,    dummy);
            spi_read_raw(16'h600C, data);
        end
    endtask

    // ================================================================
    // Module-level work arrays  (Icarus-safe: no automatic arrays)
    // ================================================================
    reg [31:0] work_param  [0:2047];
    reg [7:0]  work_img    [0:783];
    reg [7:0]  work_label  [0:0];
    reg [8*256-1:0] work_path;

    // ================================================================
    // Reset task
    // ================================================================
    task do_reset;
        begin
            reset = 1;
            spi_sclk = 0; spi_cs_n = 1; spi_mosi = 0;
            repeat (6) @(posedge clk);
            #1; reset = 0;
            repeat (4) @(posedge clk); #1;
        end
    endtask

    // ================================================================
    // Load all params via SPI  (2048 words → param_memory)
    // ================================================================
    task load_params_spi;
        integer i;
        begin
            $display("  Loading params via SPI (2048 words)...");
            $readmemh("../../datos_hex_std/PARAM_MEM_32x2048.hex", work_param);
            for (i = 0; i < 2048; i = i + 1)
                spi_write(i[15:0] * 16'd4, work_param[i]);   // byte addr in param region
            $display("  Params loaded.");
        end
    endtask

    // ================================================================
    // Clear unified buffer via SPI  (1024 words: buf_A 0-511 + buf_B 512-1023)
    // ================================================================
    task clear_buffer_spi;
        integer i;
        begin
            $display("  Clearing buffer via SPI (1024 words)...");
            // buf_A region: byte addr 0x2000 + word*4
            for (i = 0; i < 512; i = i + 1)
                spi_write(16'h2000 + i[15:0] * 16'd4, 32'd0);
            // buf_B region: byte addr 0x4000 + word*4
            for (i = 0; i < 512; i = i + 1)
                spi_write(16'h4000 + i[15:0] * 16'd4, 32'd0);
            $display("  Buffer cleared.");
        end
    endtask
    // ================================================================
    // Load image via SPI  (packed 4 px/word → buf_A, 196 words)
    // ================================================================
    task load_image_spi(input integer img_id);
        integer i;
        reg [31:0] pword;
        begin
            $sformat(work_path, "../../datos_hex_std/test_images/image_%0d.hex", img_id);
            $readmemh(work_path, work_img);
            $display("  Loading image_%0d via SPI (196 words)...", img_id);
            for (i = 0; i < 196; i = i + 1) begin
                pword = {work_img[i*4+3], work_img[i*4+2],
                          work_img[i*4+1], work_img[i*4]};
                spi_write(16'h2000 + i[15:0] * 16'd4, pword);
            end
            $display("  Image loaded.");
        end
    endtask

    // ================================================================
    // Adjust Conv1 biases via SPI  (read-modify-write)
    // bias_adj = bias - input_zp * sum(kernel_weights)
    // ================================================================
    task adjust_conv1_biases_spi;
        integer input_zp, oc, k;
        integer weight_sum, w_signed;
        integer bias_val, bias_adj;
        reg [31:0] rd_word;
        reg [15:0] w_addr;
        begin
            $display("  Adjusting Conv1 biases via SPI...");
            // Read input_zp from param word 0x001 (byte addr 0x0004)
            spi_read_data(16'h0004, rd_word);
            input_zp = rd_word & 32'hFF;

            for (oc = 0; oc < 8; oc = oc + 1) begin
                weight_sum = 0;
                for (k = 0; k < 9; k = k + 1) begin
                    // OC 0-3: weights at words 0x002+k ; OC 4-7: words 0x00B+k
                    if (oc < 4)
                        w_addr = (16'h002 + k[15:0]) * 16'd4;
                    else
                        w_addr = (16'h00B + k[15:0]) * 16'd4;

                    spi_read_data(w_addr, rd_word);

                    case (oc % 4)
                        0: w_signed = rd_word[7:0];
                        1: w_signed = (rd_word >> 8) & 32'hFF;
                        2: w_signed = (rd_word >> 16) & 32'hFF;
                        3: w_signed = (rd_word >> 24) & 32'hFF;
                    endcase
                    // Sign extend
                    if (w_signed[7]) w_signed = w_signed | 32'hFFFFFF00;
                    weight_sum = weight_sum + w_signed;
                end

                // Read original bias
                spi_read_data((16'h014 + oc[15:0]) * 16'd4, rd_word);
                bias_val = rd_word;

                // Compute adjusted bias and write back
                bias_adj = bias_val - input_zp * weight_sum;
                spi_write((16'h014 + oc[15:0]) * 16'd4, bias_adj[31:0]);
            end
            $display("  Biases adjusted.");
        end
    endtask

    // ================================================================
    // Full data load: params + clear buffer + image + bias adjust
    // ================================================================
    task load_all_data_spi(input integer img_id);
        begin
            load_params_spi();
            clear_buffer_spi();
            load_image_spi(img_id);
            adjust_conv1_biases_spi();
        end
    endtask

    // ================================================================
    // Start inference via SPI, poll STATUS, read RESULT
    // ================================================================
    task automatic run_inference_spi(output integer cycles,
                                     output reg [3:0] result);
        reg [31:0] status_val, result_val;
        integer poll_cnt;
        realtime t_start, t_end;
        begin
            // Write CTRL.start = 1
            spi_write(16'h6000, 32'h0000_0001);
            t_start = $realtime;
            poll_cnt = 0;
            status_val = 0;

            // Poll STATUS (pipeline read) until done bit set
            // First read primes the pipeline
            spi_read_raw(16'h6004, status_val);  // trigger fetch → stale
            while (!(status_val & 32'h1) && poll_cnt < cfg_timeout) begin
                spi_read_raw(16'h6004, status_val); // returns PREVIOUS fetch
                poll_cnt = poll_cnt + 1;
            end

            t_end = $realtime;
            cycles = ($rtoi(t_end - t_start)) / 67;  // approx core cycles

            if (poll_cnt >= cfg_timeout) begin
                $display("  TIMEOUT after %0d polls!", poll_cnt);
                result = 4'hF;
            end else begin
                // Read RESULT
                spi_read_data(16'h6008, result_val);
                result = result_val[3:0];
            end

            // Clear start
            spi_write(16'h6000, 32'h0000_0000);
        end
    endtask

    // ================================================================
    // Load expected label
    // ================================================================
    task load_label(input integer img_id, output reg [3:0] label);
        begin
            $sformat(work_path,
                     "../../datos_hex_std/test_images/image_%0d_label.txt", img_id);
            $readmemh(work_path, work_label);
            label = work_label[0][3:0];
        end
    endtask

    // ================================================================
    // Test counters
    // ================================================================
    integer total_pass, total_fail;
    integer total_correct, total_tested;

    // ================================================================
    // Main test sequence
    // ================================================================
    initial begin
        // Parse plusargs
        if (!$value$plusargs("NUM_IMAGES=%d", cfg_num_images))  cfg_num_images = 3;
        if (!$value$plusargs("TIMEOUT=%d", cfg_timeout))        cfg_timeout    = 5000000;
        if (!$value$plusargs("DUMP_VCD=%d", cfg_dump_vcd))      cfg_dump_vcd   = 0;

        if (cfg_num_images < 1)  cfg_num_images = 1;
        if (cfg_num_images > 20) cfg_num_images = 20;

        $display("================================================================");
        $display("tb_top_spi — CNN Top-Level Test (SPI)");
        $display("================================================================");
        $display("  NUM_IMAGES = %0d", cfg_num_images);
        $display("  SPI_FREQ   = %.1f MHz", 1000.0 / (SPI_HALF * 2.0));
        $display("  TIMEOUT    = %0d polls", cfg_timeout);
        $display("");

        if (cfg_dump_vcd) begin
            $dumpfile("tb_top_spi.vcd");
            $dumpvars(0, tb_top_spi);
        end

        total_pass    = 0;
        total_fail    = 0;
        total_correct = 0;
        total_tested  = 0;

        // ============================================================
        // Reset
        // ============================================================
        do_reset();

        // ============================================================
        // Phase A: SPI data-path sanity check
        //   Write a few words via SPI, read them back, verify.
        // ============================================================
        begin : phase_a
            integer pa_pass, pa_fail;
            reg [31:0] rd;
            pa_pass = 0;
            pa_fail = 0;

            $display("========================================");
            $display("PHASE A: SPI Data-Path Sanity Check");
            $display("========================================");

            // Write + readback param_memory
            spi_write(16'h0000, 32'hDEAD_BEEF);
            spi_read_data(16'h0000, rd);
            if (rd === 32'hDEAD_BEEF) begin pa_pass = pa_pass + 1; end
            else begin $display("  FAIL PM[0]: 0x%08h != 0xDEADBEEF", rd); pa_fail = pa_fail + 1; end

            // Write + readback buf_A
            spi_write(16'h2000, 32'hCAFE_BABE);
            spi_read_data(16'h2000, rd);
            if (rd === 32'hCAFE_BABE) begin pa_pass = pa_pass + 1; end
            else begin $display("  FAIL BA[0]: 0x%08h != 0xCAFEBABE", rd); pa_fail = pa_fail + 1; end

            // Write + readback buf_B
            spi_write(16'h4000, 32'h1234_5678);
            spi_read_data(16'h4000, rd);
            if (rd === 32'h1234_5678) begin pa_pass = pa_pass + 1; end
            else begin $display("  FAIL BB[0]: 0x%08h != 0x12345678", rd); pa_fail = pa_fail + 1; end

            // CSR round-trip
            spi_write(16'h6000, 32'h0000_0001);
            spi_read_data(16'h6000, rd);
            if (rd === 32'h0000_0001) begin pa_pass = pa_pass + 1; end
            else begin $display("  FAIL CSR_CTRL: 0x%08h != 1", rd); pa_fail = pa_fail + 1; end
            spi_write(16'h6000, 32'h0000_0000);  // clear start

            $display("Phase A: %0d PASS, %0d FAIL", pa_pass, pa_fail);
            total_pass = total_pass + pa_pass;
            total_fail = total_fail + pa_fail;
        end

        // ============================================================
        // Phase B: Multi-Image Inference via SPI
        // ============================================================
        $display("\n========================================");
        $display("PHASE B: Multi-Image Inference via SPI");
        $display("========================================");

        begin : phase_b
            integer img_id;
            integer cycles;
            reg [3:0] hw_result, exp_label;

            for (img_id = 0; img_id < cfg_num_images; img_id = img_id + 1) begin
                $display("\n--- Image %0d ---", img_id);

                // Full reset between images
                do_reset();

                // Load everything via SPI
                load_all_data_spi(img_id);

                // Run inference (start + poll + result via SPI)
                run_inference_spi(cycles, hw_result);

                // Compare with expected label
                load_label(img_id, exp_label);
                total_tested = total_tested + 1;

                if (hw_result == exp_label) begin
                    $display("  PASS: image_%0d → class %0d (expected %0d), ~%0d cycles",
                             img_id, hw_result, exp_label, cycles);
                    total_pass    = total_pass + 1;
                    total_correct = total_correct + 1;
                end else begin
                    $display("  FAIL: image_%0d → class %0d, expected %0d",
                             img_id, hw_result, exp_label);
                    total_fail = total_fail + 1;
                end
            end
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("\n========================================");
        $display("  TOTAL PASS: %0d / %0d", total_pass, total_pass + total_fail);
        $display("  Inference accuracy: %0d / %0d images correct",
                 total_correct, total_tested);
        if (total_fail == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  FAILURES: %0d", total_fail);
        $display("========================================\n");
        $finish;
    end

    // Global timeout (generous: ~10 min sim time for 10 images)
    initial begin
        #6_000_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
