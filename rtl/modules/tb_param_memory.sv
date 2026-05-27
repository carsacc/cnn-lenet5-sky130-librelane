`timescale 1ns/1ps

module tb_param_memory;

    // Parámetros
    parameter DATA_WIDTH = 32;
    parameter ADDR_WIDTH = 11;
    parameter CLK_PERIOD = 10;
    parameter MEM_DEPTH = 2048;

    // Señales
    logic clk;
    logic reset;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] din;
    logic read_writeb;
    logic request;
    wire [DATA_WIDTH-1:0] dout;
    wire valid;

    // Memorias
    logic [DATA_WIDTH-1:0] reference_data [0:MEM_DEPTH-1];
    logic [DATA_WIDTH-1:0] dump_data [0:MEM_DEPTH-1];

    integer bank_access [4];
    integer i;
    integer errors;

    // Instancia del DUT
    param_memory #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .reset(reset), .addr(addr), .din(din),
        .read_writeb(read_writeb), .request(request),
        .dout(dout), .valid(valid)
    );

    // Reloj
    always #(CLK_PERIOD/2) clk = ~clk;

    // Tarea de Escritura
    task write_word(input [ADDR_WIDTH-1:0] waddr, input [DATA_WIDTH-1:0] wdata);
        begin
            @(posedge clk); #1;
            request = 1; read_writeb = 0;
            addr = waddr; din = wdata;
            bank_access[waddr[10:9]]++;
            wait(valid === 1'b1);
            @(posedge clk); #1;
            request = 0;
        end
    endtask

    // Tarea de Lectura
    task read_word(input [ADDR_WIDTH-1:0] raddr, output [DATA_WIDTH-1:0] rdata);
        begin
            @(posedge clk); #1;
            request = 1; read_writeb = 1;
            addr = raddr;
            bank_access[raddr[10:9]]++;
            wait(valid === 1'b1);
            rdata = dout;
            @(posedge clk); #1;
            request = 0;
        end
    endtask

    string repo_root;

    initial begin
        // Inicialización
        clk = 0; reset = 1; request = 0; errors = 0;
        for(int b=0; b<4; b++) bank_access[b] = 0;
        for(int m=0; m<MEM_DEPTH; m++) dump_data[m] = 32'h0;

        // Watchdog para seguridad
        fork
            begin
                #2000000;
                $display("ERROR: Simulation timeout!");
                $finish;
            end
        join_none

        // Cargar datos originales (REPO_ROOT inyectado por el Makefile)
        if (!$value$plusargs("REPO_ROOT=%s", repo_root)) repo_root = ".";
        $display("Cargando datos desde: %s/datos_hex_std/PARAM_MEM_32x2048.hex", repo_root);
        $readmemh({repo_root, "/datos_hex_std/PARAM_MEM_32x2048.hex"}, reference_data);

        $dumpfile({repo_root, "/rtl/sim/tb_param_memory.vcd"});
        $dumpvars(0, tb_param_memory);

        #(CLK_PERIOD * 5); reset = 0; #(CLK_PERIOD * 2);

        // FASE 1: ESCRITURA
        $display("--- Iniciando Escritura de 2048 palabras ---");
        for (i = 0; i < MEM_DEPTH; i++) begin
            write_word(i[ADDR_WIDTH-1:0], reference_data[i]);
        end

        #(CLK_PERIOD * 10);

        // FASE 2: LECTURA, VERIFICACIÓN Y CAPTURA
        $display("--- Iniciando Lectura y Captura ---");
        for (i = 0; i < MEM_DEPTH; i++) begin
            logic [DATA_WIDTH-1:0] read_val;
            read_word(i[ADDR_WIDTH-1:0], read_val);
            dump_data[i] = read_val; // Guardar para el dump

            assert(read_val === reference_data[i])
                else begin
                    $display("ERROR mismatch @ %h: Get %h, Exp %h", i, read_val, reference_data[i]);
                    errors++;
                end
        end

        // FASE 3: DUMP A ARCHIVO HEX
        $display("--- Generando archivo PARAM_MEM_dump.hex ---");
        $writememh({repo_root, "/rtl/sim/PARAM_MEM_dump.hex"}, dump_data);

        if (errors == 0)
            $display("\n--- TEST EXITOSO: Datos volcados correctamente ---");
        else
            $display("\n--- TEST FALLIDO: %0d errores detectados ---", errors);

        $finish;
    end
endmodule
