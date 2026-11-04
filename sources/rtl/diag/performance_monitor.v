`timescale 1ns / 1ps
// Live, read-only performance telemetry for the diagnostic OSD.
// All counters observe existing media signals; they do not feed the control path.
module performance_monitor #(
    parameter integer CTRL_HZ = 25000000,
    parameter integer PUBLISH_HZ = 10
) (
    input  wire        clk_ctrl,
    input  wire        rst_ctrl_n,
    input  wire        audio_underrun_level,
    input  wire        frame_toggle_pxl,
    input  wire        frame_swap_ack_ctrl,
    input  wire        underflow_toggle_pxl,

    input  wire        clk_pixel,
    input  wire        rst_pixel_n,
    output reg  [7:0]  fps_pxl,
    output reg  [7:0]  swap_count_pxl,
    output reg  [7:0]  underflow_count_pxl,
    output reg  [7:0]  underrun_count_pxl
);
    // Accommodate the actual control frequency rather than the old 25 MHz
    // fixed widths. 50 MHz needs 26 bits and a 10 Hz publisher needs 23.
    reg [31:0] second_counter;
    reg [31:0] publish_counter;
    reg [7:0]  frame_count;
    reg [7:0]  fps_ctrl;

    reg frame_toggle_sync1;
    reg frame_toggle_sync2;
    reg frame_toggle_seen;
    reg frame_swap_ack_q;
    reg underflow_toggle_sync1;
    reg underflow_toggle_sync2;
    reg underflow_toggle_seen;

    reg [7:0]  swap_count_ctrl;
    reg [7:0] underflow_count_ctrl;
    reg [7:0] underrun_count_ctrl;
    reg        underrun_level_q;

    // Publish one coherent telemetry snapshot at 10 Hz. The 32-bit payload
    // remains stable until the next toggle, so the pixel domain captures it
    // directly after synchronizing the single-bit event.
    reg [31:0] metrics_hold_ctrl;
    reg         metrics_toggle_ctrl;
    reg         metrics_toggle_sync1_pxl;
    reg         metrics_toggle_sync2_pxl;
    reg         metrics_toggle_seen_pxl;

    always @(posedge clk_ctrl or negedge rst_ctrl_n) begin
        if (!rst_ctrl_n) begin
            second_counter <= 32'd0;
            publish_counter <= 32'd0;
            frame_count <= 8'd0;
            fps_ctrl <= 8'd0;
            frame_toggle_sync1 <= 1'b0;
            frame_toggle_sync2 <= 1'b0;
            frame_toggle_seen <= 1'b0;
            frame_swap_ack_q <= 1'b0;
            underflow_toggle_sync1 <= 1'b0;
            underflow_toggle_sync2 <= 1'b0;
            underflow_toggle_seen <= 1'b0;
            swap_count_ctrl <= 8'd0;
            underflow_count_ctrl <= 8'd0;
            underrun_count_ctrl <= 8'd0;
            underrun_level_q <= 1'b0;
            metrics_hold_ctrl <= 32'd0;
            metrics_toggle_ctrl <= 1'b0;
        end else begin
            frame_toggle_sync1 <= frame_toggle_pxl;
            frame_toggle_sync2 <= frame_toggle_sync1;
            underflow_toggle_sync1 <= underflow_toggle_pxl;
            underflow_toggle_sync2 <= underflow_toggle_sync1;

            if (frame_toggle_sync2 != frame_toggle_seen) begin
                frame_toggle_seen <= frame_toggle_sync2;
                if (frame_count != 8'hFF)
                    frame_count <= frame_count + 1'b1;
            end
            frame_swap_ack_q <= frame_swap_ack_ctrl;
            if (frame_swap_ack_ctrl && !frame_swap_ack_q) begin
                if (swap_count_ctrl != 8'hFF)
                    swap_count_ctrl <= swap_count_ctrl + 1'b1;
            end
            if (underflow_toggle_sync2 != underflow_toggle_seen) begin
                underflow_toggle_seen <= underflow_toggle_sync2;
                if (underflow_count_ctrl != 8'hFF)
                    underflow_count_ctrl <= underflow_count_ctrl + 1'b1;
            end

            underrun_level_q <= audio_underrun_level;
            if (audio_underrun_level && !underrun_level_q &&
                (underrun_count_ctrl != 8'hFF))
                underrun_count_ctrl <= underrun_count_ctrl + 1'b1;

            if (second_counter >= CTRL_HZ - 1) begin
                second_counter <= 32'd0;
                fps_ctrl <= (frame_count == 8'hFF) ? frame_count :
                    frame_count + ((frame_toggle_sync2 != frame_toggle_seen) ?
                                   8'd1 : 8'd0);
                frame_count <= 8'd0;
            end else begin
                second_counter <= second_counter + 1'b1;
            end

            if (publish_counter >= (CTRL_HZ / PUBLISH_HZ) - 1) begin
                publish_counter <= 32'd0;
                metrics_hold_ctrl <= {
                    fps_ctrl, swap_count_ctrl,
                    underflow_count_ctrl, underrun_count_ctrl
                };
                metrics_toggle_ctrl <= ~metrics_toggle_ctrl;
            end else begin
                publish_counter <= publish_counter + 1'b1;
            end
        end
    end

    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if (!rst_pixel_n) begin
            metrics_toggle_sync1_pxl <= 1'b0;
            metrics_toggle_sync2_pxl <= 1'b0;
            metrics_toggle_seen_pxl <= 1'b0;
            fps_pxl <= 8'd0;
            swap_count_pxl <= 8'd0;
            underflow_count_pxl <= 8'd0;
            underrun_count_pxl <= 8'd0;
        end else begin
            metrics_toggle_sync1_pxl <= metrics_toggle_ctrl;
            metrics_toggle_sync2_pxl <= metrics_toggle_sync1_pxl;
            if (metrics_toggle_sync2_pxl != metrics_toggle_seen_pxl) begin
                metrics_toggle_seen_pxl <= metrics_toggle_sync2_pxl;
                {
                    fps_pxl, swap_count_pxl,
                    underflow_count_pxl, underrun_count_pxl
                } <= metrics_hold_ctrl;
            end
        end
    end
endmodule
