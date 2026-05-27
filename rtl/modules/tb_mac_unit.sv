`timescale 1ns/1ps

module tb_mac_unit;

    localparam integer DATA_WIDTH = 8;
    localparam integer ACC_WIDTH = 32;
    localparam integer CLK_PERIOD = 10;

    reg clk, reset, valid_in, acc_clear;
    wire valid_out;
    reg signed [DATA_WIDTH-1:0] pixel_in, weight_in;
    reg signed [ACC_WIDTH-1:0] bias_in;
    wire signed [ACC_WIDTH-1:0] acc_out;

    mac_unit #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk), .reset(reset),
        .valid_in(valid_in), .acc_clear(acc_clear),
        .bias_in(bias_in), .pixel_in(pixel_in), .weight_in(weight_in),
        .acc_out(acc_out), .valid_out(valid_out)
    );

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end

    integer i, k, errors;
    integer seed = 123;
    integer burst_len;
    
    // Usamos real o variables de 64 bits para el modelo de referencia
    longint theoretical_acc;

    initial begin
        errors = 0;
        reset = 1; valid_in = 0; acc_clear = 0;
        #(CLK_PERIOD*5); @(posedge clk); #1 reset = 0;
        @(posedge clk);

        $display("\n==========================================================");
        $display("VERIFICACION MAC: Bias + Sum(Px * W)");
        $display("==========================================================");

        for (i = 0; i < 20; i = i + 1) begin
            bias_in = $random(seed) % 100;
            burst_len = ($random(seed) % 5) + 3; // Ráfagas de 3 a 7
            
            $display("\n--- Ráfaga #%0d (Bias Inicial: %d) ---", i, bias_in);

            for (k = 0; k < burst_len; k = k + 1) begin
                pixel_in = $random(seed) % 16;
                weight_in = $random(seed) % 16;
                acc_clear = (k == 0);
                valid_in = 1;
                
                // Modelo de referencia
                if (k == 0)
                    theoretical_acc = bias_in + ($signed(pixel_in) * $signed(weight_in));
                else
                    theoretical_acc = theoretical_acc + ($signed(pixel_in) * $signed(weight_in));
                
                @(posedge clk); #1;
                
                $display("  Ciclo %0d: [%d * %d] | Acumulado HW: %d | Esperado: %d", 
                         k, pixel_in, weight_in, acc_out, theoretical_acc[31:0]);

                if (acc_out !== theoretical_acc[31:0]) begin
                    $display("    ^^^ [ERROR]");
                    errors = errors + 1;
                end
            end
            
            valid_in = 0;
            acc_clear = 0;
            @(posedge clk);
        end

        $display("\n==========================================================");
        if (errors == 0) $display("RESULTADO FINAL: MAC OK (Todas las ráfagas correctas)");
        else $display("RESULTADO FINAL: FAIL (%0d ERRORES)", errors);
        $display("==========================================================");
        $finish;
    end

endmodule