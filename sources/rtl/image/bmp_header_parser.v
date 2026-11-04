// -----------------------------------------------------------------------------
// bmp_header_parser.v
// D01: strict BMP file/info header parser for C06 byte streams.
//
// Supported first-version format:
//   - BM signature
//   - BITMAPINFOHEADER-compatible DIB size >= 40
//   - planes = 1
//   - bit_count = 24
//   - compression = BI_RGB (0)
//   - positive width, non-zero height (bottom-up or signed top-down height)
//   - width/height <= 4095 for the 12-bit downstream image interface
//   - row_stride = ceil(width*3/4)*4
//   - no compression/other bit-depth path is implemented
// -----------------------------------------------------------------------------
module bmp_header_parser #(
    parameter integer TIMEOUT_CYCLES = 1048576
) (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire        start,

    // C06 byte stream. The parser consumes header bytes only and deasserts
    // in_ready after success/error. in_data is the file byte order.
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    input  wire        in_last,
    output wire        in_ready,

    input  wire [31:0] file_size_bytes,

    output wire        busy,
    output reg         done,
    output reg         header_valid,
    output reg  [7:0]  error_code,

    output reg  [31:0] bmp_file_size,
    output reg  [31:0] pixel_data_offset,
    output reg  [31:0] dib_header_size,
    output reg signed [31:0] width_signed,
    output reg signed [31:0] height_signed,
    output reg  [11:0] image_width,
    output reg  [11:0] image_height,
    output reg         top_down,
    output reg  [15:0] planes,
    output reg  [15:0] bit_count,
    output reg  [31:0] compression,
    output reg  [31:0] size_image,
    output reg  [31:0] row_stride
);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_READ  = 2'd1;
    localparam [1:0] ST_DONE  = 2'd2;
    localparam [1:0] ST_ERROR = 2'd3;

    // Stable D01 error codes.
    localparam [7:0] ERR_SIGNATURE  = 8'h01;
    localparam [7:0] ERR_DIB_SIZE   = 8'h02;
    localparam [7:0] ERR_PLANES     = 8'h03;
    localparam [7:0] ERR_BIT_COUNT  = 8'h04;
    localparam [7:0] ERR_COMPRESSION= 8'h05;
    localparam [7:0] ERR_DIMENSION  = 8'h06;
    localparam [7:0] ERR_OFFSET     = 8'h07;
    localparam [7:0] ERR_SIZE       = 8'h08;
    localparam [7:0] ERR_TRUNCATED  = 8'h09;
    localparam [7:0] ERR_TIMEOUT    = 8'h0A;

    reg [1:0]  state;
    reg [5:0]  byte_index;
    reg [31:0] stream_wait_count;

    reg [7:0]  signature_lo;
    reg [7:0]  signature_hi;
    reg [31:0] file_size_raw;
    reg [7:0]  pixel_offset_b0;
    reg [7:0]  pixel_offset_b1;
    reg [7:0]  pixel_offset_b2;
    reg [7:0]  pixel_offset_b3;
    reg [31:0] dib_size_raw;
    reg [31:0] width_raw;
    reg [31:0] height_raw;
    reg [15:0] planes_raw;
    reg [15:0] bit_count_raw;
    reg [31:0] compression_raw;
    reg [31:0] size_image_raw;

    wire [31:0] pixel_offset_raw = {pixel_offset_b3, pixel_offset_b2,
                                    pixel_offset_b1, pixel_offset_b0};
    wire [31:0] height_abs = height_raw[31] ? (~height_raw + 32'd1) : height_raw;
    wire [13:0] width_times_3 =
        {2'd0, width_raw[11:0]} +
        {1'd0, width_raw[11:0]} +
        {1'd0, width_raw[11:0]};
    wire [13:0] row_stride_padded = width_times_3 + 14'd3;
    wire [13:0] row_stride_calc = {row_stride_padded[13:2], 2'b00};
    // Dimensions are complete by byte25; verdict is byte53, even without stalls.
    // Register each arithmetic boundary without delaying the public verdict.
    reg [13:0] stride_pipe;
    reg [11:0] height_pipe;
    reg [25:0] image_bytes_pipe;
    reg [32:0] file_end_pipe;
    wire [31:0] image_bytes_calc = {6'd0, image_bytes_pipe};
    wire [32:0] file_end_calc = file_end_pipe;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            stride_pipe <= 14'd0;
            height_pipe <= 12'd0;
            image_bytes_pipe <= 26'd0;
            file_end_pipe <= 33'd0;
        end else if (start) begin
            stride_pipe <= 14'd0;
            height_pipe <= 12'd0;
            image_bytes_pipe <= 26'd0;
            file_end_pipe <= 33'd0;
        end else begin
            stride_pipe <= row_stride_calc;
            height_pipe <= height_abs[11:0];
            image_bytes_pipe <= stride_pipe * height_pipe;
            file_end_pipe <= {1'b0, pixel_offset_raw} + {7'd0, image_bytes_pipe};
        end
    end

    assign busy = (state == ST_READ);
    assign in_ready = (state == ST_READ);

    task fail;
        input [7:0] code;
        begin
            error_code <= code;
            header_valid <= 1'b0;
            done <= 1'b1;
            state <= ST_ERROR;
        end
    endtask

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            byte_index        <= 6'd0;
            stream_wait_count <= 32'd0;
            signature_lo      <= 8'd0;
            signature_hi      <= 8'd0;
            file_size_raw     <= 32'd0;
            pixel_offset_b0   <= 8'd0;
            pixel_offset_b1   <= 8'd0;
            pixel_offset_b2   <= 8'd0;
            pixel_offset_b3   <= 8'd0;
            dib_size_raw      <= 32'd0;
            width_raw         <= 32'd0;
            height_raw        <= 32'd0;
            planes_raw        <= 16'd0;
            bit_count_raw     <= 16'd0;
            compression_raw   <= 32'd0;
            size_image_raw    <= 32'd0;
            done              <= 1'b0;
            header_valid      <= 1'b0;
            error_code        <= 8'd0;
            bmp_file_size     <= 32'd0;
            pixel_data_offset <= 32'd0;
            dib_header_size   <= 32'd0;
            width_signed      <= 32'sd0;
            height_signed     <= 32'sd0;
            image_width       <= 12'd0;
            image_height      <= 12'd0;
            top_down          <= 1'b0;
            planes            <= 16'd0;
            bit_count         <= 16'd0;
            compression       <= 32'd0;
            size_image        <= 32'd0;
            row_stride        <= 32'd0;
        end else begin
            done <= 1'b0;

            // A new file load aborts any stale header transaction. This is
            // required after a retry: otherwise an old ST_READ parser can
            // silently ignore the retry start and consume bytes from the new
            // file at the wrong header offset.
            if (start) begin
                state             <= ST_READ;
                byte_index        <= 6'd0;
                stream_wait_count <= 32'd0;
                header_valid      <= 1'b0;
                error_code        <= 8'd0;
                bmp_file_size     <= 32'd0;
                pixel_data_offset <= 32'd0;
                dib_header_size   <= 32'd0;
                width_signed      <= 32'sd0;
                height_signed     <= 32'sd0;
                image_width       <= 12'd0;
                image_height      <= 12'd0;
                top_down          <= 1'b0;
                planes            <= 16'd0;
                bit_count         <= 16'd0;
                compression       <= 32'd0;
                size_image        <= 32'd0;
                row_stride        <= 32'd0;
            end else begin
                case (state)
                ST_IDLE, ST_DONE, ST_ERROR: begin
                    if (start) begin
                        state             <= ST_READ;
                        byte_index        <= 6'd0;
                        stream_wait_count <= 32'd0;
                        header_valid      <= 1'b0;
                        error_code        <= 8'd0;
                        bmp_file_size     <= 32'd0;
                        pixel_data_offset <= 32'd0;
                        dib_header_size   <= 32'd0;
                        width_signed      <= 32'sd0;
                        height_signed     <= 32'sd0;
                        image_width       <= 12'd0;
                        image_height      <= 12'd0;
                        top_down          <= 1'b0;
                        planes            <= 16'd0;
                        bit_count         <= 16'd0;
                        compression       <= 32'd0;
                        size_image        <= 32'd0;
                        row_stride        <= 32'd0;
                    end
                end

                ST_READ: begin
                    if (in_valid && in_ready) begin
                        stream_wait_count <= 32'd0;
                        case (byte_index)
                            6'd0:  signature_lo    <= in_data;
                            6'd1:  signature_hi    <= in_data;
                            6'd2:  file_size_raw[7:0]   <= in_data;
                            6'd3:  file_size_raw[15:8]  <= in_data;
                            6'd4:  file_size_raw[23:16] <= in_data;
                            6'd5:  file_size_raw[31:24] <= in_data;
                            6'd10: pixel_offset_b0 <= in_data;
                            6'd11: pixel_offset_b1 <= in_data;
                            6'd12: pixel_offset_b2 <= in_data;
                            6'd13: pixel_offset_b3 <= in_data;
                            6'd14: dib_size_raw[7:0]   <= in_data;
                            6'd15: dib_size_raw[15:8]  <= in_data;
                            6'd16: dib_size_raw[23:16] <= in_data;
                            6'd17: dib_size_raw[31:24] <= in_data;
                            6'd18: width_raw[7:0]   <= in_data;
                            6'd19: width_raw[15:8]  <= in_data;
                            6'd20: width_raw[23:16] <= in_data;
                            6'd21: width_raw[31:24] <= in_data;
                            6'd22: height_raw[7:0]   <= in_data;
                            6'd23: height_raw[15:8]  <= in_data;
                            6'd24: height_raw[23:16] <= in_data;
                            6'd25: height_raw[31:24] <= in_data;
                            6'd26: planes_raw[7:0]  <= in_data;
                            6'd27: planes_raw[15:8] <= in_data;
                            6'd28: bit_count_raw[7:0]  <= in_data;
                            6'd29: bit_count_raw[15:8] <= in_data;
                            6'd30: compression_raw[7:0]   <= in_data;
                            6'd31: compression_raw[15:8]  <= in_data;
                            6'd32: compression_raw[23:16] <= in_data;
                            6'd33: compression_raw[31:24] <= in_data;
                            6'd34: size_image_raw[7:0]   <= in_data;
                            6'd35: size_image_raw[15:8]  <= in_data;
                            6'd36: size_image_raw[23:16] <= in_data;
                            6'd37: size_image_raw[31:24] <= in_data;
                            default: begin end
                        endcase

                        if (in_last && (byte_index < 6'd53)) begin
                            fail(ERR_TRUNCATED);
                        end else if (byte_index == 6'd53) begin
                            if ({signature_hi, signature_lo} != 16'h4D42)
                                fail(ERR_SIGNATURE);
                            else if (dib_size_raw < 32'd40)
                                fail(ERR_DIB_SIZE);
                            else if (planes_raw != 16'd1)
                                fail(ERR_PLANES);
                            else if (bit_count_raw != 16'd24)
                                fail(ERR_BIT_COUNT);
                            else if (compression_raw != 32'd0)
                                fail(ERR_COMPRESSION);
                            else if ((width_raw == 32'd0) || width_raw[31] ||
                                     (height_abs == 32'd0) ||
                                     (width_raw > 32'd4095) ||
                                     (height_abs > 32'd4095))
                                fail(ERR_DIMENSION);
                            else if ((pixel_offset_raw < 32'd54) ||
                                     (file_size_raw < pixel_offset_raw))
                                fail(ERR_OFFSET);
                            else if ((file_size_bytes != 32'd0) &&
                                     (file_size_raw > file_size_bytes))
                                fail(ERR_SIZE);
                            else if (file_end_calc > {1'b0, file_size_raw})
                                fail(ERR_SIZE);
                            else if ((size_image_raw != 32'd0) &&
                                     (size_image_raw != image_bytes_calc))
                                fail(ERR_SIZE);
                            else begin
                                bmp_file_size     <= file_size_raw;
                                pixel_data_offset <= pixel_offset_raw;
                                dib_header_size   <= dib_size_raw;
                                width_signed      <= width_raw;
                                height_signed     <= height_raw;
                                image_width       <= width_raw[11:0];
                                image_height      <= height_abs[11:0];
                                top_down          <= height_raw[31];
                                planes            <= planes_raw;
                                bit_count         <= bit_count_raw;
                                compression       <= compression_raw;
                                size_image        <= size_image_raw;
                                row_stride        <= {18'd0, row_stride_calc};
                                header_valid      <= 1'b1;
                                error_code        <= 8'd0;
                                done              <= 1'b1;
                                state             <= ST_DONE;
                            end
                        end else if (byte_index < 6'd53) begin
                            byte_index <= byte_index + 1'b1;
                        end
                    end else if (stream_wait_count >= TIMEOUT_CYCLES - 1) begin
                        fail(ERR_TIMEOUT);
                    end else begin
                        stream_wait_count <= stream_wait_count + 1'b1;
                    end
                end

                default: begin
                    state <= ST_ERROR;
                end
                endcase
            end
        end
    end
endmodule
