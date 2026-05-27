// conv_layer_ctrl.v — Convolution Layer Controller FSM
// Orchestrates a complete convolution layer (Conv1/Conv2/Conv3) by sequencing:
//   param_memory reads, activation_buffer reads/writes,
//   line_buffer fills, data_bus loads, and compute_top operations.
// First implementation: sequential (no pipelining). ~5 cycles per MAC op.

module conv_layer_ctrl (
    input  wire        clk,
    input  wire        reset,

    // --- Control ---
    input  wire        start,
    output reg         done,

    // --- Layer Configuration (set before start) ---
    input  wire [10:0] cfg_act_rd_base,
    input  wire [10:0] cfg_act_wr_base,
    input  wire [10:0] cfg_weight_base,
    input  wire [10:0] cfg_bias_base,
    input  wire [10:0] cfg_mult_base,
    input  wire [10:0] cfg_zp_base,
    input  wire [7:0]  cfg_shift,
    input  wire [4:0]  cfg_out_height,
    input  wire [4:0]  cfg_out_width,
    input  wire [4:0]  cfg_in_width,
    input  wire [4:0]  cfg_words_per_row,
    input  wire [2:0]  cfg_num_ic_groups,
    input  wire [5:0]  cfg_num_oc_steps,
    input  wire        cfg_is_ic_parallel,
    input  wire        cfg_relu_en,
    input  wire        cfg_pool_en,
    input  wire        cfg_pixel_packed,  // 1=input pixels packed 4/word (Conv1 only)

    // --- Input Activation Buffer (read port) ---
    output reg  [10:0] act_rd_addr,
    output reg         act_rd_request,
    output wire        act_rd_read_writeb,
    input  wire [31:0] act_rd_dout,
    input  wire        act_rd_valid,

    // --- Output Activation Buffer (write port) ---
    output reg  [10:0] act_wr_addr,
    output reg  [31:0] act_wr_din,
    output reg  [3:0]  act_wr_wmask,
    output reg         act_wr_request,
    output wire        act_wr_read_writeb,
    input  wire        act_wr_valid,

    // --- Param Memory (read port) ---
    output reg  [10:0] param_addr,
    output reg         param_request,
    output wire        param_read_writeb,
    input  wire [31:0] param_dout,
    input  wire        param_valid,

    // --- Line Buffer ---
    output reg  [31:0] lb_wr_data,
    output reg         lb_wr_en,
    output reg  [1:0]  lb_wr_row,
    output reg  [4:0]  lb_wr_addr,
    output wire [1:0]  lb_rd_row,
    output wire [4:0]  lb_rd_addr,
    input  wire [31:0] lb_rd_data,
    output reg         lb_row_advance,

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
    output reg         ct_core_req,
    output reg         ct_core_acc_clear,
    output reg         ct_core_process_out,
    output reg         ct_core_frame_start,
    output wire [5:0]  ct_core_img_width,
    input  wire [31:0] ct_data_out_32b,
    input  wire        ct_valid_out,

    // --- Data Bus Result Path ---
    output reg  [1:0]  db_result_byte_pos
);

    // ================================================================
    // Fixed assigns
    // ================================================================
    assign act_rd_read_writeb = 1'b1;
    assign act_wr_read_writeb = 1'b0;
    assign param_read_writeb  = 1'b1;
    assign ct_core_img_width  = {1'b0, cfg_out_width};

    // ================================================================
    // FSM States
    // ================================================================
    localparam [3:0]
        S_IDLE         = 4'd0,
        S_FRAME_START  = 4'd1,
        S_LOAD_SHIFT   = 4'd2,
        S_CFG_READ     = 4'd3,
        S_CFG_WAIT     = 4'd4,
        S_FILL_READ    = 4'd5,
        S_FILL_WAIT    = 4'd6,
        S_WEIGHT_READ  = 4'd7,
        S_WEIGHT_WAIT  = 4'd8,
        S_LOAD_COMPUTE = 4'd9,
        S_CORE_REQ     = 4'd10,
        S_PROCESS_OUT  = 4'd11,
        S_WAIT_VALID   = 4'd12,
        S_WRITE_RESULT = 4'd13,
        S_WRITE_WAIT   = 4'd14,
        S_DONE         = 4'd15;

    reg [3:0] state;

    // ================================================================
    // Loop counters
    // ================================================================
    reg [5:0]  oc_step;
    reg [4:0]  out_row;
    reg [4:0]  out_col;
    reg [3:0]  kpos;
    reg [1:0]  kpos_row;
    reg [1:0]  kpos_col;
    reg [2:0]  ic_grp;

    // Line buffer fill
    reg [4:0]  fill_word;
    reg [1:0]  fill_row;
    reg [4:0]  fill_in_row;
    reg        fill_single_row;  // 1 = filling only row 2 (advance), 0 = filling rows 0-2

    // Config loading
    reg [3:0]  cfg_cnt;
    wire [3:0] cfg_cnt_max;
    assign cfg_cnt_max = cfg_is_ic_parallel ? 4'd3 : 4'd10;

    // Weight capture
    reg [31:0] weight_captured;

    // Pixel packing (packed mode: 4 pixels per SRAM word)
    reg [31:0] px_hold;   // latched SRAM word during sub-pixel expansion
    reg [1:0]  sub_px;    // sub-pixel index within packed word (0-3)

    // Write-back counter
    reg [10:0] wr_count;

    // ================================================================
    // Line buffer read ports (combinational)
    // ================================================================
    assign lb_rd_row  = kpos_row;
    assign lb_rd_addr = (out_col + kpos_col) * cfg_num_ic_groups + ic_grp[1:0];

    // ================================================================
    // Write address calculation
    // ================================================================
    wire [5:0] num_oc_words = cfg_num_oc_steps >> 2;
    wire [5:0] oc_word      = oc_step >> 2;

    wire [10:0] wr_addr_oc = cfg_act_wr_base + wr_count * cfg_num_oc_steps + oc_step;
    wire [10:0] wr_addr_ic = cfg_act_wr_base + wr_count * num_oc_words + oc_word;
    wire [10:0] wr_addr_calc = cfg_is_ic_parallel ? wr_addr_ic : wr_addr_oc;

    // ================================================================
    // Weight address calculation
    // ================================================================
    wire [10:0] weight_addr_calc = cfg_weight_base
        + oc_step * (9 * cfg_num_ic_groups)
        + kpos * cfg_num_ic_groups
        + ic_grp;

    // ================================================================
    // Fill address calculation
    // ================================================================
    wire [10:0] fill_addr_calc = cfg_act_rd_base
        + fill_in_row * cfg_words_per_row
        + fill_word;

    // ================================================================
    // Config address calculation
    // ================================================================
    reg [10:0] cfg_param_addr;
    always @(*) begin
        cfg_param_addr = 11'd0;
        if (!cfg_is_ic_parallel) begin
            // OC-parallel: cnt 0-3 bias, 4-7 mult, 8 zp
            if (cfg_cnt < 4)
                cfg_param_addr = cfg_bias_base + oc_step * 4 + cfg_cnt;
            else if (cfg_cnt < 8)
                cfg_param_addr = cfg_mult_base + oc_step * 4 + (cfg_cnt - 4);
            else
                cfg_param_addr = cfg_zp_base + oc_step;
        end else begin
            // IC-parallel: cnt 0 bias, 1 mult, 2 zp
            case (cfg_cnt)
                4'd0: cfg_param_addr = cfg_bias_base + oc_step;
                4'd1: cfg_param_addr = cfg_mult_base + oc_step;
                4'd2: cfg_param_addr = cfg_zp_base + (oc_step >> 2);
                default: cfg_param_addr = 11'd0;
            endcase
        end
    end

    // ================================================================
    // Main FSM
    // ================================================================
    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            done             <= 1'b0;
            oc_step          <= 6'd0;
            out_row          <= 5'd0;
            out_col          <= 5'd0;
            kpos             <= 4'd0;
            kpos_row         <= 2'd0;
            kpos_col         <= 2'd0;
            ic_grp           <= 3'd0;
            fill_word        <= 5'd0;
            fill_row         <= 2'd0;
            fill_in_row      <= 5'd0;
            fill_single_row  <= 1'b0;
            cfg_cnt          <= 4'd0;
            weight_captured  <= 32'd0;
            px_hold          <= 32'd0;
            sub_px           <= 2'd0;
            wr_count         <= 11'd0;
            // Outputs
            act_rd_addr      <= 11'd0;
            act_rd_request   <= 1'b0;
            act_wr_addr      <= 11'd0;
            act_wr_din       <= 32'd0;
            act_wr_wmask     <= 4'd0;
            act_wr_request   <= 1'b0;
            param_addr       <= 11'd0;
            param_request    <= 1'b0;
            lb_wr_data       <= 32'd0;
            lb_wr_en         <= 1'b0;
            lb_wr_row        <= 2'd0;
            lb_wr_addr       <= 5'd0;
            lb_row_advance   <= 1'b0;
            db_pixel_din     <= 32'd0;
            db_pixel_load    <= 1'b0;
            db_pixel_byte_sel<= 2'd0;
            db_weight_din    <= 32'd0;
            db_weight_load   <= 1'b0;
            db_bias_din      <= 32'd0;
            db_bias_load     <= 1'b0;
            db_bias_lane_sel <= 2'd0;
            db_mult_din      <= 32'd0;
            db_mult_load     <= 1'b0;
            db_mult_lane_sel <= 2'd0;
            db_shift_din     <= 8'd0;
            db_shift_load    <= 1'b0;
            db_zp_din        <= 32'd0;
            db_zp_load       <= 1'b0;
            ct_core_req      <= 1'b0;
            ct_core_acc_clear<= 1'b0;
            ct_core_process_out <= 1'b0;
            ct_core_frame_start <= 1'b0;
            db_result_byte_pos  <= 2'd0;
        end else begin
            // Default: deassert single-cycle pulses
            lb_wr_en            <= 1'b0;
            lb_row_advance      <= 1'b0;
            db_pixel_load       <= 1'b0;
            db_weight_load      <= 1'b0;
            db_bias_load        <= 1'b0;
            db_mult_load        <= 1'b0;
            db_shift_load       <= 1'b0;
            db_zp_load          <= 1'b0;
            ct_core_req         <= 1'b0;
            ct_core_acc_clear   <= 1'b0;
            ct_core_process_out <= 1'b0;
            ct_core_frame_start <= 1'b0;

            case (state)

            // --------------------------------------------------------
            S_IDLE: begin
                done <= 1'b0;
                if (start) begin
                    oc_step     <= 6'd0;
                    out_row     <= 5'd0;
                    out_col     <= 5'd0;
                    wr_count    <= 11'd0;
                    state       <= S_FRAME_START;
                end
            end

            // --------------------------------------------------------
            S_FRAME_START: begin
                ct_core_frame_start <= 1'b1;
                // Setup initial fill
                fill_row        <= 2'd0;
                fill_word       <= 5'd0;
                sub_px          <= 2'd0;
                fill_in_row     <= out_row;  // first row to load = out_row + 0
                fill_single_row <= 1'b0;
                wr_count        <= 11'd0;
                state           <= S_LOAD_SHIFT;
            end

            // --------------------------------------------------------
            S_LOAD_SHIFT: begin
                db_shift_din  <= cfg_shift;
                db_shift_load <= 1'b1;
                cfg_cnt       <= 4'd0;
                state         <= S_CFG_READ;
            end

            // --------------------------------------------------------
            S_CFG_READ: begin
                param_addr    <= cfg_param_addr;
                param_request <= 1'b1;
                state         <= S_CFG_WAIT;
            end

            // --------------------------------------------------------
            S_CFG_WAIT: begin
                if (param_valid) begin
                    param_request <= 1'b0;

                    // Route captured data to correct data_bus channel
                    if (!cfg_is_ic_parallel) begin
                        // OC-parallel config
                        if (cfg_cnt < 4) begin
                            db_bias_din      <= param_dout;
                            db_bias_load     <= 1'b1;
                            db_bias_lane_sel <= cfg_cnt[1:0];
                        end else if (cfg_cnt < 8) begin
                            db_mult_din      <= param_dout;
                            db_mult_load     <= 1'b1;
                            db_mult_lane_sel <= cfg_cnt[1:0];
                        end else begin
                            db_zp_din  <= param_dout;
                            db_zp_load <= 1'b1;
                        end
                    end else begin
                        // IC-parallel config
                        case (cfg_cnt)
                            4'd0: begin
                                db_bias_din      <= param_dout;
                                db_bias_load     <= 1'b1;
                                db_bias_lane_sel <= 2'd0;
                            end
                            4'd1: begin
                                db_mult_din      <= param_dout;
                                db_mult_load     <= 1'b1;
                                db_mult_lane_sel <= 2'd0;
                            end
                            4'd2: begin
                                // Extract correct byte for this oc_step
                                case (oc_step[1:0])
                                    2'd0: db_zp_din <= {4{param_dout[ 7: 0]}};
                                    2'd1: db_zp_din <= {4{param_dout[15: 8]}};
                                    2'd2: db_zp_din <= {4{param_dout[23:16]}};
                                    2'd3: db_zp_din <= {4{param_dout[31:24]}};
                                endcase
                                db_zp_load <= 1'b1;
                            end
                            default: ;
                        endcase
                    end

                    cfg_cnt <= cfg_cnt + 4'd1;
                    if (cfg_cnt + 4'd1 == cfg_cnt_max) begin
                        // Config done, start line buffer fill
                        fill_row    <= 2'd0;
                        fill_word   <= 5'd0;
                        sub_px      <= 2'd0;
                        fill_in_row <= out_row;
                        state       <= S_FILL_READ;
                    end else begin
                        state <= S_CFG_READ;
                    end
                end
            end

            // --------------------------------------------------------
            S_FILL_READ: begin
                act_rd_addr    <= fill_addr_calc;
                act_rd_request <= 1'b1;
                state          <= S_FILL_WAIT;
            end

            // --------------------------------------------------------
            S_FILL_WAIT: begin
                // Packed mode sub-pixel path: px_hold already latched, no SRAM read
                if (cfg_pixel_packed && sub_px > 2'd0) begin
                    lb_wr_data <= px_hold;
                    lb_wr_en   <= 1'b1;
                    lb_wr_row  <= fill_row;
                    lb_wr_addr <= {fill_word[2:0], sub_px}; // pixel index = word*4+sub_px

                    if (sub_px == 2'd3) begin
                        // Last sub-pixel of this SRAM word — advance fill_word
                        sub_px <= 2'd0;
                        if (fill_word + 5'd1 == cfg_words_per_row) begin
                            fill_word <= 5'd0;
                            if (fill_single_row) begin
                                fill_single_row <= 1'b0;
                                kpos     <= 4'd0;
                                kpos_row <= 2'd0;
                                kpos_col <= 2'd0;
                                ic_grp   <= 3'd0;
                                state    <= S_WEIGHT_READ;
                            end else if (fill_row == 2'd2) begin
                                kpos     <= 4'd0;
                                kpos_row <= 2'd0;
                                kpos_col <= 2'd0;
                                ic_grp   <= 3'd0;
                                state    <= S_WEIGHT_READ;
                            end else begin
                                fill_row    <= fill_row + 2'd1;
                                fill_in_row <= fill_in_row + 5'd1;
                                state       <= S_FILL_READ;
                            end
                        end else begin
                            fill_word <= fill_word + 5'd1;
                            state     <= S_FILL_READ;
                        end
                    end else begin
                        sub_px <= sub_px + 2'd1;
                        // Stay in S_FILL_WAIT for next sub-pixel
                    end

                end else if (act_rd_valid) begin
                    act_rd_request <= 1'b0;
                    px_hold        <= act_rd_dout; // latch for packed sub-pixels 1-3
                    lb_wr_en       <= 1'b1;
                    lb_wr_row      <= fill_row;

                    if (cfg_pixel_packed) begin
                        // Sub-pixel 0: write packed word to lb[fill_word*4+0]
                        lb_wr_data <= act_rd_dout;
                        lb_wr_addr <= {fill_word[2:0], 2'b00};
                        sub_px     <= 2'd1;
                        // Stay in S_FILL_WAIT to process sub-pixels 1-3
                    end else begin
                        // Non-packed: standard one-pixel-per-word fill
                        lb_wr_data <= act_rd_dout;
                        lb_wr_addr <= fill_word;

                        if (fill_word + 5'd1 == cfg_words_per_row) begin
                            fill_word <= 5'd0;
                            if (fill_single_row) begin
                                fill_single_row <= 1'b0;
                                kpos     <= 4'd0;
                                kpos_row <= 2'd0;
                                kpos_col <= 2'd0;
                                ic_grp   <= 3'd0;
                                state    <= S_WEIGHT_READ;
                            end else if (fill_row == 2'd2) begin
                                kpos     <= 4'd0;
                                kpos_row <= 2'd0;
                                kpos_col <= 2'd0;
                                ic_grp   <= 3'd0;
                                state    <= S_WEIGHT_READ;
                            end else begin
                                fill_row    <= fill_row + 2'd1;
                                fill_in_row <= fill_in_row + 5'd1;
                                state       <= S_FILL_READ;
                            end
                        end else begin
                            fill_word <= fill_word + 5'd1;
                            state     <= S_FILL_READ;
                        end
                    end
                end
            end

            // --------------------------------------------------------
            S_WEIGHT_READ: begin
                param_addr    <= weight_addr_calc;
                param_request <= 1'b1;
                state         <= S_WEIGHT_WAIT;
            end

            // --------------------------------------------------------
            S_WEIGHT_WAIT: begin
                if (param_valid) begin
                    param_request   <= 1'b0;
                    weight_captured <= param_dout;
                    state           <= S_LOAD_COMPUTE;
                end
            end

            // --------------------------------------------------------
            S_LOAD_COMPUTE: begin
                // Load pixel from line buffer (combinational read already available)
                // In packed mode each lb word holds 4 pixels; byte_sel picks the right one.
                db_pixel_din      <= lb_rd_data;
                db_pixel_load     <= 1'b1;
                db_pixel_byte_sel <= cfg_pixel_packed ? lb_rd_addr[1:0] : 2'd0;

                // Load weight
                db_weight_din  <= weight_captured;
                db_weight_load <= 1'b1;

                state <= S_CORE_REQ;
            end

            // --------------------------------------------------------
            S_CORE_REQ: begin
                ct_core_req       <= 1'b1;
                ct_core_acc_clear <= (kpos == 4'd0 && ic_grp == 3'd0) ? 1'b1 : 1'b0;

                // Advance inner loop: ic_grp first, then kpos
                if (ic_grp + 3'd1 == cfg_num_ic_groups) begin
                    ic_grp <= 3'd0;
                    if (kpos == 4'd8) begin
                        // All 9 kernel positions done
                        kpos     <= 4'd0;
                        kpos_row <= 2'd0;
                        kpos_col <= 2'd0;
                        state    <= S_PROCESS_OUT;
                    end else begin
                        // Next kernel position
                        if (kpos_col == 2'd2) begin
                            kpos_col <= 2'd0;
                            kpos_row <= kpos_row + 2'd1;
                        end else begin
                            kpos_col <= kpos_col + 2'd1;
                        end
                        kpos  <= kpos + 4'd1;
                        state <= S_WEIGHT_READ;
                    end
                end else begin
                    ic_grp <= ic_grp + 3'd1;
                    state  <= S_WEIGHT_READ;
                end
            end

            // --------------------------------------------------------
            S_PROCESS_OUT: begin
                ct_core_process_out <= 1'b1;
                db_result_byte_pos  <= oc_step[1:0];
                state               <= S_WAIT_VALID;
            end

            // --------------------------------------------------------
            // Wait 1 cycle for post_proc valid to propagate
            S_WAIT_VALID: begin
                state <= S_WRITE_RESULT;
            end

            // --------------------------------------------------------
            S_WRITE_RESULT: begin
                if (ct_valid_out) begin
                    // Write result to output activation buffer
                    act_wr_addr <= wr_addr_calc;

                    if (cfg_is_ic_parallel) begin
                        act_wr_din   <= {4{ct_data_out_32b[7:0]}};
                        act_wr_wmask <= (4'b0001 << oc_step[1:0]);
                    end else begin
                        act_wr_din   <= ct_data_out_32b;
                        act_wr_wmask <= 4'b1111;
                    end

                    act_wr_request <= 1'b1;
                    state          <= S_WRITE_WAIT;
                end else begin
                    // Pooling absorbed this pixel (no output)
                    // Advance to next pixel
                    if (out_col + 5'd1 == cfg_out_width) begin
                        out_col <= 5'd0;
                        if (out_row + 5'd1 == cfg_out_height) begin
                            // OC step done
                            out_row <= 5'd0;
                            if (oc_step + 6'd1 == cfg_num_oc_steps) begin
                                state <= S_DONE;
                            end else begin
                                oc_step <= oc_step + 6'd1;
                                state   <= S_FRAME_START;
                            end
                        end else begin
                            out_row <= out_row + 5'd1;
                            // Row advance + fill 1 new row
                            lb_row_advance  <= 1'b1;
                            fill_single_row <= 1'b1;
                            fill_row        <= 2'd2;
                            fill_word       <= 5'd0;
                            sub_px          <= 2'd0;
                            fill_in_row     <= out_row + 5'd3; // next row = current+1 + 2
                            state           <= S_FILL_READ;
                        end
                    end else begin
                        out_col <= out_col + 5'd1;
                        kpos     <= 4'd0;
                        kpos_row <= 2'd0;
                        kpos_col <= 2'd0;
                        ic_grp   <= 3'd0;
                        state    <= S_WEIGHT_READ;
                    end
                end
            end

            // --------------------------------------------------------
            S_WRITE_WAIT: begin
                if (act_wr_valid) begin
                    act_wr_request <= 1'b0;
                    wr_count       <= wr_count + 11'd1;

                    // Advance to next pixel
                    if (out_col + 5'd1 == cfg_out_width) begin
                        out_col <= 5'd0;
                        if (out_row + 5'd1 == cfg_out_height) begin
                            // OC step done
                            out_row <= 5'd0;
                            if (oc_step + 6'd1 == cfg_num_oc_steps) begin
                                state <= S_DONE;
                            end else begin
                                oc_step <= oc_step + 6'd1;
                                state   <= S_FRAME_START;
                            end
                        end else begin
                            out_row <= out_row + 5'd1;
                            lb_row_advance  <= 1'b1;
                            fill_single_row <= 1'b1;
                            fill_row        <= 2'd2;
                            fill_word       <= 5'd0;
                            sub_px          <= 2'd0;
                            fill_in_row     <= out_row + 5'd3;
                            state           <= S_FILL_READ;
                        end
                    end else begin
                        out_col  <= out_col + 5'd1;
                        kpos     <= 4'd0;
                        kpos_row <= 2'd0;
                        kpos_col <= 2'd0;
                        ic_grp   <= 3'd0;
                        state    <= S_WEIGHT_READ;
                    end
                end
            end

            // --------------------------------------------------------
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
