// -----------------------------------------------------------------------------
// bmp24_stream_decoder.v
// D02: 24-bit BI_RGB BMP pixel-stream decoder.
//
// Input contract:
//   - D01 has already consumed the BMP/file/info headers.
//   - in_data begins at pixel_data_offset and contains bottom-up BGR888 rows.
//   - Each source row contains width*3 pixel bytes followed by row padding.
//   - row_stride is supplied by D01.
//
// Output contract:
//   - pixels are emitted left-to-right, top-to-bottom;
//   - BMP bottom-up source rows are mapped to image y = height-1-row_index;
//   - BGR888 is converted to RGB565;
//   - line_done pulses after every output row; image_done pulses once after the
//     final row; error_code is latched on failure.
//
// D02 deliberately does not claim top-down support. A top_down header is
// rejected with ERR_TOP_DOWN_UNSUPPORTED until a separately tested mode exists.
// -----------------------------------------------------------------------------
module bmp24_stream_decoder #(
    parameter integer TIMEOUT_CYCLES = 1048576
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        start,
    // Abort is asserted by a new top-level image LOAD. It synchronously drops
    // any stale decoder transaction before the replacement header is parsed.
    input  wire        abort,

    // D01 header outputs.
    input  wire        header_valid,
    input  wire [11:0] image_width,
    input  wire [11:0] image_height,
    input  wire        top_down,
    input  wire [31:0] row_stride,

    // C06 pixel-byte stream, beginning at pixel_data_offset.
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_last,
    output wire        in_ready,

    input  wire        pixel_ready,
    output wire        busy,
    output reg         pixel_valid,
    output reg  [11:0] pixel_x,
    output reg  [11:0] pixel_y,
    output reg  [15:0] pixel_rgb565,
    output reg         line_done,
    output reg         image_done,
    output reg  [7:0]  error_code
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_B   = 3'd1;
    localparam [2:0] ST_G   = 3'd2;
    localparam [2:0] ST_R   = 3'd3;
    localparam [2:0] ST_PAD = 3'd4;
    localparam [2:0] ST_DONE = 3'd5;
    localparam [2:0] ST_ERROR = 3'd6;
    localparam [2:0] ST_TRAIL = 3'd7;

    localparam [7:0] ERR_HEADER = 8'h01;
    localparam [7:0] ERR_DIMENSION = 8'h02;
    localparam [7:0] ERR_STRIDE = 8'h03;
    localparam [7:0] ERR_TRUNCATED = 8'h04;
    localparam [7:0] ERR_TIMEOUT = 8'h05;
    localparam [7:0] ERR_TOP_DOWN_UNSUPPORTED = 8'h06;

    reg [2:0] state;
    reg [11:0] width_reg;
    reg [11:0] height_reg;
    reg [31:0] stride_reg;
    reg [15:0] row_byte_index;
    reg [11:0] source_row_index;
    reg [11:0] x_reg;
    reg [7:0] blue_reg;
    reg [7:0] green_reg;
    reg [31:0] wait_count;

    wire [31:0] pixel_bytes_per_row = {20'd0, width_reg} * 32'd3;
    wire [31:0] pad_bytes_per_row = stride_reg - pixel_bytes_per_row;
    wire [11:0] bottom_up_y = height_reg - 1'b1 - source_row_index;
    wire [15:0] rgb565_current = {in_data[7:3], green_reg[7:5],
                                   green_reg[4:2], blue_reg[7:3]};

    assign busy = (state != ST_IDLE) && (state != ST_DONE) && (state != ST_ERROR);
    assign in_ready = (((state == ST_B) || (state == ST_G) ||
                       (state == ST_R) || (state == ST_PAD) ||
                       (state == ST_TRAIL)) &&
                      ((state != ST_R) || pixel_ready));

    task fail;
        input [7:0] code;
        begin
            error_code <= code;
            state <= ST_ERROR;
        end
    endtask

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n || abort) begin
            state           <= ST_IDLE;
            width_reg       <= 12'd0;
            height_reg      <= 12'd0;
            stride_reg      <= 32'd0;
            row_byte_index  <= 16'd0;
            source_row_index<= 12'd0;
            x_reg           <= 12'd0;
            blue_reg        <= 8'd0;
            green_reg       <= 8'd0;
            wait_count      <= 32'd0;
            pixel_valid     <= 1'b0;
            pixel_x         <= 12'd0;
            pixel_y         <= 12'd0;
            pixel_rgb565    <= 16'd0;
            line_done       <= 1'b0;
            image_done      <= 1'b0;
            error_code      <= 8'd0;
        end else begin
            pixel_valid <= 1'b0;
            line_done   <= 1'b0;
            image_done  <= 1'b0;

            case (state)
                ST_IDLE, ST_DONE, ST_ERROR: begin
                    if (start) begin
                        error_code <= 8'd0;
                        wait_count <= 32'd0;
                        if (!header_valid) begin
                            fail(ERR_HEADER);
                        end else if (top_down) begin
                            fail(ERR_TOP_DOWN_UNSUPPORTED);
                        end else if ((image_width == 12'd0) ||
                                     (image_height == 12'd0)) begin
                            fail(ERR_DIMENSION);
                        end else if (row_stride < ({20'd0, image_width} * 32'd3) ||
                                     ((row_stride & 32'd3) != 0)) begin
                            fail(ERR_STRIDE);
                        end else begin
                            width_reg        <= image_width;
                            height_reg       <= image_height;
                            stride_reg       <= row_stride;
                            row_byte_index   <= 16'd0;
                            source_row_index <= 12'd0;
                            x_reg            <= 12'd0;
                            state            <= ST_B;
                        end
                    end
                end

                ST_B: begin
                    if (in_valid && in_ready) begin
                        // EOF qualifies this accepted byte only. B cannot be
                        // the final byte of a complete BGR pixel.
                        if (in_last) begin
                            fail(ERR_TRUNCATED);
                        end else begin
                        wait_count     <= 32'd0;
                        blue_reg       <= in_data;
                        row_byte_index <= row_byte_index + 1'b1;
                        state          <= ST_G;
                        end
                    end else if (wait_count >= TIMEOUT_CYCLES - 1) begin
                        fail(ERR_TIMEOUT);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_G: begin
                    if (in_valid && in_ready) begin
                        if (in_last) begin
                            fail(ERR_TRUNCATED);
                        end else begin
                        wait_count     <= 32'd0;
                        green_reg      <= in_data;
                        row_byte_index <= row_byte_index + 1'b1;
                        state          <= ST_R;
                        end
                    end else if (wait_count >= TIMEOUT_CYCLES - 1) begin
                        fail(ERR_TIMEOUT);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_R: begin
                    if (in_valid && in_ready) begin
                        // A valid final red byte may wait here while the
                        // SDRAM path is stalled. Inspect EOF on transfer.
                        if (in_last && ((x_reg != width_reg - 1'b1) ||
                            (source_row_index != height_reg - 1'b1) ||
                            (stride_reg != pixel_bytes_per_row))) begin
                            fail(ERR_TRUNCATED);
                        end else begin
                        wait_count     <= 32'd0;
                        pixel_valid    <= 1'b1;
                        pixel_x        <= x_reg;
                        pixel_y        <= bottom_up_y;
                        pixel_rgb565   <= {in_data[7:3], green_reg[7:5],
                                            green_reg[4:2], blue_reg[7:3]};
                        row_byte_index <= row_byte_index + 1'b1;
                        if (x_reg == width_reg - 1'b1) begin
                            x_reg <= 12'd0;
                            if (row_stride == pixel_bytes_per_row) begin
                                line_done <= 1'b1;
                                if (source_row_index == height_reg - 1'b1) begin
                                    image_done <= 1'b1;
                                    if (in_last)
                                        state <= ST_DONE;
                                    else
                                        state <= ST_TRAIL;
                                end else begin
                                    source_row_index <= source_row_index + 1'b1;
                                    row_byte_index <= 16'd0;
                                    state <= ST_B;
                                end
                            end else begin
                                state <= ST_PAD;
                            end
                        end else begin
                            x_reg <= x_reg + 1'b1;
                            state <= ST_B;
                        end
                        end
                    end else if (wait_count >= TIMEOUT_CYCLES - 1) begin
                        fail(ERR_TIMEOUT);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_PAD: begin
                    if (in_valid && in_ready) begin
                        if (in_last && ((row_byte_index != stride_reg - 1'b1) ||
                            (source_row_index != height_reg - 1'b1))) begin
                            fail(ERR_TRUNCATED);
                        end else begin
                        wait_count     <= 32'd0;
                        row_byte_index <= row_byte_index + 1'b1;
                        if (row_byte_index == stride_reg - 1'b1) begin
                            line_done <= 1'b1;
                            if (source_row_index == height_reg - 1'b1) begin
                                image_done <= 1'b1;
                                if (in_last)
                                    state <= ST_DONE;
                                else
                                    state <= ST_TRAIL;
                            end else begin
                                source_row_index <= source_row_index + 1'b1;
                                    row_byte_index <= 16'd0;
                                state <= ST_B;
                            end
                        end
                        end
                    end else if (wait_count >= TIMEOUT_CYCLES - 1) begin
                        fail(ERR_TIMEOUT);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                // Pixel data is complete. Consume optional trailing file
                // bytes until the stream's in_last marker so a legal BMP with
                // metadata after the pixel array does not time out.
                ST_TRAIL: begin
                    if (in_valid && in_ready) begin
                        wait_count <= 32'd0;
                        if (in_last)
                            state <= ST_DONE;
                    end else if (wait_count >= TIMEOUT_CYCLES - 1) begin
                        fail(ERR_TIMEOUT);
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                default: begin
                    state <= ST_ERROR;
                end
            endcase
        end
    end
endmodule
