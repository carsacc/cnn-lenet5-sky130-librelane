module gap_unit #(
    parameter integer DATA_WIDTH = 8,
    parameter integer MSG_WIDTH = 16 
) (
    input  wire                     clk,
    input  wire                     reset,
    
    // Handshake
    input  wire                     request,
    output reg                      valid,
    
    // Entrada
    input  wire signed [DATA_WIDTH-1:0] data_in,
    
    // Salida
    output reg  signed [DATA_WIDTH-1:0] data_out
);

    reg [3:0] count; 
    reg signed [MSG_WIDTH-1:0] accumulator;

    localparam signed [15:0] INV_9_Q16 = 16'h1C72;

    // Lógica de cálculo (combinacional sobre registros actuales)
    wire signed [MSG_WIDTH-1:0] current_sum = accumulator + data_in;
    wire signed [31:0] current_prod = current_sum * INV_9_Q16;
    wire signed [DATA_WIDTH-1:0] current_avg = current_prod[23:16];

    always @(posedge clk) begin
        if (reset) begin
            count <= 4'd0;
            accumulator <= 16'sd0;
            valid <= 1'b0;
            data_out <= 8'sd0;
        end else begin
            valid <= 1'b0;
            
            if (request) begin
                if (count == 4'd8) begin
                    // 9no píxel recibido: Emitir promedio
                    data_out <= current_avg;
                    valid <= 1'b1;
                    
                    // Reset para el siguiente canal
                    count <= 4'd0;
                    accumulator <= 16'sd0;
                end else begin
                    accumulator <= current_sum;
                    count <= count + 4'd1;
                end
            end
        end
    end

endmodule