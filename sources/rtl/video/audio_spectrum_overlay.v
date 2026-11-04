`timescale 1ns/1ps
// Aligned 256-pixel-wide audio spectrum and waveform panels in the left HUD.
module audio_spectrum_overlay #(
    parameter integer SPECTRUM_LEFT=24,
    parameter integer SPECTRUM_RIGHT=280,
    parameter integer SPECTRUM_TOP=168,
    parameter integer SPECTRUM_BOTTOM=368,
    parameter integer SCOPE_LEFT=24,
    parameter integer SCOPE_RIGHT=280,
    parameter integer SCOPE_TOP=384,
    parameter integer SCOPE_BOTTOM=584
)(
    input wire clk,
    input wire rst_n,
    input wire [11:0] pixel_x,
    input wire [11:0] pixel_y,
    input wire [95:0] bar_tops,
    input wire [7:0] waveform_sample,
    input wire [7:0] waveform_previous,
    input wire panel_enable,
    output wire alpha,
    output wire [15:0] rgb565
);
    reg [11:0] x_stage;
    reg [11:0] y_stage;
    reg [95:0] tops_stage;
    reg enabled_stage;
    reg spectrum_area;
    reg scope_area;
    reg border_area;
    reg grid_area;
    reg bar_column;
    reg scope_column;
    reg [11:0] raster_y;
    reg [11:0] bar_top;
    reg [11:0] waveform_upper;
    reg [11:0] waveform_lower;
    reg [11:0] selected_top;

    wire [11:0] band_coordinate = x_stage - SPECTRUM_LEFT;
    wire [2:0] band_index = band_coordinate[8:5];
    wire [4:0] slot_x = band_coordinate[4:0];
    wire [7:0] estimator_height = selected_top >= 12'd1008 ? 8'd0 :
        selected_top < 12'd816 ? 8'd192 : 12'd1008-selected_top;
    wire [7:0] display_height =
        estimator_height - (estimator_height >> 2);
    wire [7:0] sample_high =
        waveform_sample > waveform_previous ? waveform_sample : waveform_previous;
    wire [7:0] sample_low =
        waveform_sample < waveform_previous ? waveform_sample : waveform_previous;
    wire [11:0] spectrum_baseline = SPECTRUM_BOTTOM - 24;
    wire bar_pixel = spectrum_area && bar_column &&
                     raster_y >= bar_top && raster_y <= spectrum_baseline &&
                     bar_top < spectrum_baseline;
    wire trace_pixel = scope_area && scope_column &&
                       raster_y >= waveform_upper &&
                       raster_y <= waveform_lower;
    wire peak_pixel = bar_pixel && raster_y <= bar_top + 1'b1;

    assign alpha = spectrum_area || scope_area;
    assign rgb565 = border_area ? 16'h4c95 :
        trace_pixel ? 16'h07ff :
        peak_pixel ? 16'hffff :
        (bar_pixel && raster_y < 12'd248) ? 16'hfc69 :
        (bar_pixel && raster_y < 12'd280) ? 16'hffe8 :
        (bar_pixel && raster_y < 12'd320) ? 16'h07f5 :
        bar_pixel ? 16'h07ff :
        grid_area ? 16'h1949 : 16'h0864;

    always @(*) begin
        case(band_index)
            0: selected_top = tops_stage[11:0];
            1: selected_top = tops_stage[23:12];
            2: selected_top = tops_stage[35:24];
            3: selected_top = tops_stage[47:36];
            4: selected_top = tops_stage[59:48];
            5: selected_top = tops_stage[71:60];
            6: selected_top = tops_stage[83:72];
            default: selected_top = tops_stage[95:84];
        endcase
    end

    // Register the raster coordinate and visualization samples together.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_stage <= 12'd0;
            y_stage <= 12'd0;
            tops_stage <= 96'd0;
            enabled_stage <= 1'b0;
        end else begin
            x_stage <= pixel_x;
            y_stage <= pixel_y;
            tops_stage <= bar_tops;
            enabled_stage <= panel_enable;
        end
    end

    // Classify each delayed pixel into the two non-overlapping left panels.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spectrum_area <= 1'b0;
            scope_area <= 1'b0;
            border_area <= 1'b0;
            grid_area <= 1'b0;
            bar_column <= 1'b0;
            scope_column <= 1'b0;
            raster_y <= 12'd0;
            bar_top <= 12'd344;
            waveform_upper <= 12'd442;
            waveform_lower <= 12'd442;
        end else begin
            spectrum_area <= enabled_stage &&
                x_stage >= SPECTRUM_LEFT && x_stage < SPECTRUM_RIGHT &&
                y_stage >= SPECTRUM_TOP && y_stage < SPECTRUM_BOTTOM;
            scope_area <= enabled_stage &&
                x_stage >= SCOPE_LEFT && x_stage < SCOPE_RIGHT &&
                y_stage >= SCOPE_TOP && y_stage < SCOPE_BOTTOM;
            border_area <= enabled_stage &&
                (((x_stage == SPECTRUM_LEFT) ||
                  (x_stage == SPECTRUM_RIGHT - 1) ||
                  (y_stage == SPECTRUM_TOP) ||
                  (y_stage == SPECTRUM_BOTTOM - 1)) &&
                 (x_stage >= SPECTRUM_LEFT) && (x_stage < SPECTRUM_RIGHT) &&
                 (y_stage >= SPECTRUM_TOP) && (y_stage < SPECTRUM_BOTTOM)) ||
                (((x_stage == SCOPE_LEFT) ||
                  (x_stage == SCOPE_RIGHT - 1) ||
                  (y_stage == SCOPE_TOP) ||
                  (y_stage == SCOPE_BOTTOM - 1)) &&
                 (x_stage >= SCOPE_LEFT) && (x_stage < SCOPE_RIGHT) &&
                 (y_stage >= SCOPE_TOP) && (y_stage < SCOPE_BOTTOM));
            grid_area <= enabled_stage &&
                ((y_stage >= SPECTRUM_TOP) && (y_stage < SPECTRUM_BOTTOM) &&
                 (x_stage >= SPECTRUM_LEFT) && (x_stage < SPECTRUM_RIGHT) &&
                 ((x_stage[4:0] == 5'd0) || (y_stage[4:0] == 5'd0))) ||
                ((y_stage >= SCOPE_TOP) && (y_stage < SCOPE_BOTTOM) &&
                 (x_stage >= SCOPE_LEFT) && (x_stage < SCOPE_RIGHT) &&
                 ((x_stage[4:0] == 5'd0) || (y_stage[4:0] == 5'd0)));
            bar_column <= (x_stage >= SPECTRUM_LEFT) &&
                          (x_stage < SPECTRUM_RIGHT) &&
                          slot_x >= 5'd8 && slot_x < 5'd24;
            scope_column <= (x_stage >= SCOPE_LEFT + 16) &&
                            (x_stage < SCOPE_RIGHT - 16);
            raster_y <= y_stage;
            bar_top <= spectrum_baseline - display_height;
            waveform_upper <= SCOPE_TOP + 58 + {5'd0, sample_low[7:1]};
            waveform_lower <= SCOPE_TOP + 58 + {5'd0, sample_high[7:1]};
        end
    end
endmodule
