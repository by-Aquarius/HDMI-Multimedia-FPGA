// -----------------------------------------------------------------------------
// parameter_ctrl.v
// B04: brightness and playback-speed parameter registers.
//
// Brightness:
//   range 0..10, step 1, reset 10.
//   The register is a pixel-data gain parameter. It never changes HDMI clocks.
//
// Speed:
//   level 0..5, reset 2.
//   National-second-plan playback timer mapping is:
//     0=10 s, 1=8 s, 2=6 s, 3=4 s, 4=2 s, 5=1 s per image.
//   The register changes only the future slideshow timer interval.
//
// If opposite commands in one cycle are asserted simultaneously, that
// parameter holds its previous value. Brightness and speed are independent.
// -----------------------------------------------------------------------------
module parameter_ctrl #(
    parameter [7:0] BRIGHTNESS_RESET = 8'd10,
    parameter [7:0] BRIGHTNESS_MIN   = 8'd0,
    parameter [7:0] BRIGHTNESS_MAX   = 8'd10,
    parameter [7:0] BRIGHTNESS_STEP  = 8'd1,
    parameter [2:0] SPEED_RESET      = 3'd2,
    parameter [2:0] SPEED_MIN        = 3'd0,
    parameter [2:0] SPEED_MAX        = 3'd5
) (
    input  wire       clk_50m,
    input  wire       rst_n,
    input  wire       cmd_bright_dec,
    input  wire       cmd_bright_inc,
    input  wire       cmd_speed_dec,
    input  wire       cmd_speed_inc,
    output reg [7:0]  brightness_level,
    output reg [2:0]  speed_level
);

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            brightness_level <= BRIGHTNESS_RESET;
            speed_level      <= SPEED_RESET;
        end else begin
            // Opposite commands in one cycle are treated as ambiguous and
            // leave that parameter unchanged.
            if (cmd_bright_dec && !cmd_bright_inc) begin
                if (brightness_level <= (BRIGHTNESS_MIN + BRIGHTNESS_STEP))
                    brightness_level <= BRIGHTNESS_MIN;
                else
                    brightness_level <= brightness_level - BRIGHTNESS_STEP;
            end else if (cmd_bright_inc && !cmd_bright_dec) begin
                if (brightness_level >= (BRIGHTNESS_MAX - BRIGHTNESS_STEP))
                    brightness_level <= BRIGHTNESS_MAX;
                else
                    brightness_level <= brightness_level + BRIGHTNESS_STEP;
            end

            if (cmd_speed_dec && !cmd_speed_inc) begin
                if (speed_level <= SPEED_MIN)
                    speed_level <= SPEED_MIN;
                else
                    speed_level <= speed_level - 1'b1;
            end else if (cmd_speed_inc && !cmd_speed_dec) begin
                if (speed_level >= SPEED_MAX)
                    speed_level <= SPEED_MAX;
                else
                    speed_level <= speed_level + 1'b1;
            end
        end
    end

endmodule
