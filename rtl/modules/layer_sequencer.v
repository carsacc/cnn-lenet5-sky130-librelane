// layer_sequencer.v — Global Layer Sequencer
// Chains Conv1+Pool1 → Conv2+Pool2 → Conv3 → GAP+FC+ArgMax
// Internally instantiates: data_bus, compute_top, line_buffer,
//                          conv_layer_ctrl, gap_fc_layer_ctrl
// Externally exposes: 2 activation_buffer ports + 1 param_memory port + control

module layer_sequencer (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    output reg         done,

    // --- Unified Activation Buffer (single 1024-word SRAM) ---
    // A-region = words 0-511, B-region = words 512-1023
    output wire [10:0] buf_addr,
    output wire [31:0] buf_din,
    output wire [3:0]  buf_wmask,
    output wire        buf_request,
    output wire        buf_read_writeb,
    input  wire [31:0] buf_dout,
    input  wire        buf_valid,

    // --- Param Memory (read-only port) ---
    output wire [10:0] param_addr,
    output wire        param_request,
    output wire        param_read_writeb,
    input  wire [31:0] param_dout,
    input  wire        param_valid,

    // --- Classification output ---
    output wire [3:0]  pred_class_out,
    output wire        classification_valid
);

    // ================================================================
    // FSM States
    // ================================================================
    localparam [3:0]
        S_IDLE       = 4'd0,
        S_CONV1_CFG  = 4'd1,
        S_CONV1_GO   = 4'd2,
        S_WAIT_CONV1 = 4'd3,
        S_CONV2_CFG  = 4'd4,
        S_CONV2_GO   = 4'd5,
        S_WAIT_CONV2 = 4'd6,
        S_CONV3_CFG  = 4'd7,
        S_CONV3_GO   = 4'd8,
        S_WAIT_CONV3 = 4'd9,
        S_GFC_CFG    = 4'd10,
        S_GFC_GO     = 4'd11,
        S_WAIT_GFC   = 4'd12,
        S_DONE       = 4'd13;

    reg [3:0] state;

    // ================================================================
    // Per-Layer Configuration Constants
    // ================================================================
    localparam [7:0] GENERAL_SHIFT = 8'd30;

    // --- Conv1: OC-parallel, pool=1 ---
    localparam [10:0] CONV1_RD_BASE     = 11'd0;
    localparam [10:0] CONV1_WR_BASE     = 11'd0;
    localparam [10:0] CONV1_WEIGHT_BASE = 11'h002;
    localparam [10:0] CONV1_BIAS_BASE   = 11'h014;
    localparam [10:0] CONV1_MULT_BASE   = 11'h01C;
    localparam [10:0] CONV1_ZP_BASE     = 11'h024;
    localparam [4:0]  CONV1_OUT_HEIGHT   = 5'd26;
    localparam [4:0]  CONV1_OUT_WIDTH    = 5'd26;
    localparam [4:0]  CONV1_IN_WIDTH     = 5'd28;
    localparam [4:0]  CONV1_WORDS_PER_ROW = 5'd7;  // packed: 28 pixels / 4 per word
    localparam [2:0]  CONV1_NUM_IC_GROUPS = 3'd1;
    localparam [5:0]  CONV1_NUM_OC_STEPS  = 6'd2;

    // --- Conv2: IC-parallel, pool=1 ---
    localparam [10:0] CONV2_RD_BASE     = 11'd0;
    localparam [10:0] CONV2_WR_BASE     = 11'd0;
    localparam [10:0] CONV2_WEIGHT_BASE = 11'h026;
    localparam [10:0] CONV2_BIAS_BASE   = 11'h146;
    localparam [10:0] CONV2_MULT_BASE   = 11'h156;
    localparam [10:0] CONV2_ZP_BASE     = 11'h166;
    localparam [4:0]  CONV2_OUT_HEIGHT   = 5'd11;
    localparam [4:0]  CONV2_OUT_WIDTH    = 5'd11;
    localparam [4:0]  CONV2_IN_WIDTH     = 5'd13;
    localparam [4:0]  CONV2_WORDS_PER_ROW = 5'd26;
    localparam [2:0]  CONV2_NUM_IC_GROUPS = 3'd2;
    localparam [5:0]  CONV2_NUM_OC_STEPS  = 6'd16;

    // --- Conv3: IC-parallel, pool=0 ---
    localparam [10:0] CONV3_RD_BASE     = 11'd0;
    localparam [10:0] CONV3_WR_BASE     = 11'd0;
    localparam [10:0] CONV3_WEIGHT_BASE = 11'h16A;
    localparam [10:0] CONV3_BIAS_BASE   = 11'h5EA;
    localparam [10:0] CONV3_MULT_BASE   = 11'h60A;
    localparam [10:0] CONV3_ZP_BASE     = 11'h62A;
    localparam [4:0]  CONV3_OUT_HEIGHT   = 5'd3;
    localparam [4:0]  CONV3_OUT_WIDTH    = 5'd3;
    localparam [4:0]  CONV3_IN_WIDTH     = 5'd5;
    localparam [4:0]  CONV3_WORDS_PER_ROW = 5'd20;
    localparam [2:0]  CONV3_NUM_IC_GROUPS = 3'd4;
    localparam [5:0]  CONV3_NUM_OC_STEPS  = 6'd32;

    // --- GAP+FC+ArgMax ---
    localparam [10:0] GFC_GAP_RD_BASE     = 11'd0;
    localparam [10:0] GFC_GAP_WR_BASE     = 11'd72;
    localparam [10:0] GFC_FC_WR_BASE      = 11'd104;
    localparam [10:0] GFC_FC_WEIGHT_BASE  = 11'h632;
    localparam [10:0] GFC_FC_BIAS_BASE    = 11'h692;
    localparam [10:0] GFC_FC_MULT_BASE    = 11'h69C;
    localparam [10:0] GFC_FC_ZP_BASE      = 11'h6A6;

    // ================================================================
    // Conv layer config registers (set in _CFG states)
    // ================================================================
    reg [10:0] conv_act_rd_base;
    reg [10:0] conv_act_wr_base;
    reg [10:0] conv_weight_base;
    reg [10:0] conv_bias_base;
    reg [10:0] conv_mult_base;
    reg [10:0] conv_zp_base;
    reg [7:0]  conv_shift;
    reg [4:0]  conv_out_height;
    reg [4:0]  conv_out_width;
    reg [4:0]  conv_in_width;
    reg [4:0]  conv_words_per_row;
    reg [2:0]  conv_num_ic_groups;
    reg [5:0]  conv_num_oc_steps;
    reg        conv_is_ic_parallel;
    reg        conv_relu_en;
    reg        conv_pool_en;

    // ================================================================
    // Controller start/done signals
    // ================================================================
    reg  conv_start;
    wire conv_done;
    reg  gfc_start;
    wire gfc_done;

    // ================================================================
    // Unified buffer region offsets (A=0..511, B=512..1023)
    // ================================================================
    localparam [10:0] BUF_A_OFFSET = 11'd0;
    localparam [10:0] BUF_B_OFFSET = 11'd512;

    // Pixel-packed flag (1 for Conv1, 0 for Conv2/Conv3)
    reg conv_pixel_packed;

    // ================================================================
    // Active controller select: 0=conv, 1=gfc
    // ================================================================
    reg active_ctrl;

    // ================================================================
    // Internal wires: conv_layer_ctrl ↔ shared resources
    // ================================================================
    // Act read port
    wire [10:0] conv_act_rd_addr;
    wire        conv_act_rd_request;
    wire        conv_act_rd_rwb;
    // Act write port
    wire [10:0] conv_act_wr_addr;
    wire [31:0] conv_act_wr_din;
    wire [3:0]  conv_act_wr_wmask;
    wire        conv_act_wr_request;
    wire        conv_act_wr_rwb;
    // Param port
    wire [10:0] conv_param_addr;
    wire        conv_param_request;
    wire        conv_param_rwb; // driven by conv_layer_ctrl, unused (param always read)
    // Line buffer
    wire [31:0] lb_wr_data;
    wire        lb_wr_en;
    wire [1:0]  lb_wr_row;
    wire [4:0]  lb_wr_addr;
    wire [1:0]  lb_rd_row;
    wire [4:0]  lb_rd_addr;
    wire [31:0] lb_rd_data;
    wire        lb_row_advance;
    // Data bus inputs
    wire [31:0] conv_db_pixel_din;
    wire        conv_db_pixel_load;
    wire [1:0]  conv_db_pixel_byte_sel;
    wire [31:0] conv_db_weight_din;
    wire        conv_db_weight_load;
    wire [31:0] conv_db_bias_din;
    wire        conv_db_bias_load;
    wire [1:0]  conv_db_bias_lane_sel;
    wire [31:0] conv_db_mult_din;
    wire        conv_db_mult_load;
    wire [1:0]  conv_db_mult_lane_sel;
    wire [7:0]  conv_db_shift_din;
    wire        conv_db_shift_load;
    wire [31:0] conv_db_zp_din;
    wire        conv_db_zp_load;
    // Compute top controls
    wire        conv_ct_core_req;
    wire        conv_ct_core_acc_clear;
    wire        conv_ct_core_process_out;
    wire        conv_ct_core_frame_start;
    wire [5:0]  conv_ct_core_img_width;
    // Data bus result path
    wire [1:0]  conv_db_result_byte_pos;

    // ================================================================
    // Internal wires: gap_fc_layer_ctrl ↔ shared resources
    // ================================================================
    // Act read port
    wire [10:0] gfc_act_rd_addr;
    wire        gfc_act_rd_request;
    wire        gfc_act_rd_rwb;
    // Act write port
    wire [10:0] gfc_act_wr_addr;
    wire [31:0] gfc_act_wr_din;
    wire [3:0]  gfc_act_wr_wmask;
    wire        gfc_act_wr_request;
    wire        gfc_act_wr_rwb;
    // Param port
    wire [10:0] gfc_param_addr;
    wire        gfc_param_request;
    wire        gfc_param_rwb; // driven by gap_fc_layer_ctrl, unused (param always read)
    // Data bus inputs
    wire [31:0] gfc_db_pixel_din;
    wire        gfc_db_pixel_load;
    wire [1:0]  gfc_db_pixel_byte_sel;
    wire [31:0] gfc_db_weight_din;
    wire        gfc_db_weight_load;
    wire [31:0] gfc_db_bias_din;
    wire        gfc_db_bias_load;
    wire [1:0]  gfc_db_bias_lane_sel;
    wire [31:0] gfc_db_mult_din;
    wire        gfc_db_mult_load;
    wire [1:0]  gfc_db_mult_lane_sel;
    wire [7:0]  gfc_db_shift_din;
    wire        gfc_db_shift_load;
    wire [31:0] gfc_db_zp_din;
    wire        gfc_db_zp_load;
    // Compute top controls
    wire [1:0]  gfc_ct_compute_mode;
    wire        gfc_ct_gap_req;
    wire        gfc_ct_argmax_req;
    wire        gfc_ct_core_req;
    wire        gfc_ct_core_acc_clear;
    wire        gfc_ct_core_process_out;
    wire        gfc_ct_core_frame_start;
    // Classification outputs
    wire [3:0]  gfc_pred_class_out;
    wire        gfc_classification_valid;

    // ================================================================
    // Internal wires: data_bus outputs → compute_top
    // ================================================================
    wire [31:0] db_pixel_word;
    wire [31:0] db_weights_word;
    wire signed [31:0] db_bias_0, db_bias_1, db_bias_2, db_bias_3;
    wire signed [31:0] db_mult_0, db_mult_1, db_mult_2, db_mult_3;
    wire [7:0]  db_shift_amt;
    wire [7:0]  db_zp_0, db_zp_1, db_zp_2, db_zp_3;
    wire [31:0] db_result_dout;  // used by data_bus, read via act_wr_din mux
    wire [3:0]  db_result_wmask; // used by data_bus, read via act_wr_wmask mux

    // ================================================================
    // Internal wires: compute_top outputs
    // ================================================================
    wire [31:0] ct_data_out_32b;
    wire        ct_valid_out;
    wire [3:0]  ct_pred_class;
    wire        ct_classification_done;

    // ================================================================
    // Controller Mux: select active controller signals
    // ================================================================

    // --- Act read port (to buffer routing) ---
    wire [10:0] ctrl_act_rd_addr    = active_ctrl ? gfc_act_rd_addr    : conv_act_rd_addr;
    wire        ctrl_act_rd_request = active_ctrl ? gfc_act_rd_request : conv_act_rd_request;
    // ctrl_act_rd_rwb removed — always read (1'b1) during inference

    // --- Act write port (to buffer routing) ---
    wire [10:0] ctrl_act_wr_addr    = active_ctrl ? gfc_act_wr_addr    : conv_act_wr_addr;
    wire [31:0] ctrl_act_wr_din     = active_ctrl ? gfc_act_wr_din     : conv_act_wr_din;
    wire [3:0]  ctrl_act_wr_wmask   = active_ctrl ? gfc_act_wr_wmask   : conv_act_wr_wmask;
    wire        ctrl_act_wr_request = active_ctrl ? gfc_act_wr_request : conv_act_wr_request;
    // ctrl_act_wr_rwb removed — always write (1'b0) during inference

    // --- Param memory ---
    assign param_addr          = active_ctrl ? gfc_param_addr    : conv_param_addr;
    assign param_request       = active_ctrl ? gfc_param_request : conv_param_request;
    assign param_read_writeb   = 1'b1; // always read

    // --- Data bus inputs ---
    wire [31:0] ctrl_db_pixel_din      = active_ctrl ? gfc_db_pixel_din      : conv_db_pixel_din;
    wire        ctrl_db_pixel_load     = active_ctrl ? gfc_db_pixel_load     : conv_db_pixel_load;
    wire [1:0]  ctrl_db_pixel_byte_sel = active_ctrl ? gfc_db_pixel_byte_sel : conv_db_pixel_byte_sel;
    wire [31:0] ctrl_db_weight_din     = active_ctrl ? gfc_db_weight_din     : conv_db_weight_din;
    wire        ctrl_db_weight_load    = active_ctrl ? gfc_db_weight_load    : conv_db_weight_load;
    wire [31:0] ctrl_db_bias_din       = active_ctrl ? gfc_db_bias_din       : conv_db_bias_din;
    wire        ctrl_db_bias_load      = active_ctrl ? gfc_db_bias_load      : conv_db_bias_load;
    wire [1:0]  ctrl_db_bias_lane_sel  = active_ctrl ? gfc_db_bias_lane_sel  : conv_db_bias_lane_sel;
    wire [31:0] ctrl_db_mult_din       = active_ctrl ? gfc_db_mult_din       : conv_db_mult_din;
    wire        ctrl_db_mult_load      = active_ctrl ? gfc_db_mult_load      : conv_db_mult_load;
    wire [1:0]  ctrl_db_mult_lane_sel  = active_ctrl ? gfc_db_mult_lane_sel  : conv_db_mult_lane_sel;
    wire [7:0]  ctrl_db_shift_din      = active_ctrl ? gfc_db_shift_din      : conv_db_shift_din;
    wire        ctrl_db_shift_load     = active_ctrl ? gfc_db_shift_load     : conv_db_shift_load;
    wire [31:0] ctrl_db_zp_din         = active_ctrl ? gfc_db_zp_din         : conv_db_zp_din;
    wire        ctrl_db_zp_load        = active_ctrl ? gfc_db_zp_load        : conv_db_zp_load;

    // --- Compute top controls ---
    wire [1:0]  ctrl_compute_mode      = active_ctrl ? gfc_ct_compute_mode     : 2'd0;
    wire        ctrl_core_req          = active_ctrl ? gfc_ct_core_req         : conv_ct_core_req;
    wire        ctrl_core_acc_clear    = active_ctrl ? gfc_ct_core_acc_clear   : conv_ct_core_acc_clear;
    wire        ctrl_core_process_out  = active_ctrl ? gfc_ct_core_process_out : conv_ct_core_process_out;
    wire        ctrl_core_frame_start  = active_ctrl ? gfc_ct_core_frame_start : conv_ct_core_frame_start;
    wire        ctrl_gap_req           = active_ctrl ? gfc_ct_gap_req          : 1'b0;
    wire        ctrl_argmax_req        = active_ctrl ? gfc_ct_argmax_req       : 1'b0;

    // --- Compute top config ---
    wire        ct_is_parallel_ic = active_ctrl ? 1'b0              : conv_is_ic_parallel;
    wire        ct_relu_en        = 1'b1; // always enabled
    wire        ct_pool_en        = active_ctrl ? 1'b0              : conv_pool_en;
    wire [5:0]  ct_img_width      = active_ctrl ? 6'd0              : conv_ct_core_img_width;

    // --- Data bus is_ic_mode ---
    wire        db_is_ic_mode     = active_ctrl ? 1'b0              : conv_is_ic_parallel;

    // --- Data bus result_byte_pos (only conv uses it) ---
    wire [1:0]  ctrl_db_result_byte_pos = active_ctrl ? 2'd0        : conv_db_result_byte_pos;

    // ================================================================
    // Unified Buffer Routing
    // ================================================================
    // rd and wr accesses are never simultaneous (provably serial FSM states).
    // Base addresses already include A/B region offsets (set in _CFG states).

    wire [31:0] ctrl_act_rd_dout  = buf_dout;
    wire        ctrl_act_rd_valid = buf_valid & ctrl_act_rd_request;
    wire        ctrl_act_wr_valid = buf_valid & ctrl_act_wr_request;

    assign buf_addr        = ctrl_act_rd_request ? ctrl_act_rd_addr :
                             ctrl_act_wr_request ? ctrl_act_wr_addr : 11'd0;
    assign buf_din         = ctrl_act_wr_din;
    assign buf_wmask       = ctrl_act_wr_wmask;
    assign buf_request     = ctrl_act_rd_request | ctrl_act_wr_request;
    assign buf_read_writeb = ctrl_act_rd_request ? 1'b1 : 1'b0;

    // ================================================================
    // Submodule Instantiations
    // ================================================================

    // --- conv_layer_ctrl ---
    conv_layer_ctrl u_conv_ctrl (
        .clk                (clk),
        .reset              (reset),
        .start              (conv_start),
        .done               (conv_done),
        // Config
        .cfg_act_rd_base    (conv_act_rd_base),
        .cfg_act_wr_base    (conv_act_wr_base),
        .cfg_weight_base    (conv_weight_base),
        .cfg_bias_base      (conv_bias_base),
        .cfg_mult_base      (conv_mult_base),
        .cfg_zp_base        (conv_zp_base),
        .cfg_shift          (conv_shift),
        .cfg_out_height     (conv_out_height),
        .cfg_out_width      (conv_out_width),
        .cfg_in_width       (conv_in_width),
        .cfg_words_per_row  (conv_words_per_row),
        .cfg_num_ic_groups  (conv_num_ic_groups),
        .cfg_num_oc_steps   (conv_num_oc_steps),
        .cfg_is_ic_parallel (conv_is_ic_parallel),
        .cfg_relu_en        (conv_relu_en),
        .cfg_pool_en        (conv_pool_en),
        .cfg_pixel_packed   (conv_pixel_packed),
        // Act read
        .act_rd_addr        (conv_act_rd_addr),
        .act_rd_request     (conv_act_rd_request),
        .act_rd_read_writeb (conv_act_rd_rwb),
        .act_rd_dout        (ctrl_act_rd_dout),
        .act_rd_valid       (ctrl_act_rd_valid),
        // Act write
        .act_wr_addr        (conv_act_wr_addr),
        .act_wr_din         (conv_act_wr_din),
        .act_wr_wmask       (conv_act_wr_wmask),
        .act_wr_request     (conv_act_wr_request),
        .act_wr_read_writeb (conv_act_wr_rwb),
        .act_wr_valid       (ctrl_act_wr_valid),
        // Param
        .param_addr         (conv_param_addr),
        .param_request      (conv_param_request),
        .param_read_writeb  (conv_param_rwb),
        .param_dout         (param_dout),
        .param_valid        (param_valid),
        // Line buffer
        .lb_wr_data         (lb_wr_data),
        .lb_wr_en           (lb_wr_en),
        .lb_wr_row          (lb_wr_row),
        .lb_wr_addr         (lb_wr_addr),
        .lb_rd_row          (lb_rd_row),
        .lb_rd_addr         (lb_rd_addr),
        .lb_rd_data         (lb_rd_data),
        .lb_row_advance     (lb_row_advance),
        // Data bus inputs
        .db_pixel_din       (conv_db_pixel_din),
        .db_pixel_load      (conv_db_pixel_load),
        .db_pixel_byte_sel  (conv_db_pixel_byte_sel),
        .db_weight_din      (conv_db_weight_din),
        .db_weight_load     (conv_db_weight_load),
        .db_bias_din        (conv_db_bias_din),
        .db_bias_load       (conv_db_bias_load),
        .db_bias_lane_sel   (conv_db_bias_lane_sel),
        .db_mult_din        (conv_db_mult_din),
        .db_mult_load       (conv_db_mult_load),
        .db_mult_lane_sel   (conv_db_mult_lane_sel),
        .db_shift_din       (conv_db_shift_din),
        .db_shift_load      (conv_db_shift_load),
        .db_zp_din          (conv_db_zp_din),
        .db_zp_load         (conv_db_zp_load),
        // Compute top
        .ct_core_req        (conv_ct_core_req),
        .ct_core_acc_clear  (conv_ct_core_acc_clear),
        .ct_core_process_out(conv_ct_core_process_out),
        .ct_core_frame_start(conv_ct_core_frame_start),
        .ct_core_img_width  (conv_ct_core_img_width),
        .ct_data_out_32b    (ct_data_out_32b),
        .ct_valid_out       (ct_valid_out),
        // Data bus result
        .db_result_byte_pos (conv_db_result_byte_pos)
    );

    // --- gap_fc_layer_ctrl ---
    gap_fc_layer_ctrl u_gfc_ctrl (
        .clk                    (clk),
        .reset                  (reset),
        .start                  (gfc_start),
        .done                   (gfc_done),
        // Config
        .cfg_gap_rd_base        (GFC_GAP_RD_BASE + BUF_B_OFFSET),  // 512
        .cfg_gap_wr_base        (GFC_GAP_WR_BASE + BUF_B_OFFSET),  // 584
        .cfg_fc_wr_base         (GFC_FC_WR_BASE  + BUF_B_OFFSET),  // 616
        .cfg_fc_weight_base     (GFC_FC_WEIGHT_BASE),
        .cfg_fc_bias_base       (GFC_FC_BIAS_BASE),
        .cfg_fc_mult_base       (GFC_FC_MULT_BASE),
        .cfg_fc_zp_base         (GFC_FC_ZP_BASE),
        .cfg_fc_shift           (GENERAL_SHIFT),
        // Act read
        .act_rd_addr            (gfc_act_rd_addr),
        .act_rd_request         (gfc_act_rd_request),
        .act_rd_read_writeb     (gfc_act_rd_rwb),
        .act_rd_dout            (ctrl_act_rd_dout),
        .act_rd_valid           (ctrl_act_rd_valid),
        // Act write
        .act_wr_addr            (gfc_act_wr_addr),
        .act_wr_din             (gfc_act_wr_din),
        .act_wr_wmask           (gfc_act_wr_wmask),
        .act_wr_request         (gfc_act_wr_request),
        .act_wr_read_writeb     (gfc_act_wr_rwb),
        .act_wr_valid           (ctrl_act_wr_valid),
        // Param
        .param_addr             (gfc_param_addr),
        .param_request          (gfc_param_request),
        .param_read_writeb      (gfc_param_rwb),
        .param_dout             (param_dout),
        .param_valid            (param_valid),
        // Data bus inputs
        .db_pixel_din           (gfc_db_pixel_din),
        .db_pixel_load          (gfc_db_pixel_load),
        .db_pixel_byte_sel      (gfc_db_pixel_byte_sel),
        .db_weight_din          (gfc_db_weight_din),
        .db_weight_load         (gfc_db_weight_load),
        .db_bias_din            (gfc_db_bias_din),
        .db_bias_load           (gfc_db_bias_load),
        .db_bias_lane_sel       (gfc_db_bias_lane_sel),
        .db_mult_din            (gfc_db_mult_din),
        .db_mult_load           (gfc_db_mult_load),
        .db_mult_lane_sel       (gfc_db_mult_lane_sel),
        .db_shift_din           (gfc_db_shift_din),
        .db_shift_load          (gfc_db_shift_load),
        .db_zp_din              (gfc_db_zp_din),
        .db_zp_load             (gfc_db_zp_load),
        // Compute top
        .ct_compute_mode        (gfc_ct_compute_mode),
        .ct_gap_req             (gfc_ct_gap_req),
        .ct_argmax_req          (gfc_ct_argmax_req),
        .ct_core_req            (gfc_ct_core_req),
        .ct_core_acc_clear      (gfc_ct_core_acc_clear),
        .ct_core_process_out    (gfc_ct_core_process_out),
        .ct_core_frame_start    (gfc_ct_core_frame_start),
        .ct_data_out_32b        (ct_data_out_32b),
        .ct_valid_out           (ct_valid_out),
        .ct_pred_class          (ct_pred_class),
        .ct_classification_done (ct_classification_done),
        // Classification output
        .pred_class_out         (gfc_pred_class_out),
        .classification_valid   (gfc_classification_valid)
    );

    // --- data_bus ---
    data_bus u_data_bus (
        .clk            (clk),
        .reset          (reset),
        .is_ic_mode     (db_is_ic_mode),
        // Pixel
        .pixel_din      (ctrl_db_pixel_din),
        .pixel_load     (ctrl_db_pixel_load),
        .pixel_byte_sel (ctrl_db_pixel_byte_sel),
        .pixel_word     (db_pixel_word),
        // Weight
        .weight_din     (ctrl_db_weight_din),
        .weight_load    (ctrl_db_weight_load),
        .weights_word   (db_weights_word),
        // Bias
        .bias_din       (ctrl_db_bias_din),
        .bias_load      (ctrl_db_bias_load),
        .bias_lane_sel  (ctrl_db_bias_lane_sel),
        .bias_0         (db_bias_0),
        .bias_1         (db_bias_1),
        .bias_2         (db_bias_2),
        .bias_3         (db_bias_3),
        // Mult
        .mult_din       (ctrl_db_mult_din),
        .mult_load      (ctrl_db_mult_load),
        .mult_lane_sel  (ctrl_db_mult_lane_sel),
        .mult_0         (db_mult_0),
        .mult_1         (db_mult_1),
        .mult_2         (db_mult_2),
        .mult_3         (db_mult_3),
        // Shift
        .shift_din      (ctrl_db_shift_din),
        .shift_load     (ctrl_db_shift_load),
        .shift_amt      (db_shift_amt),
        // ZP
        .zp_din         (ctrl_db_zp_din),
        .zp_load        (ctrl_db_zp_load),
        .zp_0           (db_zp_0),
        .zp_1           (db_zp_1),
        .zp_2           (db_zp_2),
        .zp_3           (db_zp_3),
        // Result
        .result_din     (ct_data_out_32b),
        .result_valid   (ct_valid_out),
        .result_byte_pos(ctrl_db_result_byte_pos),
        .result_dout    (db_result_dout),
        .result_wmask   (db_result_wmask)
    );

    // --- compute_top ---
    compute_top u_compute_top (
        .clk              (clk),
        .reset            (reset),
        .compute_mode     (ctrl_compute_mode),
        .is_parallel_ic   (ct_is_parallel_ic),
        .core_req         (ctrl_core_req),
        .core_acc_clear   (ctrl_core_acc_clear),
        .core_process_out (ctrl_core_process_out),
        .core_frame_start (ctrl_core_frame_start),
        .core_relu_en     (ct_relu_en),
        .core_pool_en     (ct_pool_en),
        .core_img_width   (ct_img_width),
        .gap_req          (ctrl_gap_req),
        .argmax_req       (ctrl_argmax_req),
        // Data from data_bus
        .weights_word     (db_weights_word),
        .pixel_word       (db_pixel_word),
        .bias_0           (db_bias_0),
        .bias_1           (db_bias_1),
        .bias_2           (db_bias_2),
        .bias_3           (db_bias_3),
        .mult_0           (db_mult_0),
        .mult_1           (db_mult_1),
        .mult_2           (db_mult_2),
        .mult_3           (db_mult_3),
        .shift_amt        (db_shift_amt),
        .zp_0             (db_zp_0),
        .zp_1             (db_zp_1),
        .zp_2             (db_zp_2),
        .zp_3             (db_zp_3),
        // Outputs
        .data_out_32b     (ct_data_out_32b),
        .valid_out        (ct_valid_out),
        .pred_class       (ct_pred_class),
        .classification_done (ct_classification_done)
    );

    // --- line_buffer ---
    line_buffer #(.MAX_WORDS_PER_ROW(28)) u_line_buf (
        .clk        (clk),
        .reset      (reset),
        .wr_data    (lb_wr_data),
        .wr_en      (lb_wr_en),
        .wr_row     (lb_wr_row),
        .wr_addr    (lb_wr_addr),
        .rd_row     (lb_rd_row),
        .rd_addr    (lb_rd_addr),
        .rd_data    (lb_rd_data),
        .row_advance(lb_row_advance)
    );

    // ================================================================
    // Classification output from gap_fc_layer_ctrl
    // ================================================================
    assign pred_class_out       = gfc_pred_class_out;
    assign classification_valid = gfc_classification_valid;

    // ================================================================
    // Main FSM
    // ================================================================
    always @(posedge clk) begin
        if (reset) begin
            state             <= S_IDLE;
            done              <= 1'b0;
            conv_start        <= 1'b0;
            gfc_start         <= 1'b0;
            active_ctrl       <= 1'b0;
            conv_pixel_packed <= 1'b0;
            // Config regs init
            conv_act_rd_base    <= 11'd0;
            conv_act_wr_base    <= 11'd0;
            conv_weight_base    <= 11'd0;
            conv_bias_base      <= 11'd0;
            conv_mult_base      <= 11'd0;
            conv_zp_base        <= 11'd0;
            conv_shift          <= 8'd0;
            conv_out_height     <= 5'd0;
            conv_out_width      <= 5'd0;
            conv_in_width       <= 5'd0;
            conv_words_per_row  <= 5'd0;
            conv_num_ic_groups  <= 3'd0;
            conv_num_oc_steps   <= 6'd0;
            conv_is_ic_parallel <= 1'b0;
            conv_relu_en        <= 1'b0;
            conv_pool_en        <= 1'b0;
        end else begin
            case (state)

            S_IDLE: begin
                done <= 1'b0;
                if (start)
                    state <= S_CONV1_CFG;
            end

            // ==== Conv1 (OC-parallel, pool=1, pixel-packed) ====
            S_CONV1_CFG: begin
                conv_act_rd_base    <= CONV1_RD_BASE + BUF_A_OFFSET; // A-region = 0
                conv_act_wr_base    <= CONV1_WR_BASE + BUF_B_OFFSET; // B-region = 512
                conv_weight_base    <= CONV1_WEIGHT_BASE;
                conv_bias_base      <= CONV1_BIAS_BASE;
                conv_mult_base      <= CONV1_MULT_BASE;
                conv_zp_base        <= CONV1_ZP_BASE;
                conv_shift          <= GENERAL_SHIFT;
                conv_out_height     <= CONV1_OUT_HEIGHT;
                conv_out_width      <= CONV1_OUT_WIDTH;
                conv_in_width       <= CONV1_IN_WIDTH;
                conv_words_per_row  <= CONV1_WORDS_PER_ROW;
                conv_num_ic_groups  <= CONV1_NUM_IC_GROUPS;
                conv_num_oc_steps   <= CONV1_NUM_OC_STEPS;
                conv_is_ic_parallel <= 1'b0;
                conv_relu_en        <= 1'b1;
                conv_pool_en        <= 1'b1;
                conv_pixel_packed   <= 1'b1;
                active_ctrl         <= 1'b0;
                conv_start          <= 1'b0;
                state               <= S_CONV1_GO;
            end

            S_CONV1_GO: begin
                conv_start <= 1'b1;
                state      <= S_WAIT_CONV1;
            end

            S_WAIT_CONV1: begin
                if (conv_done) begin
                    conv_start <= 1'b0;
                    state      <= S_CONV2_CFG;
                end
            end

            // ==== Conv2 (IC-parallel, pool=1) ====
            S_CONV2_CFG: begin
                conv_act_rd_base    <= CONV2_RD_BASE + BUF_B_OFFSET; // B-region = 512
                conv_act_wr_base    <= CONV2_WR_BASE + BUF_A_OFFSET; // A-region = 0
                conv_weight_base    <= CONV2_WEIGHT_BASE;
                conv_bias_base      <= CONV2_BIAS_BASE;
                conv_mult_base      <= CONV2_MULT_BASE;
                conv_zp_base        <= CONV2_ZP_BASE;
                conv_shift          <= GENERAL_SHIFT;
                conv_out_height     <= CONV2_OUT_HEIGHT;
                conv_out_width      <= CONV2_OUT_WIDTH;
                conv_in_width       <= CONV2_IN_WIDTH;
                conv_words_per_row  <= CONV2_WORDS_PER_ROW;
                conv_num_ic_groups  <= CONV2_NUM_IC_GROUPS;
                conv_num_oc_steps   <= CONV2_NUM_OC_STEPS;
                conv_is_ic_parallel <= 1'b1;
                conv_relu_en        <= 1'b1;
                conv_pool_en        <= 1'b1;
                conv_pixel_packed   <= 1'b0;
                active_ctrl         <= 1'b0;
                conv_start          <= 1'b0;
                state               <= S_CONV2_GO;
            end

            S_CONV2_GO: begin
                conv_start <= 1'b1;
                state      <= S_WAIT_CONV2;
            end

            S_WAIT_CONV2: begin
                if (conv_done) begin
                    conv_start <= 1'b0;
                    state      <= S_CONV3_CFG;
                end
            end

            // ==== Conv3 (IC-parallel, pool=0) ====
            S_CONV3_CFG: begin
                conv_act_rd_base    <= CONV3_RD_BASE + BUF_A_OFFSET; // A-region = 0
                conv_act_wr_base    <= CONV3_WR_BASE + BUF_B_OFFSET; // B-region = 512
                conv_weight_base    <= CONV3_WEIGHT_BASE;
                conv_bias_base      <= CONV3_BIAS_BASE;
                conv_mult_base      <= CONV3_MULT_BASE;
                conv_zp_base        <= CONV3_ZP_BASE;
                conv_shift          <= GENERAL_SHIFT;
                conv_out_height     <= CONV3_OUT_HEIGHT;
                conv_out_width      <= CONV3_OUT_WIDTH;
                conv_in_width       <= CONV3_IN_WIDTH;
                conv_words_per_row  <= CONV3_WORDS_PER_ROW;
                conv_num_ic_groups  <= CONV3_NUM_IC_GROUPS;
                conv_num_oc_steps   <= CONV3_NUM_OC_STEPS;
                conv_is_ic_parallel <= 1'b1;
                conv_relu_en        <= 1'b1;
                conv_pool_en        <= 1'b0;
                conv_pixel_packed   <= 1'b0;
                active_ctrl         <= 1'b0;
                conv_start          <= 1'b0;
                state               <= S_CONV3_GO;
            end

            S_CONV3_GO: begin
                conv_start <= 1'b1;
                state      <= S_WAIT_CONV3;
            end

            S_WAIT_CONV3: begin
                if (conv_done) begin
                    conv_start <= 1'b0;
                    state      <= S_GFC_CFG;
                end
            end

            // ==== GAP + FC + ArgMax ====
            // GFC uses B-region for both rd and wr (addresses include +512 offset)
            S_GFC_CFG: begin
                active_ctrl <= 1'b1; // gfc
                gfc_start   <= 1'b0;
                state       <= S_GFC_GO;
            end

            S_GFC_GO: begin
                gfc_start <= 1'b1;
                state     <= S_WAIT_GFC;
            end

            S_WAIT_GFC: begin
                if (gfc_done) begin
                    gfc_start <= 1'b0;
                    state     <= S_DONE;
                end
            end

            S_DONE: begin
                done <= 1'b1;
                if (!start)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

endmodule
