// -----------------------------------------------------------------------------
// brightness_gain.v
// D09: RGB565 data-path brightness gain. No clock, PLL, or timing signal is
// present in this module; brightness therefore cannot change any pixel clock.
// B04 contract: enabled gain range is 0x20..0xFF. Values below 0x20 clamp to
// 0x20. Disabled mode bypasses the data unchanged.
// -----------------------------------------------------------------------------
module brightness_gain #(
    parameter [7:0] BRIGHTNESS_MIN = 8'h20
) (
    input  wire        brightness_enable,
    input  wire [7:0]  brightness_level,
    input  wire [15:0] in_rgb565,
    output reg  [15:0] out_rgb565
);
    reg [7:0] gain;
    reg [7:0] r8;
    reg [7:0] g8;
    reg [7:0] b8;
    reg [7:0] r_scaled;
    reg [7:0] g_scaled;
    reg [7:0] b_scaled;

    function [7:0] scale_channel;
        input [7:0] channel;
        input [7:0] channel_gain;
        reg [16:0] p;
        reg [16:0] q;
        begin
            // Rounded Q0.8 multiplication with explicit 8-bit saturation.
            p = (channel * channel_gain) + 17'd255;
            q = p >> 8;
            if (q > 17'd255)
                scale_channel = 8'hFF;
            else
                scale_channel = q[7:0];
        end
    endfunction

    always @* begin
        // Defaults keep the combinational block fully assigned in both bypass and gain paths.
        r_scaled = 8'd0;
        g_scaled = 8'd0;
        b_scaled = 8'd0;

        gain = (brightness_level < BRIGHTNESS_MIN) ?
               BRIGHTNESS_MIN : brightness_level;

        // Expand 5/6-bit channels to 8 bits before applying gain.
        r8 = {in_rgb565[15:11], in_rgb565[15:13]};
        g8 = {in_rgb565[10:5],  in_rgb565[10:9]};
        b8 = {in_rgb565[4:0],   in_rgb565[4:2]};

        if (!brightness_enable || (brightness_level == 8'hFF)) begin
            out_rgb565 = in_rgb565;
        end else begin
            r_scaled = scale_channel(r8, gain);
            g_scaled = scale_channel(g8, gain);
            b_scaled = scale_channel(b8, gain);
            out_rgb565 = {r_scaled[7:3], g_scaled[7:2], b_scaled[7:3]};
        end
    end
endmodule

