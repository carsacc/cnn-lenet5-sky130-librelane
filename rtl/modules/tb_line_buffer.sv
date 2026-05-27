// tb_line_buffer.sv — Testbench for line_buffer.v
// Verbose output: every check prints got vs exp.
// Uses integer locals (Icarus-safe pattern).

`timescale 1ns/1ps

module tb_line_buffer;

    parameter integer MAX_WORDS = 28;

    reg         clk;
    reg         reset;
    reg  [31:0] wr_data;
    reg         wr_en;
    reg  [1:0]  wr_row;
    reg  [4:0]  wr_addr;
    reg  [1:0]  rd_row;
    reg  [4:0]  rd_addr;
    wire [31:0] rd_data;
    reg         row_advance;

    line_buffer #(.MAX_WORDS_PER_ROW(MAX_WORDS)) dut (
        .clk        (clk),
        .reset      (reset),
        .wr_data    (wr_data),
        .wr_en      (wr_en),
        .wr_row     (wr_row),
        .wr_addr    (wr_addr),
        .rd_row     (rd_row),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .row_advance(row_advance)
    );

    // Clock: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Counters
    integer total_checks;
    integer total_errors;

    // ------------------------------------------------------------------
    // Helper tasks
    // ------------------------------------------------------------------
    task automatic write_word(input [1:0] row, input [4:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            wr_en   = 1;
            wr_row  = row;
            wr_addr = addr;
            wr_data = data;
            @(negedge clk);
            wr_en = 0;
        end
    endtask

    task automatic check_read(input [1:0] row, input [4:0] addr, input [31:0] expected, input [255:0] label);
        begin
            rd_row  = row;
            rd_addr = addr;
            #1; // combinational settle
            total_checks = total_checks + 1;
            if (rd_data !== expected) begin
                $display("  FAIL [%0s] row=%0d addr=%0d: got=%08h exp=%08h",
                         label, row, addr, rd_data, expected);
                total_errors = total_errors + 1;
            end else begin
                $display("  ok   [%0s] row=%0d addr=%0d: got=%08h", label, row, addr, rd_data);
            end
        end
    endtask

    task automatic pulse_advance;
        begin
            @(negedge clk);
            row_advance = 1;
            @(negedge clk);
            row_advance = 0;
        end
    endtask

    task automatic do_reset;
        begin
            @(negedge clk);
            reset = 1;
            @(negedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    // ------------------------------------------------------------------
    // Main test sequence
    // ------------------------------------------------------------------
    integer i, j;

    initial begin
        $dumpfile("rtl/sim/tb_line_buffer.vcd");
        $dumpvars(0, tb_line_buffer);

        total_checks = 0;
        total_errors = 0;
        wr_en = 0; wr_row = 0; wr_addr = 0; wr_data = 0;
        rd_row = 0; rd_addr = 0; row_advance = 0; reset = 0;

        do_reset;

        // ==============================================================
        // Test 1: Basic write/read — 3 filas, varias columnas
        // ==============================================================
        $display("\n=== Test 1: Basic write/read ===");
        // Write row 0
        write_word(2'd0, 5'd0, 32'hAAAA_0000);
        write_word(2'd0, 5'd1, 32'hAAAA_0001);
        write_word(2'd0, 5'd5, 32'hAAAA_0005);
        // Write row 1
        write_word(2'd1, 5'd0, 32'hBBBB_0000);
        write_word(2'd1, 5'd3, 32'hBBBB_0003);
        // Write row 2
        write_word(2'd2, 5'd0, 32'hCCCC_0000);
        write_word(2'd2, 5'd7, 32'hCCCC_0007);

        // Read back
        check_read(2'd0, 5'd0, 32'hAAAA_0000, "T1 r0a0");
        check_read(2'd0, 5'd1, 32'hAAAA_0001, "T1 r0a1");
        check_read(2'd0, 5'd5, 32'hAAAA_0005, "T1 r0a5");
        check_read(2'd1, 5'd0, 32'hBBBB_0000, "T1 r1a0");
        check_read(2'd1, 5'd3, 32'hBBBB_0003, "T1 r1a3");
        check_read(2'd2, 5'd0, 32'hCCCC_0000, "T1 r2a0");
        check_read(2'd2, 5'd7, 32'hCCCC_0007, "T1 r2a7");

        // ==============================================================
        // Test 2: Byte-level data integrity — pattern: row*0x100 + col*0x10 + 0xAB
        // ==============================================================
        $display("\n=== Test 2: Byte-level data integrity ===");
        do_reset;

        for (i = 0; i < 3; i = i + 1) begin
            for (j = 0; j < 10; j = j + 1) begin
                write_word(i[1:0], j[4:0], {16'hDEAD, i[7:0]*8'h10 + j[7:0], 8'hAB});
            end
        end

        for (i = 0; i < 3; i = i + 1) begin
            for (j = 0; j < 10; j = j + 1) begin
                check_read(i[1:0], j[4:0],
                           {16'hDEAD, i[7:0]*8'h10 + j[7:0], 8'hAB},
                           "T2 integrity");
            end
        end

        // ==============================================================
        // Test 3: Row rotation (1 advance)
        // ==============================================================
        $display("\n=== Test 3: Row rotation (1 advance) ===");
        do_reset;

        // Fill: row0=A, row1=B, row2=C  (1 word each for simplicity)
        write_word(2'd0, 5'd0, 32'h0000_000A);
        write_word(2'd1, 5'd0, 32'h0000_000B);
        write_word(2'd2, 5'd0, 32'h0000_000C);

        // Also write a second column
        write_word(2'd0, 5'd1, 32'h0001_000A);
        write_word(2'd1, 5'd1, 32'h0001_000B);
        write_word(2'd2, 5'd1, 32'h0001_000C);

        // Advance: logical 0 was phy 0 (A), now phy 1 (B)
        pulse_advance;

        // After advance: logical 0 = old mid (B), logical 1 = old bot (C), logical 2 = old top (A stale)
        check_read(2'd0, 5'd0, 32'h0000_000B, "T3 post-adv r0=B");
        check_read(2'd0, 5'd1, 32'h0001_000B, "T3 post-adv r0c1=B");
        check_read(2'd1, 5'd0, 32'h0000_000C, "T3 post-adv r1=C");
        check_read(2'd1, 5'd1, 32'h0001_000C, "T3 post-adv r1c1=C");
        check_read(2'd2, 5'd0, 32'h0000_000A, "T3 post-adv r2=A stale");
        check_read(2'd2, 5'd1, 32'h0001_000A, "T3 post-adv r2c1=A stale");

        // Now write new data D into logical row 2 (the recycled row)
        write_word(2'd2, 5'd0, 32'h0000_000D);
        write_word(2'd2, 5'd1, 32'h0001_000D);
        check_read(2'd2, 5'd0, 32'h0000_000D, "T3 overwrite r2=D");
        check_read(2'd2, 5'd1, 32'h0001_000D, "T3 overwrite r2c1=D");
        // Rows 0,1 unchanged
        check_read(2'd0, 5'd0, 32'h0000_000B, "T3 r0 still B");
        check_read(2'd1, 5'd0, 32'h0000_000C, "T3 r1 still C");

        // ==============================================================
        // Test 4: Multiple rotations (3 advances = full cycle)
        // ==============================================================
        $display("\n=== Test 4: Multiple rotations (3 advances) ===");
        do_reset;

        // Fill rows
        write_word(2'd0, 5'd0, 32'h1111_1111);
        write_word(2'd1, 5'd0, 32'h2222_2222);
        write_word(2'd2, 5'd0, 32'h3333_3333);

        // Check row_base = 0
        check_read(2'd0, 5'd0, 32'h1111_1111, "T4 base=0 r0");
        check_read(2'd1, 5'd0, 32'h2222_2222, "T4 base=0 r1");
        check_read(2'd2, 5'd0, 32'h3333_3333, "T4 base=0 r2");

        // Advance 1: base=1 → logical 0=phy1, 1=phy2, 2=phy0
        pulse_advance;
        check_read(2'd0, 5'd0, 32'h2222_2222, "T4 base=1 r0");
        check_read(2'd1, 5'd0, 32'h3333_3333, "T4 base=1 r1");
        check_read(2'd2, 5'd0, 32'h1111_1111, "T4 base=1 r2");

        // Advance 2: base=2 → logical 0=phy2, 1=phy0, 2=phy1
        pulse_advance;
        check_read(2'd0, 5'd0, 32'h3333_3333, "T4 base=2 r0");
        check_read(2'd1, 5'd0, 32'h1111_1111, "T4 base=2 r1");
        check_read(2'd2, 5'd0, 32'h2222_2222, "T4 base=2 r2");

        // Advance 3: base=0 again → back to original
        pulse_advance;
        check_read(2'd0, 5'd0, 32'h1111_1111, "T4 base=0 r0 (cycle)");
        check_read(2'd1, 5'd0, 32'h2222_2222, "T4 base=0 r1 (cycle)");
        check_read(2'd2, 5'd0, 32'h3333_3333, "T4 base=0 r2 (cycle)");

        // ==============================================================
        // Test 5: Conv1 pattern (OC mode) — 7 words/row (28 px ÷ 4)
        // ==============================================================
        $display("\n=== Test 5: Conv1 pattern (7 words/row) ===");
        do_reset;

        // Fill 3 rows, 7 words each. Pattern: {row[3:0], col[3:0], 16'hCAFE, 8'h00+col}
        for (i = 0; i < 3; i = i + 1) begin
            for (j = 0; j < 7; j = j + 1) begin
                write_word(i[1:0], j[4:0], {i[3:0], j[3:0], 16'hCAFE, j[7:0]});
            end
        end

        // Simulate reading a 3×3 window for out_col=0:
        // kernel positions (kr=0..2, kc=0..2) with 1 IC-group → rd_addr = out_col + kc = kc
        // Note: with 4 pixels packed per word, the FSM would compute different addresses.
        // Here we just check that the stored words are readable at expected positions.
        begin : blk_t5
            integer kr, kc;
            integer exp;
            for (kr = 0; kr < 3; kr = kr + 1) begin
                for (kc = 0; kc < 3; kc = kc + 1) begin
                    exp = {kr[3:0], kc[3:0], 16'hCAFE, kc[7:0]};
                    check_read(kr[1:0], kc[4:0], exp[31:0], "T5 win(0)");
                end
            end
        end

        // Window for out_col=2 → rd_addr = 2+kc
        begin : blk_t5b
            integer kr, kc;
            integer exp;
            integer addr;
            for (kr = 0; kr < 3; kr = kr + 1) begin
                for (kc = 0; kc < 3; kc = kc + 1) begin
                    addr = 2 + kc;
                    exp = {kr[3:0], addr[3:0], 16'hCAFE, addr[7:0]};
                    check_read(kr[1:0], addr[4:0], exp[31:0], "T5 win(2)");
                end
            end
        end

        // ==============================================================
        // Test 6: Conv2 pattern (IC mode) — 26 words/row (13 cols × 2 IC-groups)
        // ==============================================================
        $display("\n=== Test 6: Conv2 pattern (26 words/row) ===");
        do_reset;

        // Fill 3 rows, 26 words each. addr = col*2 + ic_group
        // Pattern: {row[7:0], col[7:0], ic_group[7:0], 8'hFF}
        for (i = 0; i < 3; i = i + 1) begin
            for (j = 0; j < 26; j = j + 1) begin
                write_word(i[1:0], j[4:0], {i[7:0], j[7:0] >> 1, j[0], 7'b0, 8'hFF});
            end
        end

        // Read: for out_col=1, kernel_col=0, ic_group=0 → addr = (1+0)*2 + 0 = 2
        // For out_col=1, kernel_col=0, ic_group=1 → addr = (1+0)*2 + 1 = 3
        begin : blk_t6
            integer row, addr, exp;
            // Check a few specific positions
            // addr=2: col=1, icg=0 → {row, 8'd1, 8'h00, 8'hFF}
            for (row = 0; row < 3; row = row + 1) begin
                addr = 2; // col=1, icg=0
                exp = {row[7:0], 8'd1, 8'h00, 8'hFF};
                check_read(row[1:0], addr[4:0], exp[31:0], "T6 c1g0");

                addr = 3; // col=1, icg=1
                exp = {row[7:0], 8'd1, 8'h80, 8'hFF};
                check_read(row[1:0], addr[4:0], exp[31:0], "T6 c1g1");

                addr = 10; // col=5, icg=0
                exp = {row[7:0], 8'd5, 8'h00, 8'hFF};
                check_read(row[1:0], addr[4:0], exp[31:0], "T6 c5g0");
            end
        end

        // ==============================================================
        // Test 7: Simultaneous read/write (different rows)
        // ==============================================================
        $display("\n=== Test 7: Simultaneous read/write ===");
        do_reset;

        // Pre-fill row 0 with known data
        write_word(2'd0, 5'd0, 32'hDEAD_BEEF);
        write_word(2'd0, 5'd1, 32'hCAFE_BABE);

        // Now write to row 1 while reading from row 0 in the same cycle
        @(negedge clk);
        wr_en   = 1;
        wr_row  = 2'd1;
        wr_addr = 5'd0;
        wr_data = 32'h1234_5678;
        rd_row  = 2'd0;
        rd_addr = 5'd0;
        #1;
        // Read should still give row 0 data (combinational)
        total_checks = total_checks + 1;
        if (rd_data !== 32'hDEAD_BEEF) begin
            $display("  FAIL [T7 simul rd] got=%08h exp=DEADBEEF", rd_data);
            total_errors = total_errors + 1;
        end else begin
            $display("  ok   [T7 simul rd] got=%08h", rd_data);
        end
        @(negedge clk);
        wr_en = 0;

        // Verify the write landed in row 1
        check_read(2'd1, 5'd0, 32'h1234_5678, "T7 wr landed");
        // Row 0 still intact
        check_read(2'd0, 5'd0, 32'hDEAD_BEEF, "T7 r0 intact");
        check_read(2'd0, 5'd1, 32'hCAFE_BABE, "T7 r0c1 intact");

        // ==============================================================
        // Test 8: Reset — row_base returns to 0
        // ==============================================================
        $display("\n=== Test 8: Reset ===");
        // Advance twice so row_base = 2
        pulse_advance;
        pulse_advance;
        // Verify row_base is non-zero by checking mapping changed
        // (row 0 data should be at logical row 1 since base=2:
        //  logical 0 → phy (2+0)%3=2, logical 1 → phy (2+1)%3=0, logical 2 → phy (2+2)%3=1)
        // Row 0 has DEADBEEF at phy 0 → now at logical 1
        check_read(2'd1, 5'd0, 32'hDEAD_BEEF, "T8 pre-reset base=2 r1=phy0");

        // Reset
        do_reset;

        // After reset, row_base=0, so logical 0 → phy 0 again
        check_read(2'd0, 5'd0, 32'hDEAD_BEEF, "T8 post-reset base=0 r0=phy0");

        // ==============================================================
        // Summary
        // ==============================================================
        $display("\n========================================");
        if (total_errors == 0) begin
            $display("ALL PASS (%0d/%0d checks)", total_checks, total_checks);
        end else begin
            $display("FAIL: %0d errors out of %0d checks", total_errors, total_checks);
        end
        $display("========================================\n");

        $finish;
    end

endmodule
