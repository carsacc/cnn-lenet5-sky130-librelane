// activation_buffer.v — Single-SRAM activation buffer for feature maps
// Always uses sky130_sram_1rw1r_32x1024_8 (1024 words × 32 bits)
// Handshake: Read=3 cycles, Write=2 cycles
module activation_buffer #(
    parameter DATA_WIDTH     = 32,
    parameter ADDR_WIDTH     = 11,   // external address bus width
    parameter SRAM_ADDR_WIDTH = 10   // 10=1024 words, 9=512 words
) (
    input clk,
    input reset,
    input [ADDR_WIDTH-1:0] addr,
    input [DATA_WIDTH-1:0] din,
    input [3:0] wmask,
    input read_writeb,        // 1: Read, 0: Write
    input request,
    output reg [DATA_WIDTH-1:0] dout,
    output reg valid
);

// --- Control signals ---
wire csb0 = ~request;
wire web0 = read_writeb;       // 0=write, 1=read
wire [DATA_WIDTH-1:0] dout0;
wire [DATA_WIDTH-1:0] dout1;  // unused, must be connected

// --- SRAM instance ---
sky130_sram_1rw1r_32x1024_8 sram (
    .clk0(clk), .csb0(csb0), .web0(web0), .wmask0(wmask),
    .addr0(addr[SRAM_ADDR_WIDTH-1:0]), .din0(din), .dout0(dout0),
    .clk1(clk), .csb1(1'b1), .addr1({SRAM_ADDR_WIDTH{1'b0}}), .dout1(dout1)
);

// --- Handshake controller ---
reg [1:0] delay;

always @(posedge clk) begin
    if (reset) begin
        dout  <= 32'hDEADBEEF;
        valid <= 1'b0;
        delay <= 0;
    end else begin
        if (request) begin
            if (read_writeb) begin          // READ
                if (delay == 2'd2) begin
                    dout  <= dout0;
                    valid <= 1;
                end else begin
                    delay <= delay + 2'd1;
                end
            end else begin                  // WRITE
                if (delay == 2'd1) begin
                    dout  <= 32'hDEADBEEF;
                    valid <= 1;
                end else begin
                    delay <= delay + 2'd1;
                end
            end
        end else begin
            valid <= 0;
            delay <= 0;
        end
    end
end

endmodule
