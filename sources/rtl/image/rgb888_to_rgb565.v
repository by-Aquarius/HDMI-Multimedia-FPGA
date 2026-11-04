// -----------------------------------------------------------------------------
// rgb888_to_rgb565.v
// D03: BGR888/RGB888 byte-pixel to RGB565 conversion with optional brightness.
//
// Input packing is BGR888 as delivered by the BMP stream:
//   in_bgr888[23:16] = Blue, [15:8] = Green, [7:0] = Red.
//
// Brightness is a data-path gain only. It does not touch any clock or timing
// signal. B04 defines the supported range 0x20..0xFF; values below 0x20 are
// clamped to 0x20 here as a defensive saturation boundary.
// -----------------------------------------------------------------------------
module rgb888_to_rgb565 #(
    parameter [7:0] BRIGHTNESS_MIN = 8'h20
) (
    input  wire        clk_50m,
    input  wire        rst_n,

    input  wire        in_valid,
    output wire        in_ready,
    input  wire [23:0] in_bgr888,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire        in_last,

    input  wire        brightness_enable,
    input  wire [7:0]  brightness_level,

    output reg         out_valid,
    input  wire        out_ready,
    output reg  [15:0] out_rgb565,
    output reg  [11:0] out_x,
    output reg  [11:0] out_y,
    output reg         out_last
);

    wire effective_bypass = !brightness_enable;
    wire [7:0] effective_gain = (brightness_level < BRIGHTNESS_MIN) ?
                                 BRIGHTNESS_MIN : brightness_level;

    function [7:0] gain_channel;
        input [7:0] channel;
        input [7:0] gain;
        reg [16:0] product;
        begin
            // Rounded Q0.8 gain. At gain=0xFF, 0xFF remains 0xFF.
            product = (channel * gain) + 17'd255;
            if (product[16:8] > 8'hFF)
                gain_channel = 8'hFF;
            else
                gain_channel = product[15:8];
        end
    endfunction

    wire [7:0] in_blue  = in_bgr888[23:16];
    wire [7:0] in_green = in_bgr888[15:8];
    wire [7:0] in_red   = in_bgr888[7:0];
    wire [7:0] red_scaled = effective_bypass ? in_red : gain_channel(in_red, effective_gain);
    wire [7:0] green_scaled = effective_bypass ? in_green : gain_channel(in_green, effective_gain);
    wire [7:0] blue_scaled = effective_bypass ? in_blue : gain_channel(in_blue, effective_gain);

    assign in_ready = !out_valid || out_ready;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            out_valid   <= 1'b0;
            out_rgb565  <= 16'd0;
            out_x       <= 12'd0;
            out_y       <= 12'd0;
            out_last    <= 1'b0;
        end else begin
            if (in_ready) begin
                if (in_valid) begin
                    out_valid  <= 1'b1;
                    out_rgb565 <= {red_scaled[7:3], green_scaled[7:2], blue_scaled[7:3]};
                    out_x      <= in_x;
                    out_y      <= in_y;
                    out_last   <= in_last;
                end else begin
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                end
            end
        end
    end
endmodule