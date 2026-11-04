`timescale 1ns / 1ps

// Adaptive nearest-neighbour raster mapper.
//
// The configured content window is filled as far as possible while preserving
// source aspect ratio:
//
//   scale = min(C_CONTENT_WIDTH / source_width,
//               C_CONTENT_HEIGHT / source_height)
//
// One rational scale is shared by both axes. Source coordinates are generated
// with integer DDA accumulators, so no per-pixel multiplier or divider is
// required. Geometry division runs only when source dimensions change.
module adaptive_aspect_raster_mapper #(
    parameter integer C_DST_WIDTH         = 1280,
    parameter integer C_DST_HEIGHT        = 1024,
    parameter integer C_CONTENT_LEFT      = 0,
    parameter integer C_CONTENT_TOP       = 32,
    parameter integer C_CONTENT_WIDTH     = 1280,
    parameter integer C_CONTENT_HEIGHT    = 960,
    parameter integer C_MAX_SOURCE_WIDTH  = 640,
    parameter integer C_MAX_SOURCE_HEIGHT = 480
) (
    input  wire        i_clk,
    input  wire        i_rstn,

    input  wire [11:0] i_source_width,
    input  wire [11:0] i_source_height,
    input  wire        i_frame_start,
    input  wire        i_line_start,
    input  wire [11:0] i_line_y,
    input  wire        i_raster_de,
    input  wire [11:0] i_raster_x,
    input  wire [11:0] i_raster_y,
    input  wire        i_line_ready,
    input  wire [11:0] i_line_ready_y,

    output wire [11:0] o_source_width,
    output wire [11:0] o_source_height,
    output wire [12:0] o_dst_x0,
    output wire [12:0] o_dst_x1,
    output wire [12:0] o_dst_y0,
    output wire [12:0] o_dst_y1,
    output wire        o_line_req_pulse,
    output wire [11:0] o_line_req_y,
    output wire        o_pixel_req_valid,
    output wire [11:0] o_pixel_req_x,
    output wire [11:0] o_pixel_req_y
);

    localparam [2:0] G_IDLE    = 3'd0;
    localparam [2:0] G_MEASURE = 3'd1;
    localparam [2:0] G_SELECT  = 3'd2;
    localparam [2:0] G_DIVIDE  = 3'd3;
    localparam [2:0] G_DONE    = 3'd4;

    localparam [11:0] C_DEFAULT_WIDTH  = C_MAX_SOURCE_WIDTH;
    localparam [11:0] C_DEFAULT_HEIGHT = C_MAX_SOURCE_HEIGHT;

    reg [2:0]  geometry_state;
    reg [2:0]  geometry_next_state;

    reg [11:0] calc_source_width_q;
    reg [11:0] calc_source_height_q;
    reg [23:0] measured_width_q;
    reg [23:0] measured_height_q;
    reg        width_limited_q;
    reg [19:0] divide_dividend_q;
    reg [11:0] divide_divisor_q;
    reg [19:0] divide_quotient_q;
    reg [12:0] divide_remainder_q;
    reg [4:0]  divide_bit_index_q;
    reg [12:0] scaled_width_calc_q;
    reg [12:0] scaled_height_calc_q;
    reg        scaled_width_limited_q;
    reg        scale_ready_q;

    reg [11:0] source_width_q;
    reg [11:0] source_height_q;
    reg [12:0] dst_x0_q;
    reg [12:0] dst_x1_q;
    reg [12:0] dst_y0_q;
    reg [12:0] dst_y1_q;
    reg [11:0] scale_numerator_q;
    reg [12:0] scale_denominator_q;
    reg        frame_active_q;

    reg        line_req_pulse_q;
    reg [11:0] line_req_y_q;
    reg        line_inflight_q;
    reg [11:0] inflight_y_q;
    reg        prefetch_pending_q;
    reg [11:0] next_prefetch_y_q;

    reg [11:0] display_source_y_q;
    reg [11:0] vertical_accumulator_q;
    reg [11:0] source_x_q;
    reg        source_x_valid_q;
    reg [11:0] horizontal_accumulator_q;

    wire geometry_supported =
        (i_source_width != 12'd0) &&
        (i_source_height != 12'd0) &&
        (i_source_width <= C_MAX_SOURCE_WIDTH) &&
        (i_source_height <= C_MAX_SOURCE_HEIGHT);

    wire geometry_matches_calc =
        scale_ready_q &&
        (i_source_width == calc_source_width_q) &&
        (i_source_height == calc_source_height_q);

    wire geometry_needs_update =
        geometry_supported &&
        (!scale_ready_q ||
         (i_source_width != calc_source_width_q) ||
         (i_source_height != calc_source_height_q));

    wire [12:0] divide_shifted =
        {divide_remainder_q[11:0], divide_dividend_q[divide_bit_index_q]};
    wire divide_subtract = divide_shifted >= {1'b0, divide_divisor_q};

    // Geometry control is a small three-process FSM. The divider datapath is
    // updated only in G_DIVIDE and completes one quotient bit per pixel clock.
    always @(*) begin
        geometry_next_state = geometry_state;
        case (geometry_state)
            G_IDLE: begin
                if (geometry_needs_update)
                    geometry_next_state = G_MEASURE;
            end
            G_MEASURE: geometry_next_state = G_SELECT;
            G_SELECT:  geometry_next_state = G_DIVIDE;
            G_DIVIDE: begin
                if (divide_bit_index_q == 5'd0)
                    geometry_next_state = G_DONE;
            end
            G_DONE: geometry_next_state = G_IDLE;
            default: geometry_next_state = G_IDLE;
        endcase
    end

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn)
            geometry_state <= G_IDLE;
        else
            geometry_state <= geometry_next_state;
    end

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            calc_source_width_q   <= C_DEFAULT_WIDTH;
            calc_source_height_q  <= C_DEFAULT_HEIGHT;
            measured_width_q      <= 24'd0;
            measured_height_q     <= 24'd0;
            width_limited_q       <= 1'b1;
            divide_dividend_q     <= 20'd0;
            divide_divisor_q      <= 12'd1;
            divide_quotient_q     <= 20'd0;
            divide_remainder_q    <= 13'd0;
            divide_bit_index_q    <= 5'd19;
            scaled_width_calc_q   <= C_CONTENT_WIDTH;
            scaled_height_calc_q  <= C_CONTENT_HEIGHT;
            scaled_width_limited_q<= 1'b1;
            scale_ready_q         <= 1'b0;
        end else begin
            case (geometry_state)
                G_IDLE: begin
                    if (geometry_needs_update) begin
                        calc_source_width_q  <= i_source_width;
                        calc_source_height_q <= i_source_height;
                        scale_ready_q        <= 1'b0;
                    end
                end
                G_MEASURE: begin
                    measured_width_q  <= calc_source_width_q * C_CONTENT_HEIGHT;
                    measured_height_q <= calc_source_height_q * C_CONTENT_WIDTH;
                end
                G_SELECT: begin
                    divide_quotient_q  <= 20'd0;
                    divide_remainder_q <= 13'd0;
                    divide_bit_index_q <= 5'd19;
                    if (measured_height_q <= measured_width_q) begin
                        width_limited_q  <= 1'b1;
                        divide_dividend_q<= measured_height_q[19:0];
                        divide_divisor_q <= calc_source_width_q;
                    end else begin
                        width_limited_q  <= 1'b0;
                        divide_dividend_q<= measured_width_q[19:0];
                        divide_divisor_q <= calc_source_height_q;
                    end
                end
                G_DIVIDE: begin
                    if (divide_subtract) begin
                        divide_remainder_q <= divide_shifted -
                                              {1'b0, divide_divisor_q};
                        divide_quotient_q[divide_bit_index_q] <= 1'b1;
                    end else begin
                        divide_remainder_q <= divide_shifted;
                        divide_quotient_q[divide_bit_index_q] <= 1'b0;
                    end
                    if (divide_bit_index_q != 5'd0)
                        divide_bit_index_q <= divide_bit_index_q - 1'b1;
                end
                G_DONE: begin
                    if ((i_source_width == calc_source_width_q) &&
                        (i_source_height == calc_source_height_q)) begin
                        if (width_limited_q) begin
                            scaled_width_calc_q  <= C_CONTENT_WIDTH;
                            scaled_height_calc_q <= divide_quotient_q[12:0];
                        end else begin
                            scaled_width_calc_q  <= divide_quotient_q[12:0];
                            scaled_height_calc_q <= C_CONTENT_HEIGHT;
                        end
                        scaled_width_limited_q <= width_limited_q;
                        scale_ready_q          <= 1'b1;
                    end
                end
                default: begin end
            endcase
        end
    end

    wire [12:0] scaled_width_for_frame = scaled_width_calc_q;
    wire [12:0] scaled_height_for_frame = scaled_height_calc_q;
    wire [12:0] dst_x0_for_frame =
        C_CONTENT_LEFT +
        ((C_CONTENT_WIDTH - scaled_width_for_frame) >> 1);
    wire [12:0] dst_y0_for_frame =
        C_CONTENT_TOP +
        ((C_CONTENT_HEIGHT - scaled_height_for_frame) >> 1);

    // Precompute the next row during the long interval between line starts.
    // This removes the accumulator/add/compare chain from first-pixel valid.
    reg vertical_advance_cached_q;
    reg [11:0] next_source_y_cached_q;
    always @(posedge i_clk or negedge i_rstn) begin
        if(!i_rstn)begin vertical_advance_cached_q<=0;next_source_y_cached_q<=1;end
        else begin
            vertical_advance_cached_q<=({1'b0,vertical_accumulator_q}+{1'b0,scale_numerator_q})>=scale_denominator_q;
            next_source_y_cached_q<=display_source_y_q+1'b1;
        end
    end
    wire [11:0] next_line_display_y =
        (i_line_y == dst_y0_q) ? 12'd0 :
        vertical_advance_cached_q ?
        next_source_y_cached_q : display_source_y_q;
    wire [11:0] line_display_y =
        i_line_start ? next_line_display_y : display_source_y_q;

    wire line_inside_image =
        (i_line_y >= dst_y0_q) && (i_line_y < dst_y1_q);
    wire raster_inside_image =
        (i_raster_x >= dst_x0_q) &&
        (i_raster_x < dst_x1_q) &&
        (i_raster_y >= dst_y0_q) &&
        (i_raster_y < dst_y1_q);
    wire [11:0] horizontal_sum =
        horizontal_accumulator_q + scale_numerator_q;
    wire horizontal_advance = horizontal_sum >= scale_denominator_q;
    wire [11:0] line_source_x =
        i_line_start ? 12'd0 : source_x_q;
    wire [11:0] vertical_sum =
        vertical_accumulator_q + scale_numerator_q;
    wire vertical_advance = vertical_sum >= scale_denominator_q;
    wire requested_line_ready = i_line_ready && line_inflight_q &&
                                (i_line_ready_y == inflight_y_q);
    wire line_slot_free = !line_inflight_q || requested_line_ready;
    assign o_source_width    = source_width_q;
    assign o_source_height   = source_height_q;
    assign o_dst_x0          = dst_x0_q;
    assign o_dst_x1          = dst_x1_q;
    assign o_dst_y0          = dst_y0_q;
    assign o_dst_y1          = dst_y1_q;
    assign o_line_req_pulse  = line_req_pulse_q;
    assign o_line_req_y      = line_req_y_q;
    assign o_pixel_req_valid = i_raster_de &&
                               frame_active_q &&
                               raster_inside_image &&
                               (i_line_start || source_x_valid_q) &&
                               (line_display_y < source_height_q);
    assign o_pixel_req_x     = line_source_x;
    assign o_pixel_req_y     = line_display_y;

    always @(posedge i_clk or negedge i_rstn) begin
        if (!i_rstn) begin
            source_width_q        <= C_DEFAULT_WIDTH;
            source_height_q       <= C_DEFAULT_HEIGHT;
            dst_x0_q              <= C_CONTENT_LEFT;
            dst_x1_q              <= C_CONTENT_LEFT + C_CONTENT_WIDTH;
            dst_y0_q              <= C_CONTENT_TOP;
            dst_y1_q              <= C_CONTENT_TOP + C_CONTENT_HEIGHT;
            scale_numerator_q     <= C_DEFAULT_WIDTH;
            scale_denominator_q   <= C_CONTENT_WIDTH;
            frame_active_q        <= 1'b0;
            line_req_pulse_q      <= 1'b0;
            line_req_y_q          <= 12'd0;
            line_inflight_q       <= 1'b0;
            inflight_y_q          <= 12'd0;
            prefetch_pending_q    <= 1'b0;
            next_prefetch_y_q     <= 12'd0;
            display_source_y_q    <= 12'd0;
            vertical_accumulator_q<= 12'd0;
            source_x_q            <= 12'd0;
            source_x_valid_q      <= 1'b1;
            horizontal_accumulator_q <= 12'd0;
        end else begin
            line_req_pulse_q <= 1'b0;
            if (requested_line_ready)
                line_inflight_q <= 1'b0;

            if (i_frame_start) begin
                line_req_pulse_q   <= 1'b0;
                line_inflight_q    <= 1'b0;
                inflight_y_q       <= 12'd0;
                next_prefetch_y_q  <= 12'd1;
                prefetch_pending_q <= 1'b1;
                display_source_y_q <= 12'd0;
                vertical_accumulator_q <= 12'd0;
                source_x_q         <= 12'd0;
                source_x_valid_q   <= 1'b1;
                horizontal_accumulator_q <= 12'd0;

                if (geometry_supported && geometry_matches_calc) begin
                    source_width_q    <= calc_source_width_q;
                    source_height_q   <= calc_source_height_q;
                    dst_x0_q          <= dst_x0_for_frame;
                    dst_x1_q          <= dst_x0_for_frame + scaled_width_for_frame;
                    dst_y0_q          <= dst_y0_for_frame;
                    dst_y1_q          <= dst_y0_for_frame + scaled_height_for_frame;
                    frame_active_q    <= 1'b1;
                    if (scaled_width_limited_q) begin
                        scale_numerator_q   <= calc_source_width_q;
                        scale_denominator_q <= C_CONTENT_WIDTH;
                    end else begin
                        scale_numerator_q   <= calc_source_height_q;
                        scale_denominator_q <= C_CONTENT_HEIGHT;
                    end
                    line_inflight_q <= 1'b1;
                    line_req_pulse_q <= 1'b1;
                    line_req_y_q <= 12'd0;
                    prefetch_pending_q <= 1'b1;
                end else if (!geometry_supported) begin
                    source_width_q    <= C_DEFAULT_WIDTH;
                    source_height_q   <= C_DEFAULT_HEIGHT;
                    dst_x0_q          <= C_CONTENT_LEFT;
                    dst_x1_q          <= C_CONTENT_LEFT + C_CONTENT_WIDTH;
                    dst_y0_q          <= C_CONTENT_TOP;
                    dst_y1_q          <= C_CONTENT_TOP + C_CONTENT_HEIGHT;
                    scale_numerator_q <= C_DEFAULT_WIDTH;
                    scale_denominator_q <= C_CONTENT_WIDTH;
                    frame_active_q    <= 1'b1;
                    line_inflight_q   <= 1'b1;
                    line_req_pulse_q  <= 1'b1;
                    line_req_y_q      <= 12'd0;
                    prefetch_pending_q <= 1'b1;
                end else begin
                    source_width_q  <= i_source_width;
                    source_height_q <= i_source_height;
                    dst_x0_q        <= C_CONTENT_LEFT;
                    dst_x1_q        <= 13'd0;
                    dst_y0_q        <= 13'd0;
                    dst_y1_q        <= 13'd0;
                    frame_active_q  <= 1'b0;
                    prefetch_pending_q <= 1'b0;
                end
            end else begin
                if (i_line_start) begin
                    horizontal_accumulator_q <= 12'd0;
                    source_x_q <= 12'd0;
                    source_x_valid_q <= 1'b1;
                    prefetch_pending_q <= 1'b1;

                    if (line_inside_image) begin
                        if (i_line_y == dst_y0_q) begin
                            display_source_y_q <= 12'd0;
                            vertical_accumulator_q <= 12'd0;
                        end else if (vertical_advance) begin
                            display_source_y_q <= display_source_y_q + 1'b1;
                            vertical_accumulator_q <= vertical_sum -
                                                      scale_denominator_q[11:0];
                        end else begin
                            vertical_accumulator_q <= vertical_sum;
                        end

                        if (i_raster_de && raster_inside_image)
                            horizontal_accumulator_q <= scale_numerator_q;
                    end
                end else if (i_raster_de && raster_inside_image) begin
                    if (horizontal_advance) begin
                        horizontal_accumulator_q <= horizontal_sum -
                                                    scale_denominator_q[11:0];
                        source_x_q <= source_x_q + 1'b1;
                        source_x_valid_q <=
                            ((source_x_q + 1'b1) < source_width_q);
                    end else begin
                        horizontal_accumulator_q <= horizontal_sum;
                    end
                end

                if (prefetch_pending_q && !i_line_start) begin
                    if (frame_active_q &&
                        line_slot_free &&
                        (next_prefetch_y_q < source_height_q) &&
                        ((display_source_y_q + 1'b1) >= next_prefetch_y_q)) begin
                        line_inflight_q <= 1'b1;
                        inflight_y_q <= next_prefetch_y_q;
                        line_req_pulse_q <= 1'b1;
                        line_req_y_q <= next_prefetch_y_q;
                        next_prefetch_y_q <= next_prefetch_y_q + 1'b1;
                        prefetch_pending_q <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
