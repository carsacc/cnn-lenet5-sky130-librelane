// host_interface.v — OBI Slave for CNN Accelerator
// Memory map (byte addr, decoded from addr[14:0]):
//   0x0000-0x1FFF  param_memory   addr[14:13]=00
//   0x2000-0x3FFF  buf_A          addr[14:13]=01
//   0x4000-0x5FFF  buf_B          addr[14:13]=10
//   0x6000-0x600F  CSR registers  addr[14:13]=11
module host_interface (
    input  wire        clk,
    input  wire        reset,

    // OBI Slave Port
    input  wire        obi_req,
    output wire        obi_gnt,
    input  wire [31:0] obi_addr,
    input  wire        obi_we,
    input  wire [3:0]  obi_be,
    input  wire [31:0] obi_wdata,
    output reg         obi_rvalid,
    output reg  [31:0] obi_rdata,

    // Single output memory port (demuxed externally)
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

// --- FSM states ---
localparam S_IDLE     = 2'd0;
localparam S_CSR_RESP = 2'd1;
localparam S_MEM_WAIT = 2'd2;

// --- Target decode ---
localparam T_PARAM = 2'd0;
localparam T_BUFA  = 2'd1;
localparam T_BUFB  = 2'd2;
localparam T_CSR   = 2'd3;

reg [1:0] state;

// CSR registers
reg        csr_ctrl_start;
assign accel_start = csr_ctrl_start;

// Latched transaction fields (only addr/we needed for CSR read mux)
reg [14:0] lat_addr;
reg        lat_we;

// Address decode (combinatorial, from obi_addr for gnt)
wire [1:0] req_target = obi_addr[14:13];
wire       req_is_csr = (req_target == T_CSR);

// Grant: CSR always OK; memory only when not running inference
assign obi_gnt = obi_req && (state == S_IDLE) &&
                 (req_is_csr || !csr_ctrl_start);

// Latched CSR select
wire [1:0] lat_csr_sel  = lat_addr[3:2];

// CSR read mux (combinatorial)
reg [31:0] csr_rdata;
always @(*) begin
    case (lat_csr_sel)
        2'd0: csr_rdata = {31'd0, csr_ctrl_start};
        2'd1: csr_rdata = {30'd0, accel_classification_valid, accel_done};
        2'd2: csr_rdata = {28'd0, accel_pred_class};
        default: csr_rdata = 32'd0;
    endcase
end

// FSM
always @(posedge clk) begin
    if (reset) begin
        state          <= S_IDLE;
        obi_rvalid     <= 1'b0;
        obi_rdata      <= 32'd0;
        mem_request    <= 1'b0;
        mem_we         <= 1'b0;
        mem_addr       <= 11'd0;
        mem_wdata      <= 32'd0;
        mem_wmask      <= 4'd0;
        mem_target     <= 2'd0;
        csr_ctrl_start <= 1'b0;
        lat_addr       <= 15'd0;
        lat_we         <= 1'b0;
    end else begin
        case (state)
        S_IDLE: begin
            obi_rvalid <= 1'b0;
            mem_request <= 1'b0;
            if (obi_req && obi_gnt) begin
                // Latch transaction
                lat_addr  <= obi_addr[14:0];
                lat_we    <= obi_we;
                if (req_is_csr) begin
                    // CSR write happens immediately
                    if (obi_we && obi_addr[3:2] == 2'd0)
                        csr_ctrl_start <= obi_wdata[0];
                    state <= S_CSR_RESP;
                end else begin
                    // Memory access
                    mem_addr    <= obi_addr[12:2];
                    mem_wdata   <= obi_wdata;
                    mem_target  <= obi_addr[14:13];
                    mem_we      <= obi_we;
                    mem_request <= 1'b1;
                    // wmask: param_memory ignores it (always 4'b1111), buffers use obi_be
                    if (obi_addr[14:13] == T_PARAM)
                        mem_wmask <= 4'b1111;
                    else
                        mem_wmask <= obi_be;
                    state <= S_MEM_WAIT;
                end
            end
        end

        S_CSR_RESP: begin
            obi_rvalid <= 1'b1;
            obi_rdata  <= lat_we ? 32'd0 : csr_rdata;
            state      <= S_IDLE;
        end

        S_MEM_WAIT: begin
            if (mem_valid) begin
                obi_rvalid  <= 1'b1;
                obi_rdata   <= mem_rdata;
                mem_request <= 1'b0;
                state       <= S_IDLE;
            end
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
