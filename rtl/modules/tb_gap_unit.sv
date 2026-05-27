`timescale 1ns/1ps

module tb_gap_unit;

    localparam integer DATA_WIDTH = 8;
    localparam integer CLK_PERIOD = 10;

    reg                     clk;
    reg                     reset;
    reg                     request;
    wire                    valid;
    reg  signed [DATA_WIDTH-1:0] data_in;
    wire signed [DATA_WIDTH-1:0] data_out;

    gap_unit #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),
        .request(request),
        .valid(valid),
        .data_in(data_in),
        .data_out(data_out)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end

    integer i, j, errors;
    integer seed;
    reg signed [31:0] sum_acc;
    reg signed [7:0] expected_avg;
    reg signed [7:0] rand_val;

    initial begin
        seed = 54321;
        errors = 0;
        reset = 1;
        request = 0;
        data_in = 0;

        #(CLK_PERIOD * 5);
        @(posedge clk); #1 reset = 0;
        @(posedge clk);

        $display("==========================================================");
        $display("TEST: GLOBAL AVERAGE POOLING (50 Canales Aleatorios)");
        $display("==========================================================");

        for (i = 0; i < 50; i = i + 1) begin
            sum_acc = 0;
            for (j = 0; j < 9; j = j + 1) begin
                rand_val = $random(seed) % 128;
                sum_acc = sum_acc + rand_val;
                
                @(posedge clk); #1;
                data_in = rand_val;
                request = 1;
                @(posedge clk); #1;
                request = 0;
            end

            expected_avg = (sum_acc * 7282) >>> 16;
            if (!valid) @(posedge valid);
            
            $display("[Canal %2d] Suma:%d | HW:%d | EXP:%d", i, sum_acc, data_out, expected_avg);

            if (data_out !== expected_avg) begin
                $display("  ^^^ [ERROR]");
                errors = errors + 1;
            end
        end

        $display("==========================================================");
        if (errors == 0) $display("RESULTADO: GAP OK (50/50 PASSED)");
        else $display("RESULTADO: FAIL (%0d ERRORES)", errors);
        $display("==========================================================");
        $finish;
    end

    initial begin
        $dumpfile("rtl/sim/gap_unit.vcd");
        $dumpvars(0, tb_gap_unit);
    end

endmodule