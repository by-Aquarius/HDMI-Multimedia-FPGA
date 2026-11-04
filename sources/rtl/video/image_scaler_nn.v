// -----------------------------------------------------------------------------
// image_scaler_nn.v
// D07: fixed 2x nearest-neighbor scaler and centered black border mapper.
//
// Fixed geometry: source 640x480 -> output 1280x1024. The active image is
// y=32..991; y=0..31 and y=992..1023 are black. In the active area:
//   src_x = out_x >> 1
//   src_y = (out_y - 32) >> 1
//
// The source request interface supports both a registered D06 response and a
// same-cycle combinational source response. The latter is useful for a fully
// pipelined static demonstration; a registered source naturally uses ST_REQ/
// ST_WAIT without changing the mapping or error behavior.
// -----------------------------------------------------------------------------
module image_scaler_nn #(
    parameter integer SRC_WIDTH       = 640,
    parameter integer SRC_HEIGHT      = 480,
    parameter integer DST_WIDTH       = 1280,
    parameter integer DST_HEIGHT      = 1024,
    parameter integer TOP_BORDER      = 32,
    parameter integer SOURCE_TIMEOUT  = 4095
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        out_req_valid,
    output wire        out_req_ready,
    input  wire [11:0] out_req_x,
    input  wire [11:0] out_req_y,

    output wire        src_req_valid,
    input  wire        src_req_ready,
    output wire [11:0] src_req_x,
    output wire [11:0] src_req_y,
    input  wire        src_pixel_valid,
    input  wire [15:0] src_pixel_rgb565,
    input  wire        src_pixel_error,

    output reg         out_pixel_valid,
    output reg  [15:0] out_pixel_rgb565,
    output reg         out_black,
    output reg  [11:0] out_src_x,
    output reg  [11:0] out_src_y,
    output reg         map_error,
    output reg         source_timeout,
    output reg         underflow_latched
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_REQ  = 2'd1;
    localparam [1:0] ST_WAIT = 2'd2;

    reg [1:0] state;
    reg [11:0] held_src_x;
    reg [11:0] held_src_y;
    reg [31:0] wait_count;

    wire invalid_dst = (out_req_x >= DST_WIDTH) ||
                       (out_req_y >= DST_HEIGHT);
    wire border_pixel = invalid_dst ||
                        (out_req_y < TOP_BORDER) ||
                        (out_req_y >= TOP_BORDER + SRC_HEIGHT * 2);
    wire [11:0] mapped_src_x = out_req_x >> 1;
    wire [11:0] mapped_src_y = (out_req_y - TOP_BORDER) >> 1;
    wire mapped_src_valid = !border_pixel &&
                            (mapped_src_x < SRC_WIDTH) &&
                            (mapped_src_y < SRC_HEIGHT);
    wire immediate_src_req = (state == ST_IDLE) &&
                             out_req_valid && mapped_src_valid;

    assign out_req_ready = (state == ST_IDLE);
    assign src_req_valid = (state == ST_REQ) || immediate_src_req;
    // Hold the source coordinate through both request and response wait states.
    // The output raster may advance while the source memory responds.
    assign src_req_x = (state != ST_IDLE) ? held_src_x : mapped_src_x;
    assign src_req_y = (state != ST_IDLE) ? held_src_y : mapped_src_y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            held_src_x        <= 12'd0;
            held_src_y        <= 12'd0;
            wait_count        <= 32'd0;
            out_pixel_valid   <= 1'b0;
            out_pixel_rgb565  <= 16'd0;
            out_black         <= 1'b1;
            out_src_x         <= 12'd0;
            out_src_y         <= 12'd0;
            map_error         <= 1'b0;
            source_timeout    <= 1'b0;
            underflow_latched <= 1'b0;
        end else begin
            out_pixel_valid <= 1'b0;
            map_error       <= 1'b0;
            source_timeout  <= 1'b0;

            if (state == ST_WAIT)
                wait_count <= wait_count + 1'b1;
            else
                wait_count <= 32'd0;

            case (state)
                ST_IDLE: begin
                    if (out_req_valid) begin
                        if (border_pixel) begin
                            out_pixel_valid  <= 1'b1;
                            out_pixel_rgb565 <= 16'h0000;
                            out_black         <= 1'b1;
                            out_src_x         <= 12'd0;
                            out_src_y         <= 12'd0;
                            if (invalid_dst)
                                map_error <= 1'b1;
                        end else if (!mapped_src_valid) begin
                            out_pixel_valid  <= 1'b1;
                            out_pixel_rgb565 <= 16'h0000;
                            out_black         <= 1'b1;
                            out_src_x         <= mapped_src_x;
                            out_src_y         <= mapped_src_y;
                            map_error         <= 1'b1;
                        end else begin
                            out_src_x  <= mapped_src_x;
                            out_src_y  <= mapped_src_y;
                            held_src_x <= mapped_src_x;
                            held_src_y <= mapped_src_y;
                            if (src_req_ready) begin
                                if (src_pixel_valid) begin
                                    out_pixel_valid  <= 1'b1;
                                    out_pixel_rgb565 <= src_pixel_rgb565;
                                    out_black         <= 1'b0;
                                end else if (src_pixel_error) begin
                                    out_pixel_valid   <= 1'b1;
                                    out_pixel_rgb565  <= 16'h0000;
                                    out_black         <= 1'b1;
                                    map_error         <= 1'b1;
                                    underflow_latched <= 1'b1;
                                end else begin
                                    state <= ST_REQ;
                                end
                            end else begin
                                state <= ST_REQ;
                            end
                        end
                    end
                end

                ST_REQ: begin
                    if (src_req_ready) begin
                        if (src_pixel_valid) begin
                            out_pixel_valid  <= 1'b1;
                            out_pixel_rgb565 <= src_pixel_rgb565;
                            out_black         <= 1'b0;
                            state             <= ST_IDLE;
                        end else if (src_pixel_error) begin
                            out_pixel_valid   <= 1'b1;
                            out_pixel_rgb565  <= 16'h0000;
                            out_black         <= 1'b1;
                            map_error         <= 1'b1;
                            underflow_latched <= 1'b1;
                            state             <= ST_IDLE;
                        end else begin
                            state <= ST_WAIT;
                        end
                    end
                end

                ST_WAIT: begin
                    if (src_pixel_valid) begin
                        out_pixel_valid  <= 1'b1;
                        out_pixel_rgb565 <= src_pixel_rgb565;
                        out_black         <= 1'b0;
                        state             <= ST_IDLE;
                    end else if (src_pixel_error) begin
                        out_pixel_valid   <= 1'b1;
                        out_pixel_rgb565  <= 16'h0000;
                        out_black         <= 1'b1;
                        map_error         <= 1'b1;
                        underflow_latched <= 1'b1;
                        state             <= ST_IDLE;
                    end else if ((SOURCE_TIMEOUT > 0) &&
                                 (wait_count >= SOURCE_TIMEOUT - 1)) begin
                        out_pixel_valid   <= 1'b1;
                        out_pixel_rgb565  <= 16'h0000;
                        out_black         <= 1'b1;
                        source_timeout    <= 1'b1;
                        underflow_latched <= 1'b1;
                        state             <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
