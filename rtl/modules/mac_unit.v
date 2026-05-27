module mac_unit #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     reset,      // CAMBIADO A SÍNCRONO
    input  wire                     valid_in,
    input  wire                     acc_clear,
    input  wire signed [ACC_WIDTH-1:0] bias_in,
    input  wire signed [DATA_WIDTH-1:0] pixel_in,
    input  wire signed [DATA_WIDTH-1:0] weight_in,
    output reg  signed [ACC_WIDTH-1:0] acc_out,
    output reg                      valid_out
);

    reg signed [ACC_WIDTH-1:0] acc_reg;
    wire signed [ACC_WIDTH-1:0] mult_result;
    assign mult_result = $signed(pixel_in) * $signed(weight_in);

    always @(posedge clk) begin
        if (reset) begin
            acc_reg   <= {ACC_WIDTH{1'b0}};
            acc_out   <= {ACC_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else begin
            if (valid_in) begin
                if (acc_clear) begin
                    acc_reg <= bias_in + mult_result;
                    acc_out <= bias_in + mult_result;
                end else begin
                    acc_reg <= acc_reg + mult_result;
                    acc_out <= acc_reg + mult_result;
                end
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end

endmodule