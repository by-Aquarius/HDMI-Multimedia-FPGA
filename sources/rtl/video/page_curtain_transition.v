`timescale 1ns/1ps
// Eased blue-gray page curtain; the external frame swap occurs while covered.
module page_curtain_transition #(
    parameter integer SCREEN_WIDTH = 1280,
    parameter integer FRAME_TIMEOUT_CYCLES = 8000000,
    parameter [31:0] SWAP_TIMEOUT_CYCLES = 32'd3500000000,
    parameter [15:0] CURTAIN_COLOR = 16'h5bd1,
    parameter [15:0] ACCENT_COLOR = 16'h9f7d
) (
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire start,
    input wire reverse,
    input wire frame_boundary,
    input wire frame_swapped,
    input wire frame_ready,
    input wire abort,
    input wire pixel_valid,
    input wire [11:0] pixel_x,
    input wire [15:0] in_rgb565,
    output wire out_valid,
    output wire [15:0] out_rgb565,
    output wire fade_active,
    output wire [7:0] fade_level,
    output wire swap_ready,
    output wire done,
    output wire [2:0] debug_state,
    output wire fade_error
);
    // The armed phase preserves every old-frame pixel until loading completes.
    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_ARMED = 3'd1;
    localparam [2:0] ST_COVER = 3'd2;
    localparam [2:0] ST_WAIT = 3'd3;
    localparam [2:0] ST_REVEAL = 3'd4;
    localparam [2:0] ST_ERROR = 3'd5;
    reg [2:0] state;
    reg [2:0] state_next;
    reg [2:0] frame_step;
    reg [31:0] wait_count;
    reg direction_latched;
    reg done_latched;
    reg error_latched;

    // Register the moving boundary before the pixel comparisons; neither
    // mirroring nor easing arithmetic belongs to the pixel-to-color path.
    reg [11:0] edge_target;
    reg [7:0] progress_target;
    reg [11:0] edge_forward;
    reg [11:0] edge_reverse;
    reg [8:0] accent_column;
    reg [7:0] level_latched;
    wire cover_phase = (state == ST_COVER);
    wire reveal_phase = (state == ST_REVEAL);
    wire wait_phase = (state == ST_WAIT);
    wire active_phase = (state == ST_ARMED) || cover_phase || wait_phase || reveal_phase;
    wire frame_expired = (FRAME_TIMEOUT_CYCLES > 0) &&
        (wait_count >= FRAME_TIMEOUT_CYCLES - 1);
    wire swap_expired = (SWAP_TIMEOUT_CYCLES > 0) &&
        (wait_count >= SWAP_TIMEOUT_CYCLES - 1);

    // Only registered boundaries and coordinate comparisons select the mask.
    wire left_forward = (pixel_x < edge_forward);
    wire left_reverse = (pixel_x < edge_reverse);
    wire direction_mask = direction_latched ? !left_reverse : left_forward;
    wire moving_mask = reveal_phase ? !direction_mask : direction_mask;
    wire cover_pixel = wait_phase || ((cover_phase || reveal_phase) && moving_mask);
    wire accent_pixel = (pixel_x[11:3] == accent_column) && !wait_phase;
    reg [15:0] image_color;
    reg input_valid;
    reg covered_latched;
    reg accent_latched;
    reg output_valid;
    reg [15:0] output_color;

    // The state register has one owner and retains asynchronous reset polarity.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else state <= state_next;
    end

    // Cover and reveal advance only at frame boundaries. A swap is never
    // released before the curtain has covered the entire completed old frame.
    always @(*) begin
        state_next = state;
        if (!enable || abort) state_next = ST_IDLE;
        else begin
            case (state)
                ST_IDLE: if (start) state_next = ST_ARMED;
                ST_ARMED: begin
                    if (frame_expired) state_next = ST_ERROR;
                    else if (frame_boundary && frame_ready) state_next = ST_COVER;
                end
                ST_COVER: begin
                    if (frame_expired) state_next = ST_ERROR;
                    else if (frame_boundary && frame_step == 3'd7) state_next = ST_WAIT;
                end
                ST_WAIT: begin
                    if (swap_expired) state_next = ST_ERROR;
                    else if (frame_swapped) state_next = ST_REVEAL;
                end
                ST_REVEAL: begin
                    if (frame_expired) state_next = ST_ERROR;
                    else if (frame_boundary && frame_step == 3'd7) state_next = ST_IDLE;
                end
                ST_ERROR: if (start) state_next = ST_ARMED;
                default: state_next = ST_IDLE;
            endcase
        end
    end

    // Frame pacing, watchdogs and one-cycle completion share the state owner.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_step <= 3'd0;
            wait_count <= 32'd0;
            direction_latched <= 1'b0;
            done_latched <= 1'b0;
            error_latched <= 1'b0;
        end else if (!enable || abort) begin
            frame_step <= 3'd0;
            wait_count <= 32'd0;
            done_latched <= 1'b0;
            error_latched <= 1'b0;
        end else begin
            done_latched <= reveal_phase && (state_next == ST_IDLE);
            if (state_next != state) begin
                frame_step <= 3'd0;
                wait_count <= 32'd0;
            end else begin
                if ((cover_phase || reveal_phase) && frame_boundary && frame_step != 3'd7)
                    frame_step <= frame_step + 1'b1;
                if (!active_phase || (frame_boundary && !wait_phase)) wait_count <= 32'd0;
                else wait_count <= wait_count + 1'b1;
            end
            if ((state_next == ST_ARMED) && (state != ST_ARMED)) begin
                direction_latched <= reverse;
                error_latched <= 1'b0;
            end else if (state_next == ST_ERROR) error_latched <= 1'b1;
        end
    end

    // Eight elaboration-time positions approximate a smooth ease-in/ease-out.
    always @(*) begin
        edge_target = 12'd0;
        progress_target = 8'd0;
        case (frame_step)
            3'd0: begin edge_target = 0; progress_target = 0; end
            3'd1: begin edge_target = SCREEN_WIDTH / 20; progress_target = 13; end
            3'd2: begin edge_target = SCREEN_WIDTH * 7 / 40; progress_target = 45; end
            3'd3: begin edge_target = SCREEN_WIDTH * 3 / 8; progress_target = 96; end
            3'd4: begin edge_target = SCREEN_WIDTH * 5 / 8; progress_target = 159; end
            3'd5: begin edge_target = SCREEN_WIDTH * 33 / 40; progress_target = 210; end
            3'd6: begin edge_target = SCREEN_WIDTH * 19 / 20; progress_target = 242; end
            3'd7: begin edge_target = SCREEN_WIDTH; progress_target = 255; end
            default: begin edge_target = 0; progress_target = 0; end
        endcase
    end

    // Coordinate mirroring and accent offsets settle during vertical blanking.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            edge_forward <= 12'd0;
            edge_reverse <= SCREEN_WIDTH;
            accent_column <= 9'd0;
            level_latched <= 8'd0;
        end else begin
            edge_forward <= edge_target;
            edge_reverse <= SCREEN_WIDTH - edge_target;
            if (direction_latched)
                accent_column <= edge_reverse[11:3] - (reveal_phase ? 9'd1 : 9'd0);
            else accent_column <= edge_forward[11:3] - (cover_phase ? 9'd1 : 9'd0);
            if (wait_phase) level_latched <= 8'hff;
            else if (cover_phase) level_latched <= progress_target;
            else if (reveal_phase) level_latched <= 8'hff - progress_target;
            else level_latched <= 8'd0;
        end
    end

    // Two clock edges preserve the existing raster, subtitle and OSD alignment.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            image_color <= 16'd0;
            input_valid <= 1'b0;
            covered_latched <= 1'b0;
            accent_latched <= 1'b0;
            output_valid <= 1'b0;
            output_color <= 16'd0;
        end else begin
            image_color <= in_rgb565;
            input_valid <= pixel_valid;
            covered_latched <= enable && cover_pixel;
            accent_latched <= accent_pixel;
            output_valid <= input_valid;
            output_color <= covered_latched ?
                (accent_latched ? ACCENT_COLOR : CURTAIN_COLOR) : image_color;
        end
    end
    // Stable output bridges keep external ports single-driven.
    assign out_valid = output_valid;
    assign out_rgb565 = output_color;
    assign fade_active = active_phase;
    assign fade_level = level_latched;
    assign swap_ready = wait_phase;
    assign done = done_latched;
    assign debug_state = state;
    assign fade_error = error_latched;
endmodule
