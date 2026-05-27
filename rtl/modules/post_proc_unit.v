module post_proc_unit #(
    parameter integer ACC_WIDTH = 32,
    parameter integer DATA_WIDTH = 8,
    parameter integer MAX_IMG_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     reset,
    
    // Handshake
    input  wire                     request,
    input  wire                     frame_start, // Reset de contadores de pooling entre canales
    output reg                      valid,
    
    // Configuración
    input  wire                     relu_en,
    input  wire                     pool_en,
    input  wire [5:0]               img_width,
    
    // Datos
    input  wire signed [ACC_WIDTH-1:0]  data_in,
    input  wire signed [31:0]       multiplier,
    input  wire [7:0]               shift_amt,
    input  wire [7:0]               offset_zp,
    
    output reg  signed [DATA_WIDTH-1:0] data_out
);

    // --- Etapa 1: Requantización y ReLU (Combinacional) ---
    wire signed [63:0] full_mult = $signed(data_in) * $signed(multiplier);
    wire signed [63:0] scaled_data = full_mult >>> shift_amt;
    
    reg signed [31:0] with_zp;
    reg signed [DATA_WIDTH-1:0] post_requant;

    always @(*) begin
        with_zp = scaled_data[31:0] + $signed({24'd0, offset_zp});
        
        if (with_zp > 32'sd127) post_requant = 8'sd127;
        else if (with_zp < -32'sd128) post_requant = -8'sd128;
        else post_requant = with_zp[7:0];

        if (relu_en && post_requant < 8'sd0) post_requant = 8'sd0;
    end

    // --- Etapa 2: Lógica de Max-Pooling 2x2 ---
    reg [5:0] col_cnt;
    reg [5:0] row_cnt;
    reg signed [DATA_WIDTH-1:0] line_buffer [0:(MAX_IMG_WIDTH/2)-1];
    reg signed [DATA_WIDTH-1:0] temp_max;

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            valid <= 1'b0;
            data_out <= 8'd0;
            col_cnt <= 6'd0;
            row_cnt <= 6'd0;
            temp_max <= -8'sd128;
            for (i = 0; i < MAX_IMG_WIDTH/2; i = i + 1) line_buffer[i] <= -8'sd128;
        end else if (frame_start) begin
            // Reset de estado espacial entre canales de salida (ej. CONV2: 11 filas = impar)
            row_cnt  <= 6'd0;
            col_cnt  <= 6'd0;
            temp_max <= -8'sd128;
            valid    <= 1'b0;
        end else begin
            valid <= 1'b0;

            if (request) begin
                if (!pool_en) begin
                    data_out <= post_requant;
                    valid <= 1'b1;
                end else begin
                    // Lógica de Max-Pool
                    if (row_cnt[0] == 1'b0) begin
                        if (col_cnt[0] == 1'b0) temp_max <= post_requant;
                        else line_buffer[col_cnt[4:1]] <= (post_requant > temp_max) ? post_requant : temp_max;
                    end else begin
                        if (col_cnt[0] == 1'b0) temp_max <= (post_requant > line_buffer[col_cnt[4:1]]) ? post_requant : line_buffer[col_cnt[4:1]];
                        else begin
                            data_out <= (post_requant > temp_max) ? post_requant : temp_max;
                            valid <= 1'b1;
                        end
                    end

                    // Contadores (Solo avanzan en modo pool)
                    if (col_cnt == img_width - 1) begin
                        col_cnt <= 6'd0;
                        row_cnt <= row_cnt + 1'b1;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                    end
                end
            end
        end
    end

endmodule