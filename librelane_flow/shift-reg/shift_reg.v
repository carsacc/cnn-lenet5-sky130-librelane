// shift_reg.v
// Registro de desplazamiento serie-paralelo de WIDTH bits.
// Disenado como caso minimo para probar la cadena de simulacion con
// anotacion SDF (Icarus, CVC). Reset sincrono y enable de avance.
module shift_reg #(
    parameter integer WIDTH = 8
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             en,
    input  wire             d_in,
    output wire [WIDTH-1:0] q_out
);
    reg [WIDTH-1:0] q;

    always @(posedge clk) begin
        if (reset) begin
            q <= {WIDTH{1'b0}};
        end else if (en) begin
            q <= {q[WIDTH-2:0], d_in};
        end
    end

    assign q_out = q;
endmodule
