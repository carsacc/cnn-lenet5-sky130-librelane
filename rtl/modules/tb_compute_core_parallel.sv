`timescale 1ns/1ps

module tb_compute_core_parallel;

    localparam integer DATA_WIDTH = 8;
    localparam integer ACC_WIDTH  = 32;
    localparam integer CLK_PERIOD = 10;

    logic                          clk, reset;
    logic                          request, acc_clear, process_out, frame_start;
    logic                          relu_en, pool_en, is_parallel_ic;
    logic [5:0]                    img_width;
    logic [31:0]                   weights_word;
    logic [31:0]                   pixel_word;
    logic signed [ACC_WIDTH-1:0]   bias_0, bias_1, bias_2, bias_3;
    logic signed [31:0]            mult_0, mult_1, mult_2, mult_3;
    logic [7:0]                    shift_amt;
    logic [7:0]                    zp_0, zp_1, zp_2, zp_3;
    wire  [31:0]                   data_out_word;
    wire                           valid;
    wire  [ACC_WIDTH-1:0]          sum_tree_out;

    compute_core_parallel #(
        .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) dut (.*);

    initial begin clk = 0; forever #(CLK_PERIOD/2) clk = ~clk; end
    initial begin #10000000; $display("\n[TIMEOUT]"); $finish; end

    integer errors;
    integer seed = 456;

    // -----------------------------------------------------------------------
    // Funcion de modelo de referencia (requantizacion)
    // -----------------------------------------------------------------------
    function automatic signed [7:0] golden_requant(
        input signed [31:0] acc,
        input signed [31:0] mult,
        input        [7:0]  shift,
        input        [7:0]  zp,
        input               relu
    );
        logic signed [63:0] f;
        logic signed [31:0] sc;
        begin
            f  = $signed(acc) * $signed(mult);
            sc = (f >>> shift) + $signed({24'd0, zp});
            if      (sc >  32'sd127)  golden_requant = 8'sd127;
            else if (sc < -32'sd128)  golden_requant = -8'sd128;
            else                      golden_requant = sc[7:0];
            if (relu && golden_requant < 0) golden_requant = 0;
        end
    endfunction

    // -----------------------------------------------------------------------
    // Tarea: un pulso request de 1 ciclo (back-to-back, sin idle)
    // -----------------------------------------------------------------------
    task automatic send_pixel(
        input [31:0] pword,
        input [31:0] wword,
        input        clear
    );
        pixel_word   = pword;
        weights_word = wword;
        acc_clear    = clear;
        request      = 1;
        @(posedge clk); #1;
        request  = 0;
        acc_clear = 0;
    endtask

    // -----------------------------------------------------------------------
    // Tarea: disparar process_out y esperar valid
    // -----------------------------------------------------------------------
    task automatic fire_and_wait(output logic [31:0] result);
        process_out = 1;
        @(posedge clk); #1;
        process_out = 0;
        while (!valid) @(posedge clk);
        #1;
        result = data_out_word;
    endtask

    // -----------------------------------------------------------------------
    // INICIO
    // -----------------------------------------------------------------------
    initial begin
        errors       = 0;
        request      = 0; acc_clear    = 0; process_out  = 0; frame_start  = 0;
        relu_en      = 0; pool_en      = 0; is_parallel_ic = 0;
        img_width    = 0; pixel_word   = 0; weights_word = 0;
        bias_0 = 0; bias_1 = 0; bias_2 = 0; bias_3 = 0;
        mult_0 = 32'sd65536; mult_1 = 32'sd65536;
        mult_2 = 32'sd65536; mult_3 = 32'sd65536;
        shift_amt = 8'd16;
        zp_0 = 0; zp_1 = 0; zp_2 = 0; zp_3 = 0;
        reset = 1; #(CLK_PERIOD*5);
        @(posedge clk); #1; reset = 0;
        @(posedge clk);

        // ===================================================================
        // TEST 1: MODO OC-PARALLEL (CONV1/FC)
        // Cada lane es independiente. 4 filtros calculados en paralelo.
        // 20 rafagas aleatorias de 9 acumulaciones (kernel 3x3, 1 IC).
        // ===================================================================
        $display("\n===========================================================");
        $display("TEST 1: MODO OC-PARALLEL (is_parallel_ic=0)");
        $display("  4 canales de salida independientes, kernel 3x3");
        $display("===========================================================");
        is_parallel_ic = 0;
        relu_en = 1; pool_en = 0;
        shift_amt = 16;
        mult_0 = 32'sd65536; mult_1 = 32'sd65536;
        mult_2 = 32'sd65536; mult_3 = 32'sd65536;
        zp_0 = 0; zp_1 = 0; zp_2 = 0; zp_3 = 0;

        begin : blk_oc_test
            integer k, j;
            integer g_acc [0:3];      // integer = signed 32-bit, evita truncacion en Icarus
            logic signed [7:0] g_final [0:3];
            logic [31:0] hw_result;
            integer px;               // integer para aritmetica signed correcta
            integer w0, w1, w2, w3;

            for (k = 0; k < 20; k = k + 1) begin
                bias_0 = $random(seed) % 200;
                bias_1 = $random(seed) % 200;
                bias_2 = $random(seed) % 200;
                bias_3 = $random(seed) % 200;
                g_acc[0] = $signed(bias_0);
                g_acc[1] = $signed(bias_1);
                g_acc[2] = $signed(bias_2);
                g_acc[3] = $signed(bias_3);

                // 9 ciclos de acumulacion (kernel 3x3, 1 IC -> broadcast)
                for (j = 0; j < 9; j = j + 1) begin
                    px = $random(seed) % 32;
                    w0 = $random(seed) % 16;
                    w1 = $random(seed) % 16;
                    w2 = $random(seed) % 16;
                    w3 = $random(seed) % 16;

                    // pixel broadcast: mismo pixel para los 4 lanes
                    // px[7:0] preserva los 8 bits del valor (positivo/negativo)
                    send_pixel({{px[7:0]},{px[7:0]},{px[7:0]},{px[7:0]}},
                               {w3[7:0], w2[7:0], w1[7:0], w0[7:0]}, (j==0));

                    g_acc[0] += (px * w0);
                    g_acc[1] += (px * w1);
                    g_acc[2] += (px * w2);
                    g_acc[3] += (px * w3);
                end

                fire_and_wait(hw_result);

                for (j = 0; j < 4; j = j + 1)
                    g_final[j] = golden_requant(g_acc[j], 32'sd65536, 16, 0, 1);

                if (hw_result !== {g_final[3], g_final[2], g_final[1], g_final[0]}) begin
                    $display("  [ERROR] Rafaga OC #%0d: HW=%h EXP=%h",
                             k, hw_result,
                             {g_final[3], g_final[2], g_final[1], g_final[0]});
                    errors++;
                end
            end
        end

        if (errors == 0) $display("  RESULTADO TEST1: PASS (20/20)");
        else             $display("  RESULTADO TEST1: FAIL (%0d errores)", errors);

        // ===================================================================
        // TEST 2: MODO IC-PARALLEL (CONV2/CONV3)
        // 4 canales de entrada se suman para 1 canal de salida.
        // Verifica que:
        //   a) El bias solo se suma una vez (hardware fuerza bias_1/2/3=0).
        //   b) El post_proc usa mult_0/zp_0 para todos los lanes.
        //   c) data_out_word[7:0] contiene el resultado correcto.
        //   d) Los 4 bytes de data_out_word son identicos.
        // ===================================================================
        $display("\n===========================================================");
        $display("TEST 2: MODO IC-PARALLEL (is_parallel_ic=1)");
        $display("  4 ICs sumados para 1 OC, kernel 3x3");
        $display("  Verifica mux de metadatos: bias/mult/zp de lane 0 para todos");
        $display("===========================================================");
        is_parallel_ic = 1;
        relu_en = 0; pool_en = 0;
        shift_amt = 16;
        mult_0 = 32'sd65536;
        zp_0 = 0;

        // Dar bias_1/2/3 con valores distintos de cero para verificar
        // que el hardware los ignora (mux los fuerza a 0 en IC mode)
        bias_1 = 32'sd9999; bias_2 = 32'sd9999; bias_3 = 32'sd9999;
        mult_1 = 32'sd1;    mult_2 = 32'sd1;    mult_3 = 32'sd1;
        zp_1   = 8'd77;     zp_2   = 8'd77;     zp_3   = 8'd77;

        begin : blk_ic_test
            integer k, j, ic;
            integer g_acc;            // integer = signed 32-bit
            logic signed [7:0]  g_final;
            logic signed [7:0]  expected_byte;
            logic [31:0] hw_result;
            integer px [0:3];         // integer para aritmetica signed correcta
            integer w  [0:3];
            logic [31:0] pword, wword;

            for (k = 0; k < 10; k = k + 1) begin
                bias_0  = $random(seed) % 500;
                mult_0  = $random(seed) % 131072 + 32'sd32768;
                zp_0    = $random(seed) % 20;
                g_acc   = $signed(bias_0);

                // 9 posiciones del kernel 3x3, con 4 IC por posicion
                for (j = 0; j < 9; j = j + 1) begin
                    for (ic = 0; ic < 4; ic = ic + 1) begin
                        px[ic] = $random(seed) % 20;
                        w[ic]  = $random(seed) % 16;
                    end

                    pword = {px[3][7:0], px[2][7:0], px[1][7:0], px[0][7:0]};
                    wword = {w[3][7:0],  w[2][7:0],  w[1][7:0],  w[0][7:0]};

                    send_pixel(pword, wword, (j==0));

                    // Modelo de referencia: acumula los 4 productos + bias al inicio
                    for (ic = 0; ic < 4; ic = ic + 1)
                        g_acc += (px[ic] * w[ic]);
                end

                fire_and_wait(hw_result);

                g_final = golden_requant(g_acc, mult_0, shift_amt, zp_0, 0);
                expected_byte = g_final;

                // Byte 0 debe ser el resultado correcto
                if (hw_result[7:0] !== expected_byte) begin
                    $display("  [ERROR] IC Rafaga #%0d byte0: HW=%0d EXP=%0d (acc=%0d)",
                             k, $signed(hw_result[7:0]), $signed(expected_byte), g_acc);
                    errors++;
                end

                // En IC mode, todos los bytes deben ser identicos
                if (hw_result[31:8] !== {hw_result[7:0], hw_result[7:0], hw_result[7:0]}) begin
                    $display("  [ERROR] IC Rafaga #%0d: bytes no identicos data_out_word=%h",
                             k, hw_result);
                    errors++;
                end
            end
        end

        if (errors == 0) $display("  RESULTADO TEST2: PASS (10/10)");
        else             $display("  RESULTADO TEST2: FAIL (%0d errores)", errors);

        // ===================================================================
        // RESUMEN
        // ===================================================================
        $display("\n===========================================================");
        if (errors == 0)
            $display("RESULTADO FINAL: TODOS LOS TESTS PASARON (0 Errores)");
        else
            $display("RESULTADO FINAL: FALLO CON %0d ERRORES", errors);
        $display("===========================================================");
        $finish;
    end

endmodule
