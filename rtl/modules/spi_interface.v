// spi_interface.v — SPI Slave Interface for CNN Accelerator
// Drop-in alternative to host_interface.v for standalone chip (no SoC).
//
// SPI Mode 0 (CPOL=0, CPHA=0), MSB first, 56 SCLK edges per transaction.
//
// Frame format (7 bytes, both read and write):
//   Byte 0:    CMD      — bit[7] = W/R (1=write, 0=read), bits[6:0] reserved
//   Byte 1:    ADDR_H   — address[15:8]  (bit 15 ignored by slave)
//   Byte 2:    ADDR_L   — address[7:0]
//   Bytes 3-6: DATA     — write: MOSI wdata; read: MISO rdata (pipeline, see below)
//
// Read protocol (pipeline):
//   During the DATA phase, MISO outputs the result from the PREVIOUS read.
//   After the full 56 bits are received, the slave fetches data for the
//   current address and stores it for the NEXT transaction's MISO.
//   → First read to a new address returns stale/zero — master discards it.
//   → Subsequent reads are pipelined (each returns the prior read's data).
//
// Memory map (identical to host_interface):
//   0x0000-0x1FFF  param_memory   addr[14:13]=00
//   0x2000-0x3FFF  buf_A          addr[14:13]=01
//   0x4000-0x5FFF  buf_B          addr[14:13]=10
//   0x6000-0x600F  CSR registers  addr[14:13]=11
//     CSR[0] CTRL:   bit 0 = start (R/W)
//     CSR[1] STATUS: bit 0 = done, bit 1 = classification_valid (RO)
//     CSR[2] RESULT: bits [3:0] = pred_class (RO)
//     CSR[3] reserved (reads 0)
//
// Max SPI clock: clk_freq / 8  (e.g. 1.87 MHz @ 15 MHz clk)
//   Limited by 2-FF synchronizer + edge-detect latency on MISO output.
//   Master must leave ≥ 300 ns between CS high and next CS low (memory
//   write/read latency).

module spi_interface (
    input  wire        clk,
    input  wire        reset,

    // SPI Slave Port
    input  wire        spi_sclk,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    output wire        spi_miso,

    // Single output memory port (same as host_interface)
    output reg  [10:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wmask,
    output reg         mem_we,
    output reg         mem_request,
    output reg  [1:0]  mem_target,    // 00=param, 01=buf_a, 10=buf_b
    input  wire [31:0] mem_rdata,
    input  wire        mem_valid,

    // Accelerator control
    output wire        accel_start,
    input  wire        accel_done,
    input  wire [3:0]  accel_pred_class,
    input  wire        accel_classification_valid
);

// ================================================================
// 2-FF synchronizers  (SPI pins → clk domain)
// ================================================================
reg [1:0] sclk_sync, cs_n_sync, mosi_sync;

always @(posedge clk) begin
    if (reset) begin
        sclk_sync <= 2'b00;
        cs_n_sync <= 2'b11;
        mosi_sync <= 2'b00;
    end else begin
        sclk_sync <= {sclk_sync[0], spi_sclk};
        cs_n_sync <= {cs_n_sync[0], spi_cs_n};
        mosi_sync <= {mosi_sync[0], spi_mosi};
    end
end

wire sclk_s = sclk_sync[1];
wire cs_n_s = cs_n_sync[1];
wire mosi_s = mosi_sync[1];

// ================================================================
// Edge detection  (one extra register stage)
// ================================================================
reg sclk_d, cs_n_d;

always @(posedge clk) begin
    if (reset) begin
        sclk_d <= 1'b0;
        cs_n_d <= 1'b1;
    end else begin
        sclk_d <= sclk_s;
        cs_n_d <= cs_n_s;
    end
end

wire sclk_rise = sclk_s & ~sclk_d;
wire sclk_fall = ~sclk_s & sclk_d;
wire cs_fall   = ~cs_n_s & cs_n_d;   // CS asserted  → transaction start

// ================================================================
// CSR register
// ================================================================
reg csr_ctrl_start;
assign accel_start = csr_ctrl_start;

// ================================================================
// Shift registers & bit counter
// ================================================================
reg [55:0] mosi_shift;   // 56 bits from MOSI  (CMD+ADDR+DATA)
reg [31:0] miso_shift;   // 32 bits to MISO    (pipeline read data)
reg [5:0]  bit_cnt;      // counts received rising edges (0-55)

// ================================================================
// Pipeline read-data register
// Holds the result of the most recent read.  Preloaded into miso_shift
// on the next CS assertion so the master can clock it out.
// ================================================================
reg [31:0] read_data;

// MISO output — directly from a register, active only when CS is low
reg miso_out;
assign spi_miso = cs_n_s ? 1'b0 : miso_out;

// ================================================================
// FSM
// ================================================================
localparam S_IDLE     = 2'd0;   // wait for CS↓
localparam S_SHIFT    = 2'd1;   // shifting 56 bits
localparam S_PROCESS  = 2'd2;   // decode + execute
localparam S_MEM_WAIT = 2'd3;   // wait for mem_valid

reg [1:0] state;

// ================================================================
// Decoded fields  (valid in S_PROCESS, after 56 shifts)
//   mosi_shift[55:48] = CMD[7:0]
//   mosi_shift[47:40] = ADDR_H[7:0]
//   mosi_shift[39:32] = ADDR_L[7:0]
//   mosi_shift[31:0]  = DATA[31:0]
// ================================================================
wire        dec_write     = mosi_shift[55];           // CMD bit 7
wire [15:0] dec_byte_addr = mosi_shift[47:32];        // {ADDR_H, ADDR_L}
wire [1:0]  dec_target    = dec_byte_addr[14:13];
wire        dec_is_csr    = (dec_target == 2'd3);
wire [10:0] dec_word_addr = dec_byte_addr[12:2];      // byte→word
wire [1:0]  dec_csr_sel   = dec_byte_addr[3:2];
wire [31:0] dec_wdata     = mosi_shift[31:0];

// CSR read mux (combinatorial)
reg [31:0] csr_rdata;
always @(*) begin
    case (dec_csr_sel)
        2'd0:    csr_rdata = {31'd0, csr_ctrl_start};
        2'd1:    csr_rdata = {30'd0, accel_classification_valid, accel_done};
        2'd2:    csr_rdata = {28'd0, accel_pred_class};
        default: csr_rdata = 32'd0;
    endcase
