module compute_top #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     reset,
    
    // --- Configuración Global ---
    input  wire [1:0]               compute_mode,   // 0:Parallel, 1:GAP, 2:Argmax
    input  wire                     is_parallel_ic, // 1: IC-Parallel (CONV2/3), 0: Broadcast (CONV1/FC)
    
    // --- Control CORE PARALELO ---
    input  wire                     core_req,
    input  wire                     core_acc_clear,
    input  wire                     core_process_out,
    input  wire                     core_frame_start, // Reset contadores pool entre canales
    input  wire                     core_relu_en,
    input  wire                     core_pool_en,
    input  wire [5:0]               core_img_width,
    
    // --- Control GAP/ARGMAX ---
    input  wire                     gap_req,
    input  wire                     argmax_req,
    
    // --- Datos de Entrada (32 bits) ---
    input  wire [31:0]              weights_word, 
    input  wire [31:0]              pixel_word,   // 4 Canales de entrada o 1 pixel duplicado
    
    // --- Metadatos de Cuantización (Core Paralelo) ---
    input  wire signed [ACC_WIDTH-1:0] bias_0, bias_1, bias_2, bias_3,
    input  wire signed [31:0]       mult_0, mult_1, mult_2, mult_3,
    input  wire [7:0]               shift_amt,
    input  wire [7:0]               zp_0, zp_1, zp_2, zp_3,
    
    // --- Salidas ---
    output reg [31:0]               data_out_32b,
    output reg                      valid_out,
    output wire [3:0]               pred_class,
    output wire                     classification_done
);

    // Señales Internas
    wire [31:0] core_out_data;
    wire        core_out_valid;
    wire [31:0] core_sum_tree_out; // IC-parallel sum (unused at top level)
    wire [7:0]  gap_out_data;
    wire        gap_out_valid;
    wire [3:0]  argmax_idx;
    wire        argmax_done;

    // ========================================================================
    // 1. NÚCLEO PARALELO (CONV / FC)
    // ========================================================================
    compute_core_parallel #(
        .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) u_core_parallel (
        .clk(clk), .reset(reset),
        .request(core_req), .acc_clear(core_acc_clear), .process_out(core_process_out),
        .frame_start(core_frame_start),
        .valid(core_out_valid),
        .relu_en(core_relu_en), .pool_en(core_pool_en), .is_parallel_ic(is_parallel_ic),
        .img_width(core_img_width),
        .weights_word(weights_word), .pixel_word(pixel_word),
        .bias_0(bias_0), .bias_1(bias_1), .bias_2(bias_2), .bias_3(bias_3),
        .mult_0(mult_0), .mult_1(mult_1), .mult_2(mult_2), .mult_3(mult_3),
        .shift_amt(shift_amt),
        .zp_0(zp_0), .zp_1(zp_1), .zp_2(zp_2), .zp_3(zp_3),
        .data_out_word(core_out_data),
        .sum_tree_out(core_sum_tree_out)
    );

    // ========================================================================
    // 2. GLOBAL AVERAGE POOLING (GAP)
    // ========================================================================
    gap_unit #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_gap (
        .clk(clk), .reset(reset),
        .request(gap_req),
        .valid(gap_out_valid),
        .data_in(pixel_word[7:0]), // GAP usa el byte bajo
        .data_out(gap_out_data)
    );

    // ========================================================================
    // 3. ARGMAX (CLASIFICACIÓN FINAL)
    // ========================================================================
    argmax_unit #(
        .DATA_WIDTH(DATA_WIDTH), .NUM_CLASSES(10)
    ) u_argmax (
        .clk(clk), .reset(reset),
        .request(argmax_req),
        .done(argmax_done),
        .data_in(pixel_word[7:0]), // Argmax usa el byte bajo
        .argmax_idx(argmax_idx),
        .max_value()
    );

    assign pred_class = argmax_idx;
    assign classification_done = argmax_done;

    // ========================================================================
    // 4. MUX DE SALIDA
    // ========================================================================
    always @(*) begin
        case (compute_mode)
            2'd0: begin // Modo Core Paralelo
                data_out_32b = core_out_data;
                valid_out    = core_out_valid;
            end
            2'd1: begin // Modo GAP
                data_out_32b = {24'd0, gap_out_data}; 
                valid_out    = gap_out_valid;
            end
            default: begin
                data_out_32b = 32'd0;
                valid_out    = 1'b0;
            end
        endcase
    end

endmodule