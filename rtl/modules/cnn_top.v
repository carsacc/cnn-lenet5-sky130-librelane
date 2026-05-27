// cnn_top.v — Top-Level CNN Accelerator
// Interface selection:
//   default        → OBI Slave  (host_interface.v)  — for SoC integration
//   -DUSE_SPI_INTERFACE → SPI Slave  (spi_interface.v)  — for standalone chip
//
// Memory arbitration: accel_start=1 → sequencer owns memories,
//                     accel_start=0 → host/SPI owns memories

module cnn_top (
    input  wire        clk,
    input  wire        reset,
`ifdef USE_SPI_INTERFACE
    // SPI Slave Port
    input  wire        spi_sclk,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    output wire        spi_miso
`else
    // OBI Slave Port (default)
    input  wire        obi_req,
    output wire        obi_gnt,
    input  wire [31:0] obi_addr,
    input  wire        obi_we,
    input  wire [3:0]  obi_be,
    input  wire [31:0] obi_wdata,
    output wire        obi_rvalid,
    output wire [31:0] obi_rdata
`endif
);

    // ================================================================
    // host/SPI interface ↔ memory bus wires
    // ================================================================
    wire [10:0] hi_mem_addr;
    wire [31:0] hi_mem_wdata;
    wire [3:0]  hi_mem_wmask;
    wire        hi_mem_we;
    wire        hi_mem_request;
    wire [1:0]  hi_mem_target;
    reg  [31:0] hi_mem_rdata;
    reg         hi_mem_valid;

    wire        accel_start;
    wire        accel_done;
    wire [3:0]  accel_pred_class;
    wire        accel_cv;

    // ================================================================
    // layer_sequencer ↔ unified buffer wires
    // ================================================================
    wire [10:0] seq_ub_addr, seq_pm_addr;
    wire [31:0] seq_ub_din;
    wire [3:0]  seq_ub_wmask;
    wire        seq_ub_request, seq_pm_request;
    wire        seq_ub_rwb, seq_pm_rwb;
    wire [31:0] seq_ub_dout, seq_pm_dout;
    wire        seq_ub_valid, seq_pm_valid;

    // ================================================================
    // Memory port mux wires (after arbitration)
    // ================================================================
    wire [10:0] pm_addr, ub_addr;
    wire [31:0] pm_din, ub_din;
    wire [3:0]  ub_wmask;
    wire        pm_rwb, ub_rwb;
    wire        pm_req, ub_req;
    wire [31:0] pm_dout, ub_dout;
    wire        pm_valid, ub_valid;

    // ================================================================
    // Memory arbitration mux
    // accel_start=1 → sequencer, accel_start=0 → host
    // ================================================================

    // --- param_memory ---
    assign pm_addr = accel_start ? seq_pm_addr    : hi_mem_addr;
    assign pm_din  = accel_start ? 32'd0          : hi_mem_wdata;
    assign pm_rwb  = accel_start ? seq_pm_rwb     : ~hi_mem_we;
    assign pm_req  = accel_start ? seq_pm_request : (hi_mem_request && hi_mem_target == 2'd0);

    // --- unified activation buffer ---
    // Host: buf_A region (target=1) maps to words 0-511;
    //       buf_B region (target=2) maps to words 512-1023 (hi_mem_addr + 512)
    wire [10:0] hi_ub_addr = (hi_mem_target == 2'd2) ? hi_mem_addr + 11'd512
                                                       : hi_mem_addr;
    assign ub_addr  = accel_start ? seq_ub_addr    : hi_ub_addr;
    assign ub_din   = accel_start ? seq_ub_din     : hi_mem_wdata;
    assign ub_wmask = accel_start ? seq_ub_wmask   : hi_mem_wmask;
    assign ub_rwb   = accel_start ? seq_ub_rwb     : ~hi_mem_we;
    assign ub_req   = accel_start ? seq_ub_request :
                      (hi_mem_request && (hi_mem_target == 2'd1 || hi_mem_target == 2'd2));

    // --- Response mux: memory → host interface ---
    always @(*) begin
        case (hi_mem_target)
            2'd0:    begin hi_mem_rdata = pm_dout; hi_mem_valid = pm_valid; end
            2'd1:    begin hi_mem_rdata = ub_dout; hi_mem_valid = ub_valid; end
            2'd2:    begin hi_mem_rdata = ub_dout; hi_mem_valid = ub_valid; end
            default: begin hi_mem_rdata = 32'd0;   hi_mem_valid = 1'b0;    end
        endcase
    end

    // ================================================================
    // Interface selection: OBI or SPI
    // ================================================================

`ifdef USE_SPI_INTERFACE
    spi_interface u_host (
        .clk                    (clk),
        .reset                  (reset),
        .spi_sclk               (spi_sclk),
        .spi_cs_n               (spi_cs_n),
        .spi_mosi               (spi_mosi),
        .spi_miso               (spi_miso),
        .mem_addr               (hi_mem_addr),
        .mem_wdata              (hi_mem_wdata),
        .mem_wmask              (hi_mem_wmask),
        .mem_we                 (hi_mem_we),
        .mem_request            (hi_mem_request),
        .mem_target             (hi_mem_target),
        .mem_rdata              (hi_mem_rdata),
        .mem_valid              (hi_mem_valid),
        .accel_start            (accel_start),
        .accel_done             (accel_done),
        .accel_pred_class       (accel_pred_class),
        .accel_classification_valid (accel_cv)
    );
`else
    host_interface u_host (
        .clk                    (clk),
        .reset                  (reset),
        .obi_req                (obi_req),
        .obi_gnt                (obi_gnt),
        .obi_addr               (obi_addr),
        .obi_we                 (obi_we),
        .obi_be                 (obi_be),
        .obi_wdata              (obi_wdata),
        .obi_rvalid             (obi_rvalid),
        .obi_rdata              (obi_rdata),
        .mem_addr               (hi_mem_addr),
        .mem_wdata              (hi_mem_wdata),
        .mem_wmask              (hi_mem_wmask),
        .mem_we                 (hi_mem_we),
        .mem_request            (hi_mem_request),
        .mem_target             (hi_mem_target),
        .mem_rdata              (hi_mem_rdata),
        .mem_valid              (hi_mem_valid),
        .accel_start            (accel_start),
        .accel_done             (accel_done),
        .accel_pred_class       (accel_pred_class),
        .accel_classification_valid (accel_cv)
    );
`endif

    // ================================================================
    // Datapath: layer_sequencer + memories
    // ================================================================

    layer_sequencer u_seq (
        .clk                (clk),
        .reset              (reset),
        .start              (accel_start),
        .done               (accel_done),
        .buf_addr           (seq_ub_addr),
        .buf_din            (seq_ub_din),
        .buf_wmask          (seq_ub_wmask),
        .buf_request        (seq_ub_request),
        .buf_read_writeb    (seq_ub_rwb),
        .buf_dout           (seq_ub_dout),
        .buf_valid          (seq_ub_valid),
        .param_addr         (seq_pm_addr),
        .param_request      (seq_pm_request),
        .param_read_writeb  (seq_pm_rwb),
        .param_dout         (seq_pm_dout),
        .param_valid        (seq_pm_valid),
        .pred_class_out     (accel_pred_class),
        .classification_valid (accel_cv)
    );

    param_memory u_param (
        .clk        (clk),
        .reset      (reset),
        .addr       (pm_addr),
        .din        (pm_din),
        .read_writeb(pm_rwb),
        .request    (pm_req),
        .dout       (pm_dout),
        .valid      (pm_valid)
    );

    // Unified 1024-word activation buffer: A-region 0-511, B-region 512-1023
    activation_buffer #(.SRAM_ADDR_WIDTH(10)) u_buf (
        .clk        (clk),
        .reset      (reset),
        .addr       (ub_addr),
        .din        (ub_din),
        .wmask      (ub_wmask),
        .read_writeb(ub_rwb),
        .request    (ub_req),
        .dout       (ub_dout),
        .valid      (ub_valid)
    );

    // Sequencer sees memory outputs directly (don't-care when idle)
    assign seq_ub_dout  = ub_dout;
    assign seq_ub_valid = ub_valid;
    assign seq_pm_dout  = pm_dout;
    assign seq_pm_valid = pm_valid;

endmodule
