`timescale 1ns/1ps

module tb_post_proc_unit;

    localparam integer ACC_WIDTH = 32;
    localparam integer DATA_WIDTH = 8;
    localparam integer CLK_PERIOD = 10;

    logic                     clk;
    logic                     reset;
    logic                     request;
    logic                     frame_start;
    wire                      valid;
    logic                     relu_en;
    logic                     pool_en;
    logic [5:0]               img_width;
    logic signed [ACC_WIDTH-1:0] data_in;
    logic signed [31:0]       multiplier;
    logic [7:0]               shift_amt;
    logic [7:0]               offset_zp;
    wire  signed [DATA_WIDTH-1:0] data_out;

    post_proc_unit #(
        .MAX_IMG_WIDTH(32)
    ) dut (.*);

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Timeout
    initial begin #10000000; $display("\n[TIMEOUT]"); $finish; end

    integer i, errors;
    integer seed = 12345;
    
    logic signed [31:0] r_in, r_mult;
    logic [7:0] r_sh, r_zp;
    logic r_relu;

    initial begin
        errors = 0;
        init_signals();
        #(CLK_PERIOD * 5);
        @(posedge clk); #1 reset = 0;
        @(posedge clk);

        $display("\n==========================================================");
        $display("TEST 1: REQUANT + RELU (50 Iteraciones Aleatorias)");
        $display("==========================================================");
        pool_en = 0; 
        
        for (i = 0; i < 50; i = i + 1) begin
            r_in = $random(seed) % 10000;
            r_mult = $random(seed) % 65536;
            r_sh = ($random(seed) % 12) + 8; // Shift entre 8 y 20
            r_zp = $random(seed) % 20;
            r_relu = $random(seed) % 2;
            check_random_case(r_in, r_mult, r_sh, r_zp, r_relu, i);
        end

        $display("\n==========================================================");
        $display("TEST 2: MAX-POOL 2x2 (5 Matrices 4x4 Aleatorias)");
        $display("==========================================================");
        relu_en = 0; pool_en = 1; img_width = 4;
        multiplier = 1; shift_amt = 0; offset_zp = 0;

        for (i = 0; i < 5; i = i + 1) begin
            $display("\n--- Matriz Aleatoria #%0d ---", i);
            run_random_pool_matrix();
        end

        $display("\n==========================================================");
        $display("TEST 3: FRAME_START - Bug contador pool con 11x11 (filas impar)");
        $display("Escenario: 2 canales consecutivos. Sin frame_start el 2do canal");
        $display("empezaria en fila impar y produciria salidas erroneas.");
        $display("==========================================================");
        relu_en = 0; pool_en = 1; img_width = 11;
        multiplier = 32'sd1; shift_amt = 0; offset_zp = 0;

        // Canal 0: todos los pixels = 10 -> pool result esperado = 10
        // Protocolo back-to-back (sin ciclos idle entre pixeles):
        // Usar ciclos idle causaba race condition en Icarus Verilog donde
        // request=1 de la siguiente iteracion se alinea con el flanco del
        // reloj idle, provocando que el DUT lo capture dos veces.
        $display("\n--- Canal 0: 11x11, todos pixels=10 ---");
        begin : blk_ch0
            integer r, c, out_cnt;
            out_cnt = 0;
            for (r = 0; r < 11; r = r + 1) begin
                for (c = 0; c < 11; c = c + 1) begin
                    data_in = 32'sd10; request = 1;
                    @(posedge clk); #1; request = 0;
                    if (valid) begin
                        out_cnt = out_cnt + 1;
                        if (data_out !== 8'sd10) begin
                            $display("  [ERROR] Canal0 salida#%0d: %d (esperado 10)", out_cnt, data_out);
                            errors = errors + 1;
                        end
                    end
                end
            end
            $display("  Canal 0: %0d salidas pool emitidas (esperado 25)", out_cnt);
        end

        // Ciclo idle + pulso frame_start
        @(posedge clk); #1;
        frame_start = 1;
        @(posedge clk); #1;
        frame_start = 0;

        // Canal 1: todos los pixels = 20 -> pool result esperado = 20
        // Sin frame_start, Canal 1 empezaria en row_cnt impar (estado residual
        // del Canal 0) y produciria salidas erroneas.
        $display("\n--- Canal 1: 11x11, todos pixels=20 (verifica frame_start) ---");
        begin : blk_ch1
            integer r, c, out_cnt;
            out_cnt = 0;
            for (r = 0; r < 11; r = r + 1) begin
                for (c = 0; c < 11; c = c + 1) begin
                    data_in = 32'sd20; request = 1;
                    @(posedge clk); #1; request = 0;
                    if (valid) begin
                        out_cnt = out_cnt + 1;
                        if (data_out !== 8'sd20) begin
                            $display("  [ERROR] Canal1 salida#%0d: %d (esperado 20, contaminacion detectada!)", out_cnt, data_out);
                            errors = errors + 1;
                        end
                    end
                end
            end
            $display("  Canal 1: %0d salidas pool emitidas (esperado 25)", out_cnt);
        end

        $display("\n==========================================================");
        if (errors == 0)
            $display("RESULTADO: TODOS LOS TESTS PASARON (0 Errores)");
        else
            $display("RESULTADO: FALLO CON %0d ERRORES", errors);
        $display("==========================================================");
        $finish;
    end

    task init_signals();
        reset = 1; request = 0; frame_start = 0; relu_en = 0; pool_en = 0;
        img_width = 0; data_in = 0; multiplier = 0;
        shift_amt = 0; offset_zp = 0;
    endtask

    task check_random_case(input signed [31:0] in, mult, input [7:0] sh, zp, input r_en, integer iter);
        reg signed [63:0] full_mult;
        reg signed [63:0] scaled;
        reg signed [31:0] with_zp;
        reg signed [7:0] expected;
        begin
            multiplier = mult; shift_amt = sh; offset_zp = zp; relu_en = r_en;
            data_in = in; request = 1;
            
            full_mult = $signed(in) * $signed(mult);
            scaled = full_mult >>> sh;
            with_zp = scaled[31:0] + $signed({24'd0, zp});
            
            if (with_zp > 127) expected = 127;
            else if (with_zp < -128) expected = -128;
            else expected = with_zp[7:0];
            
            if (r_en && expected < 0) expected = 0;

            @(posedge clk); #1; request = 0;
            if (!valid) @(posedge valid);
            
            $display("[It:%2d] In:%d * %d >> %d + %d (ReLU:%b) -> HW:%d | EXP:%d", 
                     iter, in, mult, sh, zp, r_en, data_out, expected);

            if (data_out !== expected) begin
                $display("  ^^^ [ERROR]");
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    task run_random_pool_matrix();
        logic signed [7:0] m[0:3][0:3];
        logic signed [7:0] exp[0:3];
        integer r, c, idx;
        begin
            for (r=0; r<4; r++) for(c=0; c<4; c++) m[r][c] = $random(seed) % 128;
            
            exp[0] = max4(m[0][0], m[0][1], m[1][0], m[1][1]);
            exp[1] = max4(m[0][2], m[0][3], m[1][2], m[1][3]);
            exp[2] = max4(m[2][0], m[2][1], m[3][0], m[3][1]);
            exp[3] = max4(m[2][2], m[2][3], m[3][2], m[3][3]);

            for (r=0; r<4; r++) begin
                for (c=0; c<4; c++) begin
                    data_in = m[r][c]; request = 1;
                    @(posedge clk); #1; request = 0;
                    if (valid) begin
                        idx = (r/2)*2 + (c/2);
                        $display("  Salida Pool Detectada: %d (Esperado: %d)", data_out, exp[idx]);
                        if (data_out !== exp[idx]) begin
                            $display("    ^^^ [ERROR POOL]");
                            errors = errors + 1;
                        end
                    end
                end
            end
        end
    endtask

    function signed [7:0] max4(input signed [7:0] a, b, c, d);
        logic signed [7:0] m1, m2;
        begin
            m1 = (a > b) ? a : b;
            m2 = (c > d) ? c : d;
            max4 = (m1 > m2) ? m1 : m2;
        end
    endfunction

endmodule