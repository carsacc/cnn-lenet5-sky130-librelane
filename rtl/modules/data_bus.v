module data_bus #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
) (
    input  wire        clk,
    input  wire        reset,

    // === MODO ===
    input  wire        is_ic_mode,         // 0=OC-parallel, 1=IC-parallel

    // === CANAL PIXEL (act_buffer/param_mem -> compute) ===
    input  wire [31:0] pixel_din,          // Palabra 32-bit de SRAM
    input  wire        pixel_load,         // Carga nueva palabra
    input  wire [1:0]  pixel_byte_sel,     // Seleccion de byte (OC mode)
    output wire [31:0] pixel_word,         // -> compute_top.pixel_word

    // === CANAL WEIGHT (param_mem -> compute) ===
    input  wire [31:0] weight_din,         // 4 pesos empaquetados
    input  wire        weight_load,
    output wire [31:0] weights_word,       // -> compute_top.weights_word

    // === CANAL BIAS (param_mem -> compute) ===
    input  wire [31:0] bias_din,           // Un bias de 32 bits
    input  wire        bias_load,
    input  wire [1:0]  bias_lane_sel,      // Lane 0-3
    output wire signed [ACC_WIDTH-1:0] bias_0, bias_1, bias_2, bias_3,

    // === CANAL MULT (param_mem -> compute) ===
    input  wire [31:0] mult_din,
    input  wire        mult_load,
    input  wire [1:0]  mult_lane_sel,
    output wire signed [31:0] mult_0, mult_1, mult_2, mult_3,

    // === CANAL SHIFT (param_mem -> compute) ===
    input  wire [7:0]  shift_din,
    input  wire        shift_load,
    output wire [7:0]  shift_amt,

    // === CANAL ZERO-POINT (param_mem -> compute) ===
    input  wire [31:0] zp_din,             // {zp3, zp2, zp1, zp0} empaquetados
    input  wire        zp_load,
    output wire [7:0]  zp_0, zp_1, zp_2, zp_3,

    // === CANAL RESULTADO (compute -> act_buffer) ===
    input  wire [31:0] result_din,         // compute_top.data_out_32b
    input  wire        result_valid,       // compute_top.valid_out
    input  wire [1:0]  result_byte_pos,    // Posicion de byte (IC mode, del FSM)
    output wire [31:0] result_dout,        // -> act_buffer.din
    output wire [3:0]  result_wmask        // -> act_buffer.wmask
);

    // ========================================================================
    // 1. PIXEL REGISTER
    // ========================================================================
    reg [31:0] pixel_reg;

    always @(posedge clk) begin
        if (reset)
            pixel_reg <= 32'b0;
        else if (pixel_load)
            pixel_reg <= pixel_din;
    end

    // OC mode: selected byte in [7:0], zero-extended to 32 bits (broadcast to 4 MACs)
    // IC mode: full word passthrough (4 IC pixels, one per MAC)
    wire [7:0] pixel_byte = pixel_reg[pixel_byte_sel*8 +: 8];
    assign pixel_word = is_ic_mode ? pixel_reg : {24'b0, pixel_byte};

    // ========================================================================
    // 2. WEIGHT REGISTER
    // ========================================================================
    reg [31:0] weight_reg;

    always @(posedge clk) begin
        if (reset)
            weight_reg <= 32'b0;
        else if (weight_load)
            weight_reg <= weight_din;
    end

    assign weights_word = weight_reg;

    // ========================================================================
    // 3. BIAS REGISTERS (4 x 32-bit, lane-selectable)
    // ========================================================================
    reg signed [ACC_WIDTH-1:0] bias_reg [0:3];

    always @(posedge clk) begin
        if (reset) begin
            bias_reg[0] <= {ACC_WIDTH{1'b0}};
            bias_reg[1] <= {ACC_WIDTH{1'b0}};
            bias_reg[2] <= {ACC_WIDTH{1'b0}};
            bias_reg[3] <= {ACC_WIDTH{1'b0}};
        end else if (bias_load)
            bias_reg[bias_lane_sel] <= $signed(bias_din);
    end

    assign bias_0 = bias_reg[0];
    assign bias_1 = bias_reg[1];
    assign bias_2 = bias_reg[2];
    assign bias_3 = bias_reg[3];

    // ========================================================================
    // 4. MULT REGISTERS (4 x 32-bit, lane-selectable)
    // ========================================================================
    reg signed [31:0] mult_reg [0:3];

    always @(posedge clk) begin
        if (reset) begin
            mult_reg[0] <= 32'b0;
            mult_reg[1] <= 32'b0;
            mult_reg[2] <= 32'b0;
            mult_reg[3] <= 32'b0;
        end else if (mult_load)
            mult_reg[mult_lane_sel] <= $signed(mult_din);
    end

    assign mult_0 = mult_reg[0];
    assign mult_1 = mult_reg[1];
    assign mult_2 = mult_reg[2];
    assign mult_3 = mult_reg[3];

    // ========================================================================
    // 5. SHIFT REGISTER (8-bit)
    // ========================================================================
    reg [7:0] shift_reg;

    always @(posedge clk) begin
        if (reset)
            shift_reg <= 8'b0;
        else if (shift_load)
            shift_reg <= shift_din;
    end

    assign shift_amt = shift_reg;

    // ========================================================================
    // 6. ZERO-POINT REGISTERS (4 x 8-bit from packed word)
    // ========================================================================
    reg [7:0] zp_reg [0:3];

    always @(posedge clk) begin
        if (reset) begin
            zp_reg[0] <= 8'b0;
            zp_reg[1] <= 8'b0;
            zp_reg[2] <= 8'b0;
            zp_reg[3] <= 8'b0;
        end else if (zp_load) begin
            zp_reg[0] <= zp_din[ 7: 0];
            zp_reg[1] <= zp_din[15: 8];
            zp_reg[2] <= zp_din[23:16];
            zp_reg[3] <= zp_din[31:24];
        end
    end

    assign zp_0 = zp_reg[0];
    assign zp_1 = zp_reg[1];
    assign zp_2 = zp_reg[2];
    assign zp_3 = zp_reg[3];

    // ========================================================================
    // 7. RESULT FORMATTER (combinational)
    // ========================================================================
    // OC mode: 4 bytes packed -> direct write, wmask=1111
    // IC mode: 1 byte in result_din[7:0] -> replicate to all positions,
    //          wmask selects target byte
    assign result_dout = is_ic_mode
        ? {4{result_din[7:0]}}
        : result_din;

    assign result_wmask = is_ic_mode
        ? (4'b0001 << result_byte_pos)
        : 4'b1111;

endmodule
