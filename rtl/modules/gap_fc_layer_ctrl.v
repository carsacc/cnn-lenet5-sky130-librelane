// gap_fc_layer_ctrl.v — GAP + FC + ArgMax Layer Controller FSM
// Orchestrates the final three inference stages:
//   GAP: Conv3 output (3x3x32) -> 32 averaged values
//   FC:  32 GAP outputs x 10 neurons -> 10 logits (OC-parallel mode)
//   ArgMax: 10 logits -> 4-bit classification
// All stages share: activation_buffer, param_memory, data_bus, compute_top.

module gap_fc_layer_ctrl (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    output reg         done,

    // --- Configuration (base addresses) ---
    input  wire [10:0] cfg_gap_rd_base,     // Conv3 output in act_buffer
    input  wire [10:0] cfg_gap_wr_base,     // GAP output destination
    input  wire [10:0] cfg_fc_wr_base,      // FC output destination
    input  wire [10:0] cfg_fc_weight_base,  // FC weights in param_memory
    input  wire [10:0] cfg_fc_bias_base,    // FC bias in param_memory
    input  wire [10:0] cfg_fc_mult_base,    // FC mult in param_memory
    input  wire [10:0] cfg_fc_zp_base,      // FC ZP in param_memory
    input  wire [7:0]  cfg_fc_shift,        // FC shift amount

    // --- Activation Buffer (read) ---
    output reg  [10:0] act_rd_addr,
    output reg         act_rd_request,
    output wire        act_rd_read_writeb,
    input  wire [31:0] act_rd_dout,
    input  wire        act_rd_valid,

    // --- Activation Buffer (write) ---
    output reg  [10:0] act_wr_addr,
    output reg  [31:0] act_wr_din,
    output reg  [3:0]  act_wr_wmask,
    output reg         act_wr_request,
    output wire        act_wr_read_writeb,
    input  wire        act_wr_valid,

    // --- Param Memory (read) ---
    output reg  [10:0] param_addr,
    output reg         param_request,
    output wire        param_read_writeb,
    input  wire [31:0] param_dout,
    input  wire        param_valid,

    // --- Data Bus ---
    output reg  [31:0] db_pixel_din,
    output reg         db_pixel_load,
    output reg  [1:0]  db_pixel_byte_sel,
    output reg  [31:0] db_weight_din,
    output reg         db_weight_load,
    output reg  [31:0] db_bias_din,
    output reg         db_bias_load,
    output reg  [1:0]  db_bias_lane_sel,
    output reg  [31:0] db_mult_din,
    output reg         db_mult_load,
    output reg  [1:0]  db_mult_lane_sel,
    output reg  [7:0]  db_shift_din,
    output reg         db_shift_load,
    output reg  [31:0] db_zp_din,
    output reg         db_zp_load,

    // --- Compute Top ---
    output reg  [1:0]  ct_compute_mode,     // 0=Core, 1=GAP, 2=ArgMax
    output reg         ct_gap_req,
    output reg         ct_argmax_req,
    output reg         ct_core_req,
    output reg         ct_core_acc_clear,
    output reg         ct_core_process_out,
    output reg         ct_core_frame_start,
    input  wire [31:0] ct_data_out_32b,
    input  wire        ct_valid_out,
    input  wire [3:0]  ct_pred_class,
    input  wire        ct_classification_done,

    // --- Final output ---
    output reg  [3:0]  pred_class_out,
    output reg         classification_valid
);

    // ================================================================
    // Fixed assigns
    // ================================================================
    assign act_rd_read_writeb = 1'b1;
    assign act_wr_read_writeb = 1'b0;
    assign param_read_writeb  = 1'b1;

    // ================================================================
    // Architecture constants
    // ================================================================
    localparam GAP_NUM_OC    = 32;
    localparam GAP_SPATIAL   = 9;    // 3x3
    localparam GAP_OC_WORDS  = 8;    // 32/4
    localparam FC_NUM_GROUPS = 3;    // ceil(10/4)
    localparam FC_NUM_INPUTS = 32;
    localparam FC_CFG_COUNT  = 9;    // 4 bias + 4 mult + 1 zp
    localparam ARG_NUM_CLASSES = 10;

    // ================================================================
    // FSM States
    // ================================================================
    localparam [4:0]
        S_IDLE       = 5'd0,
        // GAP phase
        S_GAP_READ   = 5'd1,
        S_GAP_WAIT   = 5'd2,
        S_GAP_LOAD   = 5'd3,
        S_GAP_REQ    = 5'd4,
        S_GAP_VALID  = 5'd5,
        S_GAP_WRITE  = 5'd6,
        S_GAP_WR_WAIT= 5'd7,
        // FC phase
        S_FC_SHIFT   = 5'd8,
        S_FC_FRAME   = 5'd9,
        S_FC_CFG_RD  = 5'd10,
        S_FC_CFG_WAIT= 5'd11,
        S_FC_PIX_RD  = 5'd12,
        S_FC_PIX_WAIT= 5'd13,
        S_FC_WT_RD   = 5'd14,
        S_FC_WT_WAIT = 5'd15,
        S_FC_LOAD    = 5'd16,
        S_FC_REQ     = 5'd17,
        S_FC_PROC    = 5'd18,
        S_FC_WVALID  = 5'd19,
        S_FC_WRITE   = 5'd20,
        S_FC_WR_WAIT = 5'd21,
        // ArgMax phase
        S_ARG_READ   = 5'd22,
        S_ARG_WAIT   = 5'd23,
        S_ARG_LOAD   = 5'd24,
        S_ARG_REQ    = 5'd25,
        S_ARG_WDONE  = 5'd26,
        // Done
        S_DONE       = 5'd27;

    reg [4:0] state;

    // ================================================================
    // Counters
    // ================================================================
    reg [5:0] gap_oc;          // 0..31
    reg [3:0] gap_sp;          // 0..8

    reg [1:0] fc_oc_group;     // 0..2
    reg [5:0] fc_input;        // 0..31
    reg [3:0] fc_cfg_cnt;      // 0..8

    reg [3:0] arg_logit;       // 0..9

    reg [31:0] captured_data;
    reg [31:0] weight_captured;

    // ================================================================
    // FC config address calculation
    // ================================================================
    reg [10:0] fc_cfg_param_addr;
    always @(*) begin
        if (fc_cfg_cnt < 4)
            fc_cfg_param_addr = cfg_fc_bias_base + {9'd0, fc_oc_group} * 11'd4 + {7'd0, fc_cfg_cnt};
        else if (fc_cfg_cnt < 8)
            fc_cfg_param_addr = cfg_fc_mult_base + {9'd0, fc_oc_group} * 11'd4 + {7'd0, fc_cfg_cnt} - 11'd4;
        else
            fc_cfg_param_addr = cfg_fc_zp_base + {9'd0, fc_oc_group};
    end

    // ================================================================
    // Main FSM
    // ================================================================
    always @(posedge clk) begin
        if (reset) begin
            state              <= S_IDLE;
            done               <= 1'b0;
            gap_oc             <= 6'd0;
            gap_sp             <= 4'd0;
            fc_oc_group        <= 2'd0;
            fc_input           <= 6'd0;
            fc_cfg_cnt         <= 4'd0;
            arg_logit          <= 4'd0;
            captured_data      <= 32'd0;
            weight_captured    <= 32'd0;
            // Outputs
            act_rd_addr        <= 11'd0;
            act_rd_request     <= 1'b0;
            act_wr_addr        <= 11'd0;
            act_wr_din         <= 32'd0;
            act_wr_wmask       <= 4'd0;
            act_wr_request     <= 1'b0;
            param_addr         <= 11'd0;
            param_request      <= 1'b0;
            db_pixel_din       <= 32'd0;
            db_pixel_load      <= 1'b0;
            db_pixel_byte_sel  <= 2'd0;
            db_weight_din      <= 32'd0;
            db_weight_load     <= 1'b0;
            db_bias_din        <= 32'd0;
            db_bias_load       <= 1'b0;
            db_bias_lane_sel   <= 2'd0;
            db_mult_din        <= 32'd0;
            db_mult_load       <= 1'b0;
            db_mult_lane_sel   <= 2'd0;
            db_shift_din       <= 8'd0;
            db_shift_load      <= 1'b0;
            db_zp_din          <= 32'd0;
            db_zp_load         <= 1'b0;
            ct_compute_mode    <= 2'd0;
            ct_gap_req         <= 1'b0;
            ct_argmax_req      <= 1'b0;
            ct_core_req        <= 1'b0;
            ct_core_acc_clear  <= 1'b0;
            ct_core_process_out<= 1'b0;
            ct_core_frame_start<= 1'b0;
            pred_class_out     <= 4'd0;
            classification_valid <= 1'b0;
        end else begin
            // Default: deassert single-cycle pulses
            db_pixel_load       <= 1'b0;
            db_weight_load      <= 1'b0;
            db_bias_load        <= 1'b0;
            db_mult_load        <= 1'b0;
            db_shift_load       <= 1'b0;
            db_zp_load          <= 1'b0;
            ct_gap_req          <= 1'b0;
            ct_argmax_req       <= 1'b0;
            ct_core_req         <= 1'b0;
            ct_core_acc_clear   <= 1'b0;
            ct_core_process_out <= 1'b0;
            ct_core_frame_start <= 1'b0;
            classification_valid <= 1'b0;

            case (state)

            // ============================================================
            // IDLE
            // ============================================================
            S_IDLE: begin
                done <= 1'b0;
                if (start) begin
                    gap_oc         <= 6'd0;
                    gap_sp         <= 4'd0;
                    ct_compute_mode <= 2'd1;  // GAP mode
                    state          <= S_GAP_READ;
                end
            end

            // ============================================================
            // GAP PHASE (compute_mode = 1)
            // ============================================================

            // Start reading Conv3 pixel from activation buffer
            S_GAP_READ: begin
                act_rd_addr    <= cfg_gap_rd_base + {7'd0, gap_sp} * GAP_OC_WORDS[3:0] + (gap_oc >> 2);
                act_rd_request <= 1'b1;
                state          <= S_GAP_WAIT;
            end

            // Wait for activation buffer valid
            S_GAP_WAIT: begin
                if (act_rd_valid) begin
                    act_rd_request <= 1'b0;
                    captured_data  <= act_rd_dout;
                    state          <= S_GAP_LOAD;
                end
            end

            // Load pixel into data_bus
            S_GAP_LOAD: begin
                db_pixel_din      <= captured_data;
                db_pixel_load     <= 1'b1;
                db_pixel_byte_sel <= gap_oc[1:0];
                state             <= S_GAP_REQ;
            end

            // Pulse gap_req and advance spatial counter
            S_GAP_REQ: begin
                ct_gap_req <= 1'b1;
                if (gap_sp == GAP_SPATIAL - 1) begin
                    // Last spatial position for this OC
                    gap_sp <= 4'd0;
                    state  <= S_GAP_VALID;
                end else begin
                    gap_sp <= gap_sp + 4'd1;
                    state  <= S_GAP_READ;
                end
            end

            // Wait 1 cycle for gap valid to propagate
            S_GAP_VALID: begin
                state <= S_GAP_WRITE;
            end

            // Write GAP result to activation buffer
            S_GAP_WRITE: begin
                if (ct_valid_out) begin
                    act_wr_addr    <= cfg_gap_wr_base + {5'd0, gap_oc};
                    act_wr_din     <= ct_data_out_32b;
                    act_wr_wmask   <= 4'b1111;
                    act_wr_request <= 1'b1;
                    state          <= S_GAP_WR_WAIT;
                end
            end

            // Wait for write handshake
            S_GAP_WR_WAIT: begin
                if (act_wr_valid) begin
                    act_wr_request <= 1'b0;
                    gap_oc <= gap_oc + 6'd1;
                    if (gap_oc + 6'd1 == GAP_NUM_OC) begin
                        // GAP phase done, transition to FC
                        state <= S_FC_SHIFT;
                    end else begin
                        state <= S_GAP_READ;
                    end
                end
            end

            // ============================================================
            // FC PHASE (compute_mode = 0, OC-parallel)
            // ============================================================

            // Load shift (once for all FC groups)
            S_FC_SHIFT: begin
                ct_compute_mode <= 2'd0;  // Core parallel mode
                db_shift_din    <= cfg_fc_shift;
                db_shift_load   <= 1'b1;
                fc_oc_group     <= 2'd0;
                fc_cfg_cnt      <= 4'd0;
                state           <= S_FC_FRAME;
            end

            // Pulse frame_start for new OC group
            S_FC_FRAME: begin
                ct_core_frame_start <= 1'b1;
                fc_input            <= 6'd0;
                fc_cfg_cnt          <= 4'd0;
                state               <= S_FC_CFG_RD;
            end

            // Read config param from param_memory
            S_FC_CFG_RD: begin
                param_addr    <= fc_cfg_param_addr;
                param_request <= 1'b1;
                state         <= S_FC_CFG_WAIT;
            end

            // Wait for param_valid, route to data_bus
            S_FC_CFG_WAIT: begin
                if (param_valid) begin
                    param_request <= 1'b0;

                    // Route to correct data_bus channel (OC-parallel config)
                    if (fc_cfg_cnt < 4) begin
                        db_bias_din      <= param_dout;
                        db_bias_load     <= 1'b1;
                        db_bias_lane_sel <= fc_cfg_cnt[1:0];
                    end else if (fc_cfg_cnt < 8) begin
                        db_mult_din      <= param_dout;
                        db_mult_load     <= 1'b1;
                        db_mult_lane_sel <= fc_cfg_cnt[1:0];
                    end else begin
                        db_zp_din  <= param_dout;
                        db_zp_load <= 1'b1;
                    end

                    fc_cfg_cnt <= fc_cfg_cnt + 4'd1;
                    if (fc_cfg_cnt + 4'd1 == FC_CFG_COUNT) begin
                        state <= S_FC_PIX_RD;
                    end else begin
                        state <= S_FC_CFG_RD;
                    end
                end
            end

            // Read GAP value from activation buffer
            S_FC_PIX_RD: begin
                act_rd_addr    <= cfg_gap_wr_base + {5'd0, fc_input};
                act_rd_request <= 1'b1;
                state          <= S_FC_PIX_WAIT;
            end

            // Wait for pixel data
            S_FC_PIX_WAIT: begin
                if (act_rd_valid) begin
                    act_rd_request <= 1'b0;
                    captured_data  <= act_rd_dout;
                    state          <= S_FC_WT_RD;
                end
            end

            // Read weight from param_memory
            S_FC_WT_RD: begin
                param_addr    <= cfg_fc_weight_base + {5'd0, fc_oc_group} * 6'd32 + {5'd0, fc_input};
                param_request <= 1'b1;
                state         <= S_FC_WT_WAIT;
            end

            // Wait for weight data
            S_FC_WT_WAIT: begin
                if (param_valid) begin
                    param_request   <= 1'b0;
                    weight_captured <= param_dout;
                    state           <= S_FC_LOAD;
                end
            end

            // Load pixel and weight into data_bus
            S_FC_LOAD: begin
                db_pixel_din      <= captured_data;
                db_pixel_load     <= 1'b1;
                db_pixel_byte_sel <= 2'd0;  // GAP values in byte 0
                db_weight_din     <= weight_captured;
                db_weight_load    <= 1'b1;
                state             <= S_FC_REQ;
            end

            // Pulse core_req
            S_FC_REQ: begin
                ct_core_req       <= 1'b1;
                ct_core_acc_clear <= (fc_input == 6'd0) ? 1'b1 : 1'b0;
                fc_input <= fc_input + 6'd1;
                if (fc_input + 6'd1 == FC_NUM_INPUTS) begin
                    state <= S_FC_PROC;
                end else begin
                    state <= S_FC_PIX_RD;
                end
            end

            // Pulse process_out
            S_FC_PROC: begin
                ct_core_process_out <= 1'b1;
                state               <= S_FC_WVALID;
            end

            // Wait 1 cycle for valid propagation
            S_FC_WVALID: begin
                state <= S_FC_WRITE;
            end

            // Write FC result
            S_FC_WRITE: begin
                if (ct_valid_out) begin
                    act_wr_addr    <= cfg_fc_wr_base + {9'd0, fc_oc_group};
                    act_wr_din     <= ct_data_out_32b;
                    act_wr_wmask   <= 4'b1111;
                    act_wr_request <= 1'b1;
                    state          <= S_FC_WR_WAIT;
                end
            end

            // Wait for write handshake
            S_FC_WR_WAIT: begin
                if (act_wr_valid) begin
                    act_wr_request <= 1'b0;
                    fc_oc_group <= fc_oc_group + 2'd1;
                    if (fc_oc_group + 2'd1 == FC_NUM_GROUPS) begin
                        // FC done, start ArgMax
                        arg_logit <= 4'd0;
                        state     <= S_ARG_READ;
                    end else begin
                        state <= S_FC_FRAME;
                    end
                end
            end

            // ============================================================
            // ARGMAX PHASE (compute_mode = 2)
            // ============================================================

            // Read FC logit word from activation buffer
            S_ARG_READ: begin
                ct_compute_mode <= 2'd2;
                act_rd_addr     <= cfg_fc_wr_base + {9'd0, arg_logit[3:2]};
                act_rd_request  <= 1'b1;
                state           <= S_ARG_WAIT;
            end

            // Wait for data
            S_ARG_WAIT: begin
                if (act_rd_valid) begin
                    act_rd_request <= 1'b0;
                    captured_data  <= act_rd_dout;
                    state          <= S_ARG_LOAD;
                end
            end

            // Load pixel (logit byte)
            S_ARG_LOAD: begin
                db_pixel_din      <= captured_data;
                db_pixel_load     <= 1'b1;
                db_pixel_byte_sel <= arg_logit[1:0];
                state             <= S_ARG_REQ;
            end

            // Pulse argmax_req
            S_ARG_REQ: begin
                ct_argmax_req <= 1'b1;
                arg_logit <= arg_logit + 4'd1;
                if (arg_logit + 4'd1 == ARG_NUM_CLASSES) begin
                    state <= S_ARG_WDONE;
                end else begin
                    state <= S_ARG_READ;
                end
            end

            // Wait for classification_done
            S_ARG_WDONE: begin
                if (ct_classification_done) begin
                    pred_class_out       <= ct_pred_class;
                    classification_valid <= 1'b1;
                    state                <= S_DONE;
                end
            end

            // ============================================================
            // DONE
            // ============================================================
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
