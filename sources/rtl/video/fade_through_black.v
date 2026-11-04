`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// fade_through_black.v
// Frame-boundary fade-out to black, external frame swap, then fade-in.
//
// Control flow:
//   start        -> fade the currently displayed image to black
//   swap_ready   -> hold black and request the actual frame-buffer swap
//   frame_swapped-> begin fading the newly displayed image in
//   done         -> one-cycle completion pulse at full brightness
//
// The gain is updated only on frame_boundary, so no raster is partly faded.
// RGB565 gain uses a two-stage pipeline to keep the 107.5 MHz pixel path away
// from a long multiply-add chain. Both pipeline stages always run, including
// bypass mode, so DE/HS/VS alignment is deterministic.
// -----------------------------------------------------------------------------
module fade_through_black #(
    parameter [7:0] FADE_STEP = 8'h15,
    parameter integer FRAME_TIMEOUT_CYCLES = 8000000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        enable,
    input  wire        start,
    input  wire        frame_boundary,
    input  wire        frame_swapped,
    input  wire        abort,

    input  wire        pixel_valid,
    input  wire [15:0] in_rgb565,
    output reg         out_valid,
    output reg  [15:0] out_rgb565,

    output wire        fade_active,
    output reg  [7:0]  fade_level,
    output wire        swap_ready,
    output reg         done,
    output reg         fade_error
);

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_FADE_OUT = 3'd1;
    localparam [2:0] ST_WAIT_SWAP= 3'd2;
    localparam [2:0] ST_FADE_IN  = 3'd3;
    localparam [2:0] ST_ERROR    = 3'd4;

    reg [2:0]  state;
    reg [31:0] frame_wait_count;
    reg [15:0] in_rgb565_q;
    reg        in_valid_q;
    reg        bypass_q;
    reg [16:0] r_product_q;
    reg [16:0] g_product_q;
    reg [16:0] b_product_q;

    wire active_state = (state == ST_FADE_OUT) ||
                        (state == ST_WAIT_SWAP) ||
                        (state == ST_FADE_IN);
    wire timeout_hit = (FRAME_TIMEOUT_CYCLES > 0) &&
                       (frame_wait_count >= FRAME_TIMEOUT_CYCLES - 1);
    wire [7:0] gain_eff = enable ? fade_level : 8'hFF;
    wire [7:0] r8 = {in_rgb565[15:11], in_rgb565[15:13]};
    wire [7:0] g8 = {in_rgb565[10:5],  in_rgb565[10:9]};
    wire [7:0] b8 = {in_rgb565[4:0],   in_rgb565[4:2]};
    wire [16:0] r_rounded = r_product_q + 17'd255;
    wire [16:0] g_rounded = g_product_q + 17'd255;
    wire [16:0] b_rounded = b_product_q + 17'd255;

    assign fade_active = active_state;
    assign swap_ready  = (state == ST_WAIT_SWAP);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            frame_wait_count <= 32'd0;
            fade_level       <= 8'hFF;
            done             <= 1'b0;
            fade_error       <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!enable || abort) begin
                state            <= ST_IDLE;
                frame_wait_count <= 32'd0;
                fade_level       <= 8'hFF;
            end else begin
                if (active_state)
                    frame_wait_count <= frame_wait_count + 1'b1;
                else
                    frame_wait_count <= 32'd0;

                case (state)
                    ST_IDLE: begin
                        fade_level <= 8'hFF;
                        if (start) begin
                            state            <= ST_FADE_OUT;
                            frame_wait_count <= 32'd0;
                            fade_error       <= 1'b0;
                        end
                    end

                    ST_FADE_OUT: begin
                        if (timeout_hit) begin
                            state            <= ST_ERROR;
                            frame_wait_count <= 32'd0;
                            fade_level       <= 8'hFF;
                            fade_error       <= 1'b1;
                        end else if (frame_boundary) begin
                            frame_wait_count <= 32'd0;
                            if (fade_level <= FADE_STEP) begin
                                fade_level <= 8'd0;
                                state      <= ST_WAIT_SWAP;
                            end else begin
                                fade_level <= fade_level - FADE_STEP;
                            end
                        end
                    end

                    ST_WAIT_SWAP: begin
                        fade_level <= 8'd0;
                        if (timeout_hit) begin
                            state            <= ST_ERROR;
                            frame_wait_count <= 32'd0;
                            fade_level       <= 8'hFF;
                            fade_error       <= 1'b1;
                        end else if (frame_swapped) begin
                            state            <= ST_FADE_IN;
                            frame_wait_count <= 32'd0;
                        end
                    end

                    ST_FADE_IN: begin
                        if (timeout_hit) begin
                            state            <= ST_ERROR;
                            frame_wait_count <= 32'd0;
                            fade_level       <= 8'hFF;
                            fade_error       <= 1'b1;
                        end else if (frame_boundary) begin
                            frame_wait_count <= 32'd0;
                            if (fade_level >= (8'hFF - FADE_STEP)) begin
                                fade_level <= 8'hFF;
                                state      <= ST_IDLE;
                                done       <= 1'b1;
                            end else begin
                                fade_level <= fade_level + FADE_STEP;
                            end
                        end
                    end

                    ST_ERROR: begin
                        fade_level <= 8'hFF;
                        if (start) begin
                            state            <= ST_FADE_OUT;
                            frame_wait_count <= 32'd0;
                            fade_error       <= 1'b0;
                        end
                    end

                    default: begin
                        state      <= ST_IDLE;
                        fade_level <= 8'hFF;
                    end
                endcase
            end
        end
    end

    // Two-stage pixel gain. This path is identical in enabled and bypass modes,
    // which keeps the downstream OSD/adapter sideband alignment fixed.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_rgb565_q <= 16'd0;
            in_valid_q  <= 1'b0;
            bypass_q    <= 1'b1;
            r_product_q <= 17'd0;
            g_product_q <= 17'd0;
            b_product_q <= 17'd0;
        end else begin
            in_rgb565_q <= in_rgb565;
            in_valid_q  <= pixel_valid;
            bypass_q    <= !enable || (gain_eff == 8'hFF);
            r_product_q <= r8 * gain_eff;
            g_product_q <= g8 * gain_eff;
            b_product_q <= b8 * gain_eff;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            out_rgb565 <= 16'd0;
        end else begin
            out_valid <= in_valid_q;
            if (bypass_q) begin
                out_rgb565 <= in_rgb565_q;
            end else begin
                out_rgb565 <= {r_rounded[15:11],
                               g_rounded[15:10],
                               b_rounded[15:11]};
            end
        end
    end

endmodule
