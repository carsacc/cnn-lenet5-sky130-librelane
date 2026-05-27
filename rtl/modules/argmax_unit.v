module argmax_unit #(
    parameter integer DATA_WIDTH = 8,
    parameter integer NUM_CLASSES = 10,
    parameter integer IDX_WIDTH = 4 // clog2(10)
) (
    input  wire                     clk,
    input  wire                     reset,
    
    // Handshake
    input  wire                     request,    // 1: Nuevo logit de entrada
    output reg                      done,       // 1: Se procesaron todas las clases
    
    // Entrada
    input  wire signed [DATA_WIDTH-1:0] data_in,
    
    // Salida Final
    output reg [IDX_WIDTH-1:0]      argmax_idx,
    output reg signed [DATA_WIDTH-1:0] max_value
);

    reg [3:0] count;
    reg [3:0] best_idx;
    reg signed [DATA_WIDTH-1:0] current_max;

    always @(posedge clk) begin
        if (reset) begin
            count <= 4'd0;
            best_idx <= 4'd0;
            current_max <= -8'sd128; // Mínimo valor posible
            done <= 1'b0;
            argmax_idx <= 4'd0;
            max_value <= -8'sd128;
        end else begin
            done <= 1'b0;
            
            if (request) begin
                // Comparar si el nuevo dato es mayor que el máximo actual
                // En el primer elemento (count=0), siempre actualizamos
                if (count == 4'd0 || data_in > current_max) begin
                    current_max <= data_in;
                    best_idx <= count;
                end

                // Gestión de finalización
                if (count == NUM_CLASSES - 1) begin
                    // Hemos terminado las 10 clases
                    argmax_idx <= (data_in > current_max) ? count[IDX_WIDTH-1:0] : best_idx[IDX_WIDTH-1:0];
                    max_value <= (data_in > current_max) ? data_in : current_max;
                    done <= 1'b1;
                    
                    // Reset interno para la siguiente imagen
                    count <= 4'd0;
                    current_max <= -8'sd128;
                end else begin
                    count <= count + 4'd1;
                end
            end
        end
    end

endmodule
