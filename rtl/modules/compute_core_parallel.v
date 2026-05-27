module compute_core_parallel #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     reset,
    
    // --- Control ---
    input  wire                     request,
    input  wire                     acc_clear,
    input  wire                     process_out,
    input  wire                     frame_start, // Reset de contadores de pooling entre canales
    output wire                     valid,
    
    // --- Configuración ---
    input  wire                     relu_en,
    input  wire                     pool_en,
    input  wire                     is_parallel_ic,
    input  wire [5:0]               img_width,
    
    // --- Datos ---
    input  wire [31:0]              weights_word,
    input  wire [31:0]              pixel_word,
    
    // --- Metadatos ---
    input  wire signed [ACC_WIDTH-1:0] bias_0, bias_1, bias_2, bias_3,
    input  wire signed [31:0]       mult_0, mult_1, mult_2, mult_3,
    input  wire [7:0]               shift_amt,
    input  wire [7:0]               zp_0, zp_1, zp_2, zp_3,
    
    output wire [31:0]              data_out_word,

    // --- DEBUG JERARQUICO ---
    // (No se necesitan puertos dbg_ si usamos rutas completas en el TB)
    output wire [ACC_WIDTH-1:0] sum_tree_out
);

    wire [ACC_WIDTH-1:0] mac_acc_bus [0:3];
    wire [3:0]           mac_valid_raw;
    wire [3:0]           pp_valid_bus;
    wire [DATA_WIDTH-1:0] pp_out_bytes [0:3];
    
    reg signed [ACC_WIDTH-1:0] sum_tree_reg;
    assign sum_tree_out = sum_tree_reg;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_compute_blocks
            
            wire [7:0] px_in = (is_parallel_ic) ? pixel_word[8*i +: 8] : pixel_word[7:0];
            
            // En modo IC-Parallel (is_parallel_ic=1):
            //   - MAC0 porta el bias del canal de salida; MAC1-3 acumulan desde 0.
            //   - Los 4 post_proc reciben sum_tree_out con los mismos metadatos (lane 0).
            //   - data_out_word[7:0] es la salida valida; bytes 1-3 son copias identicas.
            // En modo OC-Parallel (is_parallel_ic=0):
            //   - Cada lane es independiente con sus propios bias/mult/zp.
            wire signed [ACC_WIDTH-1:0] mac_bias_in;
            wire signed [31:0]          pp_mult_in;
            wire [7:0]                  pp_zp_in;

            assign mac_bias_in = (i==0) ? bias_0 :
                                 is_parallel_ic ? {ACC_WIDTH{1'b0}} :
                                 (i==1) ? bias_1 : (i==2) ? bias_2 : bias_3;

            assign pp_mult_in = is_parallel_ic ? mult_0 :
                                (i==0) ? mult_0 : (i==1) ? mult_1 :
                                (i==2) ? mult_2 : mult_3;

            assign pp_zp_in = is_parallel_ic ? zp_0 :
                              (i==0) ? zp_0 : (i==1) ? zp_1 :
                              (i==2) ? zp_2 : zp_3;

            mac_unit #(
                .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
            ) u_mac (
                .clk(clk), .reset(reset),
                .valid_in(request), .acc_clear(acc_clear),
                .bias_in(mac_bias_in),
                .pixel_in(px_in),
                .weight_in(weights_word[8*i +: 8]),
                .acc_out(mac_acc_bus[i]),
                .valid_out(mac_valid_raw[i])
            );

            wire [ACC_WIDTH-1:0] pp_in_data = (is_parallel_ic) ? sum_tree_out : mac_acc_bus[i];

            post_proc_unit #(
                .ACC_WIDTH(ACC_WIDTH), .DATA_WIDTH(DATA_WIDTH)
            ) u_post_proc (
                .clk(clk), .reset(reset),
                .request(process_out),
                .frame_start(frame_start),
                .valid(pp_valid_bus[i]),
                .relu_en(relu_en), .pool_en(pool_en), .img_width(img_width),
                .data_in(pp_in_data),
                .multiplier(pp_mult_in),
                .shift_amt(shift_amt),
                .offset_zp(pp_zp_in),
                .data_out(pp_out_bytes[i])
            );
        end
    endgenerate

    always @(*) begin
        if (is_parallel_ic)
            sum_tree_reg = mac_acc_bus[0] + mac_acc_bus[1] + mac_acc_bus[2] + mac_acc_bus[3];
        else
            sum_tree_reg = mac_acc_bus[0];
    end

    assign data_out_word = {pp_out_bytes[3], pp_out_bytes[2], pp_out_bytes[1], pp_out_bytes[0]};
    assign valid = pp_valid_bus[0];

endmodule
