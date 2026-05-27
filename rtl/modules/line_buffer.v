// line_buffer.v — Circular 3-row window cache for 3×3 convolution
// Stores 3 rows of 32-bit words with zero-latency combinational read.
// A circular pointer (row_base) maps logical rows (0=top,1=mid,2=bot)
// to physical storage arrays. row_advance rotates the window down.

module line_buffer #(
    parameter integer MAX_WORDS_PER_ROW = 28  // Max 32-bit words per row
) (
    input  wire        clk,
    input  wire        reset,

    // --- Write Port (FSM loads rows from activation buffer) ---
    input  wire [31:0] wr_data,
    input  wire        wr_en,
    input  wire [1:0]  wr_row,       // Logical row: 0=top, 1=mid, 2=bot
    input  wire [4:0]  wr_addr,      // Word address within row (0..MAX_WORDS_PER_ROW-1)

    // --- Read Port (combinational, zero-latency) ---
    input  wire [1:0]  rd_row,       // Logical row: 0=top, 1=mid, 2=bot
    input  wire [4:0]  rd_addr,      // Word address within row
    output wire [31:0] rd_data,

    // --- Row Management ---
    input  wire        row_advance   // Rotate window down: old top discarded, new bottom writable
);

    // ---------------------------------------------------------------
    // Storage: 3 separate arrays (Icarus-friendly)
    // ---------------------------------------------------------------
    reg [31:0] row_buf_0 [0:MAX_WORDS_PER_ROW-1];
    reg [31:0] row_buf_1 [0:MAX_WORDS_PER_ROW-1];
    reg [31:0] row_buf_2 [0:MAX_WORDS_PER_ROW-1];

    // ---------------------------------------------------------------
    // Circular pointer: physical row that corresponds to logical row 0
    // ---------------------------------------------------------------
    reg [1:0] row_base;

    always @(posedge clk) begin
        if (reset)
            row_base <= 2'd0;
        else if (row_advance)
            row_base <= (row_base == 2'd2) ? 2'd0 : row_base + 2'd1;
    end

    // ---------------------------------------------------------------
    // Logical → Physical row mapping (modulo-3 addition)
    // Need 3 bits for sum since max value is 2+2=4
    // ---------------------------------------------------------------
    wire [2:0] sum_wr = {1'b0, row_base} + {1'b0, wr_row};
    wire [1:0] phy_wr = (sum_wr >= 3'd3) ? (sum_wr[1:0] - 2'd3) : sum_wr[1:0];

    wire [2:0] sum_rd = {1'b0, row_base} + {1'b0, rd_row};
    wire [1:0] phy_rd = (sum_rd >= 3'd3) ? (sum_rd[1:0] - 2'd3) : sum_rd[1:0];

    // ---------------------------------------------------------------
    // Synchronous write (one row selected by phy_wr)
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (wr_en) begin
            case (phy_wr)
                2'd0: row_buf_0[wr_addr] <= wr_data;
                2'd1: row_buf_1[wr_addr] <= wr_data;
                2'd2: row_buf_2[wr_addr] <= wr_data;
                default: ; // unreachable
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Combinational read (zero-latency)
    // ---------------------------------------------------------------
    reg [31:0] rd_data_r;

    always @(*) begin
        case (phy_rd)
            2'd0:    rd_data_r = row_buf_0[rd_addr];
            2'd1:    rd_data_r = row_buf_1[rd_addr];
            2'd2:    rd_data_r = row_buf_2[rd_addr];
            default: rd_data_r = 32'b0;
        endcase
    end

    assign rd_data = rd_data_r;

endmodule
