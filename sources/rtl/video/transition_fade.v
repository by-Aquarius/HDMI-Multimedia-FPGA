// -----------------------------------------------------------------------------
// transition_fade.v
// D10: frame-boundary-triggered RGB565 fade transition.
//
// Control clock is independent of the HDMI pixel timing. transition_level is
// changed only on frame_boundary, so this module cannot insert stalls or alter
// the HDMI pixel clock. The pixel result is a combinational data-path blend.
//
// Sequence:
//   start + next_frame_ready -> level 0, ACTIVE
//   each frame_boundary      -> level += LEVEL_STEP
//   final boundary           -> level 255, DONE, output next frame
//   source_error/timeout     -> ERROR, output fallback frame, sticky error
// -----------------------------------------------------------------------------
module transition_fade #(
    parameter [7:0] LEVEL_STEP = 8'h80,
    parameter integer FRAME_TIMEOUT_CYCLES = 1000000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        enable,
    input  wire        start,
    input  wire        frame_boundary,
    input  wire        next_frame_ready,
    input  wire        load_busy,
    input  wire        source_error,
    input  wire        frame_timeout,

    input  wire        pixel_valid,
    input  wire [15:0] base_rgb565,
    input  wire [15:0] next_rgb565,
    input  wire [15:0] fallback_rgb565,

    output wire        transition_enable,
    output reg  [7:0]  transition_level,
    output wire        transition_active,
    output reg         transition_done,
    output reg         transition_error,
    output reg         out_valid,
    output reg  [15:0] out_rgb565
);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_ACTIVE = 2'd1;
    localparam [1:0] ST_DONE  = 2'd2;
    localparam [1:0] ST_ERROR = 2'd3;

    reg [1:0] state;
    reg [31:0] timeout_count;

    wire internal_timeout = (FRAME_TIMEOUT_CYCLES > 0) &&
                             (timeout_count >= FRAME_TIMEOUT_CYCLES - 1);

    assign transition_active = (state == ST_ACTIVE);
    assign transition_enable = (state == ST_ACTIVE);

    function [7:0] expand_r;
        input [15:0] c;
        begin expand_r = {c[15:11], c[15:13]}; end
    endfunction
    function [7:0] expand_g;
        input [15:0] c;
        begin expand_g = {c[10:5], c[10:9]}; end
    endfunction
    function [7:0] expand_b;
        input [15:0] c;
        begin expand_b = {c[4:0], c[4:2]}; end
    endfunction

    function [7:0] blend8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] level;
        integer value;
        begin
            if (b >= a)
                value = a + (((b - a) * level + 128) >> 8);
            else
                value = a - (((a - b) * level + 128) >> 8);
            if (value < 0)
                blend8 = 8'h00;
            else if (value > 255)
                blend8 = 8'hFF;
            else
                blend8 = value[7:0];
        end
    endfunction

    function [15:0] blend565;
        input [15:0] a;
        input [15:0] b;
        input [7:0] level;
        reg [7:0] r;
        reg [7:0] g;
        reg [7:0] bl;
        begin
            r  = blend8(expand_r(a), expand_r(b), level);
            g  = blend8(expand_g(a), expand_g(b), level);
            bl = blend8(expand_b(a), expand_b(b), level);
            blend565 = {r[7:3], g[7:2], bl[7:3]};
        end
    endfunction

    always @* begin
        out_valid = pixel_valid;
        case (state)
            ST_ACTIVE: out_rgb565 = blend565(base_rgb565, next_rgb565, transition_level);
            ST_DONE:   out_rgb565 = next_rgb565;
            ST_ERROR:  out_rgb565 = fallback_rgb565;
            default:   out_rgb565 = base_rgb565;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            transition_level  <= 8'd0;
            transition_done   <= 1'b0;
            transition_error  <= 1'b0;
            timeout_count     <= 32'd0;
        end else begin
            transition_done <= 1'b0;

            if (state == ST_ACTIVE)
                timeout_count <= timeout_count + 1'b1;
            else
                timeout_count <= 32'd0;

            case (state)
                ST_IDLE: begin
                    transition_level <= 8'd0;
                    if (enable && start && next_frame_ready && !load_busy) begin
                        state            <= ST_ACTIVE;
                        transition_level <= 8'd0;
                        transition_error <= 1'b0;
                        timeout_count    <= 32'd0;
                    end
                end

                ST_ACTIVE: begin
                    if (!enable) begin
                        state             <= ST_IDLE;
                        transition_level  <= 8'd0;
                        timeout_count     <= 32'd0;
                    end else if (source_error || frame_timeout || !next_frame_ready || internal_timeout) begin
                        state            <= ST_ERROR;
                        transition_level <= 8'd0;
                        transition_error <= 1'b1;
                        timeout_count    <= 32'd0;
                    end else if (frame_boundary) begin
                        if (transition_level >= (8'hFF - LEVEL_STEP)) begin
                            transition_level <= 8'hFF;
                            state             <= ST_DONE;
                            transition_done   <= 1'b1;
                            timeout_count     <= 32'd0;
                        end else begin
                            transition_level <= transition_level + LEVEL_STEP;
                            timeout_count    <= 32'd0;
                        end
                    end
                end

                ST_DONE: begin
                    // A new start may begin another transition after the
                    // caller has prepared a different next frame.
                    if (enable && start && next_frame_ready && !load_busy) begin
                        state            <= ST_ACTIVE;
                        transition_level <= 8'd0;
                        transition_error <= 1'b0;
                        timeout_count    <= 32'd0;
                    end
                end

                ST_ERROR: begin
                    // Error fallback stays active until reset or a clean,
                    // explicitly requested retry.
                    if (enable && start && next_frame_ready && !load_busy) begin
                        state            <= ST_ACTIVE;
                        transition_level <= 8'd0;
                        transition_error <= 1'b0;
                        timeout_count    <= 32'd0;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

