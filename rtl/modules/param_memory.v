// param_memory.v — Parameter storage using single sky130_sram_1rw1r_32x2048_8
// Stores all CNN weights, biases, multipliers, zero-points
// Handshake: Read=3 cycles, Write=2 cycles (same as before)
module param_memory #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 11   // 2048 words
) (
    input clk,
    input reset,
    input [ADDR_WIDTH-1:0] addr,
    input [DATA_WIDTH-1:0] din,
    input read_writeb, // 1: Read, 0: Write
    input request,
    output reg [DATA_WIDTH-1:0] dout,
    output reg valid
);

// --- Control signals ---
wire csb0 = ~request;
wire web0 = read_writeb;       // 0=write, 1=read
wire [3:0] wmask0 = 4'b1111;  // always full-word writes
wire [DATA_WIDTH-1:0] dout0;
wire [DATA_WIDTH-1:0] dout1;  // unused, must be connected

sky130_sram_1rw1r_32x2048_8 sram (
    .clk0(clk), .csb0(csb0), .web0(web0), .wmask0(wmask0),
    .addr0(addr), .din0(din), .dout0(dout0),
    .clk1(clk), .csb1(1'b1), .addr1({ADDR_WIDTH{1'b0}}), .dout1(dout1)
);

// --- Handshake controller ---
reg [1:0] delay;

always @(posedge clk) begin
    if (reset) begin
        dout <= 32'hDEADBEEF;
        valid <= 1'b0;
        delay <= 0;
    end else begin
        if(request)begin
            if(read_writeb)begin
                if(delay == 2'd2) begin
                    dout <= dout0;
                    valid <= 1;
                end else begin
                    delay <= delay + 2'd1;
                end
            end
            else begin
                if(delay == 2'd1) begin
                    dout <= 32'hDEADBEEF;
                    valid <= 1;
                end else begin
                    delay <= delay + 2'd1;
                end
            end
        end
        else begin
                valid <= 0;
                delay <= 0;
        end
    end
end
endmodule
