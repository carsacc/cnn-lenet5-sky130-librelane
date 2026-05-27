`timescale 1ns/1ps

module tb_argmax_unit;

    localparam integer DATA_WIDTH = 8;
    localparam integer NUM_CLASSES = 10;
    localparam integer IDX_WIDTH = 4;
    localparam integer CLK_PERIOD = 10;

    reg                     clk;
    reg                     reset;
    reg                     request;
    wire                    done;
    reg  signed [DATA_WIDTH-1:0] data_in;
    wire [IDX_WIDTH-1:0]    argmax_idx;
    wire signed [DATA_WIDTH-1:0] max_value;

    argmax_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_CLASSES(NUM_CLASSES)
    ) dut (
        .clk(clk),
        .reset(reset),
        .request(request),
        .done(done),
        .data_in(data_in),
        .argmax_idx(argmax_idx),
        .max_value(max_value)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin #5000000; $display("TIMEOUT"); $finish; end

    integer i, j, errors;
    integer seed;
    reg signed [7:0] test_vector [0:9];
    reg signed [7:0] expected_max;
    integer expected_idx;

    initial begin
        seed = 98765;
        errors = 0;
        reset = 1;
        request = 0;
        data_in = 0;

        #(CLK_PERIOD * 5);
        @(posedge clk); #1 reset = 0;
        @(posedge clk);

        $display("==========================================================");
        $display("TEST: ARGMAX UNIT (20 Iteraciones Aleatorias)");
        $display("==========================================================");

        for (i = 0; i < 20; i = i + 1) begin
            expected_max = -8'sd128;
            expected_idx = 0;
            
            // Generar vector
            for (j = 0; j < 10; j = j + 1) begin
                test_vector[j] = $random(seed) % 128;
                if (j == 0 || test_vector[j] > expected_max) begin
                    expected_max = test_vector[j];
                    expected_idx = j;
                end
            end

            // Enviar
            for (j = 0; j < 10; j = j + 1) begin
                @(posedge clk); #1;
                data_in = test_vector[j];
                request = 1;
                @(posedge clk); #1;
                request = 0;
            end

            if (!done) @(posedge done);
            
            $display("[It %2d] HW: Idx=%0d Val=%d | EXP: Idx=%0d Val=%d", 
                     i, argmax_idx, max_value, expected_idx, expected_max);

            if (argmax_idx !== expected_idx[3:0] || max_value !== expected_max) begin
                $display("  ^^^ [ERROR]");
                errors = errors + 1;
            end
        end

        $display("==========================================================");
        if (errors == 0) $display("RESULTADO: ARGMAX OK (20/20 PASSED)");
        else $display("RESULTADO: FAIL (%0d ERRORES)", errors);
        $display("==========================================================");
        $finish;
    end

    initial begin
        $dumpfile("rtl/sim/argmax_unit.vcd");
        $dumpvars(0, tb_argmax_unit);
    end

endmodule