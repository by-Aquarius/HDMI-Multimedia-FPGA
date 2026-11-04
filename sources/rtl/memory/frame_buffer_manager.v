// -----------------------------------------------------------------------------
// frame_buffer_manager.v
// D05: two-frame ownership, RGB565 word packing, and frame-boundary commit.
//
// Address contract: mem_wr_addr_word is a 21-bit SDRAM WORD address. One word
// is 32 bits/4 bytes. Two row-major RGB565 pixels are packed per word:
//   mem_wr_data[15:0]  = even-x pixel
//   mem_wr_data[31:16] = odd-x pixel
//
// FrameA base word = FRAME_A_BASE_WORD; FrameB base word = FRAME_B_BASE_WORD.
// pixel_last is an end-of-frame marker. Coordinates must be strictly row-major.
//
// The displayed frame is never written. load_frame_select always names the
// back buffer. It becomes show_frame_select only after a complete, error-free
// load, a swap_request, and a frame_boundary. Failed/timed-out loads leave the
// old show selection unchanged and invalidate the partially written back frame.
// -----------------------------------------------------------------------------
module frame_buffer_manager #(
    parameter integer FRAME_WIDTH         = 640,
    parameter integer FRAME_HEIGHT        = 480,
    parameter [20:0] FRAME_A_BASE_WORD    = 21'h00000,
    parameter [20:0] FRAME_B_BASE_WORD    = 21'h40000,
    parameter integer LOAD_TIMEOUT_CYCLES = 1000000,
    // 0: input y ascends 0..H-1; 1: input y descends H-1..0.
    parameter integer INPUT_BOTTOM_UP     = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        pixel_valid,
    output wire        pixel_ready,
    input  wire [15:0] pixel_rgb565,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire        pixel_last,
    input  wire [11:0] frame_width_i,
    input  wire [11:0] frame_height_i,

    input  wire        load_start,
    input  wire        load_abort,
    output reg         load_busy,
    output reg         load_done,
    output reg         load_error,
    output reg  [7:0]  load_error_detail,
    output reg         load_timeout,
    output reg         load_conflict,

    output reg         load_frame_select,
    output reg         show_frame_select,
    output reg  [1:0]  frame_ready,

    input  wire        swap_request,
    input  wire        frame_boundary,
    output reg         swap_ack,

    // D04-compatible, single-word write transaction interface.
    output wire        mem_wr_valid,
    input  wire        mem_wr_ready,
    output wire [20:0] mem_wr_addr_word,
    output wire [31:0] mem_wr_data,
    output wire [3:0]  mem_wr_strb,
    input  wire        mem_wr_done,
    input  wire        mem_wr_error
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_LOAD = 3'd1;
    localparam [2:0] ST_REQ  = 3'd2;
    localparam [2:0] ST_WAIT = 3'd3;
    localparam [7:0] DETAIL_NONE        = 8'd0;
    localparam [7:0] DETAIL_TIMEOUT     = 8'd2;
    localparam [7:0] DETAIL_COORDINATE  = 8'd3;
    localparam [7:0] DETAIL_MEM_WRITE   = 8'd4;
    localparam [7:0] DETAIL_BAD_STATE   = 8'd5;
    localparam [7:0] DETAIL_CONFLICT    = 8'd6;

    reg [2:0]  state;
    reg [31:0] load_timer;
    reg [11:0] expected_x;
    reg [11:0] expected_y;
    reg [15:0] first_pixel;
    reg        first_valid;

    reg        write_pending;
    reg        write_inflight;
    reg [20:0] pending_addr_word;
    reg [31:0] pending_data;
    reg        pending_last;
    reg        swap_pending;

    wire load_timeout_hit = (LOAD_TIMEOUT_CYCLES <= 1) ? 1'b1 :
                            (load_timer >= LOAD_TIMEOUT_CYCLES - 1);
    wire [31:0] pixel_word_offset =
                 ((pixel_y * FRAME_WIDTH) + pixel_x) >> 1;
    wire [20:0] selected_base_word = load_frame_select ?
                                      FRAME_B_BASE_WORD : FRAME_A_BASE_WORD;
    wire final_coordinate = (pixel_x == frame_width_i - 1'b1) &&
                            (pixel_y == (INPUT_BOTTOM_UP ? 12'd0 : frame_height_i - 1'b1));
    wire bad_stream_coordinate =
        (frame_width_i == 12'd0) || (frame_height_i == 12'd0) ||
        (frame_width_i > FRAME_WIDTH) || (frame_height_i > FRAME_HEIGHT) ||
        (pixel_x >= frame_width_i) ||
        (pixel_y >= frame_height_i) ||
        (pixel_x != expected_x) ||
        (pixel_y != expected_y) ||
        (!first_valid && pixel_x[0]) ||
        (first_valid && !pixel_x[0]) ||
        (pixel_last && !first_valid);

    assign pixel_ready       = load_busy && (state == ST_LOAD);
    assign mem_wr_valid      = write_pending;
    assign mem_wr_addr_word  = pending_addr_word;
    assign mem_wr_data       = pending_data;
    assign mem_wr_strb       = 4'b1111;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            load_timer        <= 32'd0;
            expected_x        <= 12'd0;
            // LOAD reinitializes this counter from the parsed image height.
            // Keep the asynchronous reset value constant so TD does not infer
            // an input-dependent asynchronous set alongside the reset.
            expected_y        <= 12'd0;
            first_pixel       <= 16'd0;
            first_valid       <= 1'b0;
            write_pending     <= 1'b0;
            write_inflight    <= 1'b0;
            pending_addr_word <= 21'd0;
            pending_data      <= 32'd0;
            pending_last      <= 1'b0;
            swap_pending      <= 1'b0;
            load_busy         <= 1'b0;
            load_done         <= 1'b0;
            load_error        <= 1'b0;
            load_error_detail <= DETAIL_NONE;
            load_timeout      <= 1'b0;
            load_conflict     <= 1'b0;
            // No memory contents are assumed valid after FPGA reset.
            // Neither SDRAM frame contains known pixels after FPGA reset.
            frame_ready       <= 2'b00;
            show_frame_select <= 1'b0;
            load_frame_select <= 1'b1;
            swap_ack          <= 1'b0;
        end else if (load_abort) begin
            state              <= ST_IDLE;
            load_busy          <= 1'b0;
            load_done          <= 1'b0;
            load_error         <= 1'b0;
            load_timeout       <= 1'b0;
            load_conflict      <= 1'b0;
            load_error_detail  <= DETAIL_NONE;
            load_timer         <= 32'd0;
            first_valid        <= 1'b0;
            write_pending      <= 1'b0;
            write_inflight     <= 1'b0;
            pending_last       <= 1'b0;
            swap_pending       <= 1'b0;
            swap_ack           <= 1'b0;
            // A file-open abort can precede the next load_start. After a swap,
            // load_frame_select still names the displayed front frame here.
            if (load_frame_select != show_frame_select)
                frame_ready[load_frame_select] <= 1'b0;
        end else begin
            load_done     <= 1'b0;
            load_error    <= 1'b0;
            load_timeout  <= 1'b0;
            load_conflict <= 1'b0;
            swap_ack      <= 1'b0;

            if (load_busy)
                load_timer <= load_timer + 1'b1;
            else
                load_timer <= 32'd0;

            if (swap_request)
                swap_pending <= 1'b1;

            // A second start is reported but cannot redirect/cancel the active
            // writer. Treat it as a duplicate protocol pulse rather than a
            // fatal load error: the upper request controller never issues a
            // legitimate concurrent LOAD, and aborting here would discard an
            // otherwise valid in-progress frame.
            if (load_start && load_busy) begin
                load_conflict <= 1'b1;
                load_error_detail <= DETAIL_CONFLICT;
            end

            case (state)
                ST_IDLE: begin
                    write_pending  <= 1'b0;
                    write_inflight <= 1'b0;
                    first_valid    <= 1'b0;

                    if (load_start && !load_busy) begin
                        // Always load the opposite buffer; invalidate it until
                        // all pixels and all SDRAM writes complete successfully.
                        load_frame_select <= ~show_frame_select;
                        frame_ready[~show_frame_select] <= 1'b0;
                        load_busy         <= 1'b1;
                        load_error_detail <= DETAIL_NONE;
                        load_timer        <= 32'd0;
                        expected_x        <= 12'd0;
                        expected_y        <= INPUT_BOTTOM_UP ? frame_height_i - 1'b1 : 12'd0;
                        first_valid       <= 1'b0;
                        pending_last      <= 1'b0;
                        state             <= ST_LOAD;
                    end else if (frame_boundary && swap_pending &&
                                 frame_ready[load_frame_select] &&
                                 (load_frame_select != show_frame_select) &&
                                 !load_busy) begin
                        show_frame_select <= load_frame_select;
                        swap_pending      <= 1'b0;
                        swap_ack          <= 1'b1;
                    end
                end

                ST_LOAD: begin
                    if (load_timeout_hit) begin
                        load_busy         <= 1'b0;
                        load_timeout      <= 1'b1;
                        load_error        <= 1'b1;
                        load_error_detail <= DETAIL_TIMEOUT;
                        frame_ready[load_frame_select] <= 1'b0;
                        swap_pending      <= 1'b0;
                        first_valid       <= 1'b0;
                        write_pending     <= 1'b0;
                        write_inflight    <= 1'b0;
                        state             <= ST_IDLE;
                        load_timer        <= 32'd0;
                    end else if (pixel_valid && pixel_ready) begin
                        if (bad_stream_coordinate ||
                            (pixel_last && !final_coordinate)) begin
                            load_busy         <= 1'b0;
                            load_error        <= 1'b1;
                            load_error_detail <= DETAIL_COORDINATE;
                            frame_ready[load_frame_select] <= 1'b0;
                            swap_pending      <= 1'b0;
                            first_valid       <= 1'b0;
                            write_pending     <= 1'b0;
                            write_inflight    <= 1'b0;
                            state             <= ST_IDLE;
                            load_timer        <= 32'd0;
                        end else begin
                            // Track strict row-major coordinates so omitted or
                            // duplicated pixels cannot mark a partial frame ready.
                            if (pixel_x == frame_width_i - 1'b1) begin
                                expected_x <= 12'd0;
                                if (INPUT_BOTTOM_UP) begin
                                    if (pixel_y != 0)
                                        expected_y <= pixel_y - 1'b1;
                                end else if (pixel_y != frame_height_i - 1'b1) begin
                                    expected_y <= pixel_y + 1'b1;
                                end
                            end else begin
                                expected_x <= pixel_x + 1'b1;
                            end

                            if (!first_valid) begin
                                first_pixel <= pixel_rgb565;
                                first_valid <= 1'b1;
                            end else begin
                                // Pair an even-x pixel with its odd-x partner.
                                pending_addr_word <= selected_base_word + pixel_word_offset[20:0];
                                pending_data      <= {pixel_rgb565, first_pixel};
                                pending_last      <= final_coordinate;
                                first_valid       <= 1'b0;
                                write_pending     <= 1'b1;
                                state             <= ST_REQ;
                            end
                        end
                    end
                end

                ST_REQ: begin
                    if (load_timeout_hit) begin
                        load_busy         <= 1'b0;
                        load_timeout      <= 1'b1;
                        load_error        <= 1'b1;
                        load_error_detail <= DETAIL_TIMEOUT;
                        frame_ready[load_frame_select] <= 1'b0;
                        swap_pending      <= 1'b0;
                        write_pending     <= 1'b0;
                        write_inflight    <= 1'b0;
                        state             <= ST_IDLE;
                        load_timer        <= 32'd0;
                    end else if (write_pending && mem_wr_ready) begin
                        write_pending  <= 1'b0;
                        write_inflight <= 1'b1;
                        state          <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (write_inflight && mem_wr_done) begin
                        write_inflight <= 1'b0;
                        if (mem_wr_error) begin
                            load_busy         <= 1'b0;
                            load_error        <= 1'b1;
                            load_error_detail <= DETAIL_MEM_WRITE;
                            frame_ready[load_frame_select] <= 1'b0;
                            swap_pending      <= 1'b0;
                            state             <= ST_IDLE;
                            load_timer        <= 32'd0;
                        end else if (pending_last) begin
                            load_busy         <= 1'b0;
                            load_done         <= 1'b1;
                            frame_ready[load_frame_select] <= 1'b1;
                            state             <= ST_IDLE;
                            load_timer        <= 32'd0;
                        end else begin
                            state <= ST_LOAD;
                        end
                    end else if (load_timeout_hit) begin
                        load_busy         <= 1'b0;
                        load_timeout      <= 1'b1;
                        load_error        <= 1'b1;
                        load_error_detail <= DETAIL_TIMEOUT;
                        frame_ready[load_frame_select] <= 1'b0;
                        swap_pending      <= 1'b0;
                        write_inflight    <= 1'b0;
                        state             <= ST_IDLE;
                        load_timer        <= 32'd0;
                    end
                end

                default: begin
                    state          <= ST_IDLE;
                    load_busy      <= 1'b0;
                    load_error     <= 1'b1;
                    load_error_detail <= DETAIL_BAD_STATE;
                    frame_ready[load_frame_select] <= 1'b0;
                    swap_pending   <= 1'b0;
                end
            endcase
        end
    end
endmodule



