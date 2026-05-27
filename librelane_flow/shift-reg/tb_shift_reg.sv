// tb_shift_reg.sv
// Testbench para shift_reg. Modos soportados.
//   - RTL puro:       no macro `SDF.
//   - GLS post-PnR:   `define SDF + +SDF_FILE=<path al .sdf>
// Salida VCD siempre activa para inspeccion en GTKWave/Surfer.
//
// Ejemplo de uso con Icarus (RTL):
//   iverilog -g2012 -o sim_rtl.out shift_reg.v tb_shift_reg.sv
//   vvp sim_rtl.out
//
// Ejemplo de uso con Icarus + SDF (post-PnR):
//   iverilog -g2012 -DSDF -DFUNCTIONAL -o sim_sdf.out \
//       runs/<RUN>/final/pnl/shift_reg.pnl.v \
//       ~/.ciel/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v \
//       ~/.ciel/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v \
//       tb_shift_reg.sv
//   vvp sim_sdf.out +SDF_FILE=runs/<RUN>/final/sdf/shift_reg__nom_tt_025C_1v80.sdf
//
`timescale 1ns/1ps

module tb_shift_reg;
    localparam integer WIDTH      = 8;
    localparam integer CLK_PERIOD = 10;          // ns

    reg              clk;
    reg              reset;
    reg              en;
    reg              d_in;
    wire [WIDTH-1:0] q_out;

    integer i;
    integer errors;
    reg     [WIDTH-1:0] expected;
    reg     [15:0]      pattern;

    // -----------------------------------------------------------
    // DUT. Sin parametro WIDTH para que la misma instanciacion sirva en
    // RTL (default WIDTH=8) y en netlist post-PnR (parametros resueltos).
    // Pines de power solo en GLS, cuando se compila con USE_POWER_PINS.
    // -----------------------------------------------------------
`ifdef USE_POWER_PINS
    supply1 vccd1;
    supply0 vssd1;
`endif

    shift_reg u_dut (
        .clk   (clk),
        .reset (reset),
        .en    (en),
        .d_in  (d_in),
`ifdef USE_POWER_PINS
        .vccd1 (vccd1),
        .vssd1 (vssd1),
`endif
        .q_out (q_out)
    );

    // -----------------------------------------------------------
    // Reloj
    // -----------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------
    // SDF annotation. La ruta se pasa como define literal en compile-time,
    // p.ej. +define+SDF_PATH=\"runs/RUN_X/final/sdf/.../shift_reg__nom_tt.sdf\"
    // Esto sirve para Icarus y para CVC (CVC no acepta $sdf_annotate con
    // primer argumento variable). Si no se define SDF_PATH, no se anota.
    // -----------------------------------------------------------
`ifdef SDF
  `ifdef SDF_PATH
    initial begin
        $display("[TB] Annotating SDF: %0s", `SDF_PATH);
        $sdf_annotate(`SDF_PATH, u_dut);
    end
  `else
    initial $display("[TB] WARNING: -DSDF set pero SDF_PATH macro no definida");
  `endif
`endif

    // -----------------------------------------------------------
    // Dump VCD
    // -----------------------------------------------------------
    initial begin
        $dumpfile("tb_shift_reg.vcd");
        $dumpvars(0, tb_shift_reg);
    end

    // -----------------------------------------------------------
    // Estimulos
    // -----------------------------------------------------------
    initial begin
        $display("========================================");
        $display(" tb_shift_reg  (WIDTH=%0d, T=%0dns)", WIDTH, CLK_PERIOD);
        $display("========================================");

        clk      = 1'b0;
        reset    = 1'b1;
        en       = 1'b0;
        d_in     = 1'b0;
        errors   = 0;
        expected = {WIDTH{1'b0}};
        pattern  = 16'b1010_1100_1001_0110;   // 16 bits de patron de prueba

        // Reset de 3 ciclos. El `#1` tras el `@(posedge clk)` evita la race
        // condition tipica entre la NBA del DUT y los cambios blocking del TB.
        repeat (3) @(posedge clk);
        #1;
        reset = 1'b0;
        en    = 1'b1;

        // ----- Test 1: shift 16 bits, comprobar q_out a cada ciclo
        for (i = 0; i < 16; i = i + 1) begin
            d_in = pattern[15 - i];
            @(posedge clk);
            #1;
            expected = {expected[WIDTH-2:0], pattern[15 - i]};
            if (q_out !== expected) begin
                $display("  FAIL @i=%0d: q_out=0x%0h, expected 0x%0h", i, q_out, expected);
                errors = errors + 1;
            end
        end

        // ----- Test 2: en=0 mantiene el valor
        en   = 1'b0;
        d_in = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        if (q_out !== expected) begin
            $display("  FAIL hold: q_out=0x%0h cambio con en=0 (expected 0x%0h)",
                     q_out, expected);
            errors = errors + 1;
        end

        // ----- Test 3: reset sincrono pone q_out a cero
        reset = 1'b1;
        @(posedge clk);
        #1;
        reset = 1'b0;
        if (q_out !== {WIDTH{1'b0}}) begin
            $display("  FAIL reset: q_out=0x%0h, expected 0x00", q_out);
            errors = errors + 1;
        end

        // ----- Resumen
        $display("----------------------------------------");
        if (errors == 0) $display(" ALL TESTS PASSED");
        else             $display(" %0d ERRORS", errors);
        $display("========================================");
        $finish;
    end

    // -----------------------------------------------------------
    // Timeout de seguridad
    // -----------------------------------------------------------
    initial begin
        #10_000;
        $display("[TB] TIMEOUT");
        $finish;
    end

endmodule