end

// ================================================================
// Main FSM
// ================================================================
always @(posedge clk) begin
    if (reset) begin
        state          <= S_IDLE;
        mosi_shift     <= 56'd0;
        miso_shift     <= 32'd0;
        bit_cnt        <= 6'd0;
        miso_out       <= 1'b0;
        read_data      <= 32'd0;
        mem_request    <= 1'b0;
        mem_we         <= 1'b0;
        mem_addr       <= 11'd0;
        mem_wdata      <= 32'd0;
        mem_wmask      <= 4'd0;
        mem_target     <= 2'd0;
        csr_ctrl_start <= 1'b0;
    end else begin

        case (state)
        // ---------------------------------------------------
        S_IDLE: begin
            mem_request <= 1'b0;
            miso_out    <= 1'b0;
            if (cs_fall) begin
                mosi_shift <= 56'd0;
                miso_shift <= read_data;      // preload previous result
                bit_cnt    <= 6'd0;
                state      <= S_SHIFT;
            end
        end

        // ---------------------------------------------------
        S_SHIFT: begin
            if (cs_n_s) begin
                // CS de-asserted mid-transaction → abort
                state <= S_IDLE;
            end else begin
                // Rising SCLK: sample MOSI
                if (sclk_rise) begin
                    mosi_shift <= {mosi_shift[54:0], mosi_s};
                    bit_cnt    <= bit_cnt + 6'd1;
                    if (bit_cnt == 6'd55)       // 56th edge → done
                        state <= S_PROCESS;
                end
                // Falling SCLK: drive MISO during data phase (bits 24-55)
                //   bit_cnt is already incremented for the current SCLK cycle
                //   (non-blocking took effect on the previous clk edge).
                if (sclk_fall && bit_cnt >= 6'd24) begin
                    miso_out   <= miso_shift[31];
                    miso_shift <= {miso_shift[30:0], 1'b0};
                end
            end
        end

        // ---------------------------------------------------
        S_PROCESS: begin
            if (dec_write) begin
                // ---- WRITE ----
                if (dec_is_csr) begin
                    // Only CTRL (sel=0) is writable
                    if (dec_csr_sel == 2'd0)
                        csr_ctrl_start <= dec_wdata[0];
                    state <= S_IDLE;
                end else if (csr_ctrl_start) begin
                    // Memory blocked during inference — silently ignore
                    state <= S_IDLE;
                end else begin
                    mem_addr    <= dec_word_addr;
                    mem_wdata   <= dec_wdata;
                    mem_target  <= dec_target;
                    mem_we      <= 1'b1;
                    mem_request <= 1'b1;
                    mem_wmask   <= 4'b1111;     // SPI always writes full words
                    state       <= S_MEM_WAIT;
                end
            end else begin
                // ---- READ  (pipeline: fetch for next MISO) ----
                if (dec_is_csr) begin
                    read_data <= csr_rdata;     // immediate
                    state     <= S_IDLE;
                end else if (csr_ctrl_start) begin
                    read_data <= 32'hDEAD_DEAD; // blocked
                    state     <= S_IDLE;
                end else begin
                    mem_addr    <= dec_word_addr;
                    mem_target  <= dec_target;
                    mem_we      <= 1'b0;
                    mem_request <= 1'b1;
                    mem_wmask   <= 4'd0;
                    state       <= S_MEM_WAIT;
                end
            end
        end

        // ---------------------------------------------------
        S_MEM_WAIT: begin
            if (mem_valid) begin
                mem_request <= 1'b0;
                if (!mem_we)
                    read_data <= mem_rdata;     // store for next MISO
                state <= S_IDLE;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
