`timescale 1ns / 1ps
// Carries one 48 kHz mono PCM sample from the 25 MHz media clock into the
// HDMI pixel clock. A toggle handshake keeps the sample stable before capture.
module hdmi_audio_sample_cdc (
    input  wire        clk_ctrl,
    input  wire        rst_ctrl_n,
    input  wire        sample_valid_ctrl,
    input  wire [15:0] sample_ctrl,

    input  wire        clk_pixel,
    input  wire        rst_pixel_n,
    output reg         sample_strobe_pixel,
    output reg  [15:0] sample_pixel
);
    reg [15:0] sample_hold_ctrl;
    reg        sample_toggle_ctrl;
    reg        sample_toggle_sync1_pixel;
    reg        sample_toggle_sync2_pixel;
    reg        sample_toggle_seen_pixel;
    reg [15:0] sample_sync1_pixel;
    reg [15:0] sample_sync2_pixel;

    always @(posedge clk_ctrl or negedge rst_ctrl_n) begin
        if (!rst_ctrl_n) begin
            sample_hold_ctrl   <= 16'd0;
            sample_toggle_ctrl <= 1'b0;
        end else if (sample_valid_ctrl) begin
            sample_hold_ctrl   <= sample_ctrl;
            sample_toggle_ctrl <= ~sample_toggle_ctrl;
        end
    end

    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if (!rst_pixel_n) begin
            sample_strobe_pixel      <= 1'b0;
            sample_pixel             <= 16'd0;
            sample_toggle_sync1_pixel<= 1'b0;
            sample_toggle_sync2_pixel<= 1'b0;
            sample_toggle_seen_pixel <= 1'b0;
            sample_sync1_pixel       <= 16'd0;
            sample_sync2_pixel       <= 16'd0;
        end else begin
            sample_strobe_pixel       <= 1'b0;
            sample_toggle_sync1_pixel <= sample_toggle_ctrl;
            sample_toggle_sync2_pixel <= sample_toggle_sync1_pixel;
            sample_sync1_pixel        <= sample_hold_ctrl;
            sample_sync2_pixel        <= sample_sync1_pixel;

            if (sample_toggle_sync2_pixel != sample_toggle_seen_pixel) begin
                sample_toggle_seen_pixel <= sample_toggle_sync2_pixel;
                sample_pixel             <= sample_sync2_pixel;
                sample_strobe_pixel      <= 1'b1;
            end
        end
    end
endmodule
