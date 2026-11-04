// -----------------------------------------------------------------------------
// video_mixer.v
// D09: transition/image + OSD + optional spectrum + brightness composition.
//
// Composition order:
//   base/transition -> OSD alpha -> optional spectrum alpha -> brightness gain
//
// All inputs/outputs are pixel data and valid bits only. There is deliberately
// no clock port: this block cannot alter the HDMI pixel clock or serializer
// timing. Alpha layers are binary for the D08/P2 interfaces; transition_level
// is an 8-bit linear blend level (0=base, 255=next).
// -----------------------------------------------------------------------------
module video_mixer #(
    parameter [7:0] BRIGHTNESS_MIN = 8'h20
) (
    input  wire        pixel_valid,
    input  wire [15:0] base_rgb565,

    input  wire        transition_enable,
    input  wire [7:0]  transition_level,
    input  wire [15:0] next_rgb565,

    input  wire [15:0] osd_rgb565,
    input  wire        osd_alpha,

    input  wire        spectrum_enable,
    input  wire [15:0] spectrum_rgb565,
    input  wire        spectrum_alpha,

    input  wire        brightness_enable,
    input  wire [7:0]  brightness_level,

    output reg         out_valid,
    output wire [15:0] out_rgb565,
    output reg         out_underflow
);
    reg [15:0] transition_rgb565;
    reg [15:0] osd_mix_rgb565;
    reg [15:0] layer_rgb565;

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
            // Keep both branches unsigned; this avoids Verilog signed/unsigned
            // promotion errors when fading downward from a bright channel.
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

    reg [7:0] tr;
    reg [7:0] tg;
    reg [7:0] tb;

    brightness_gain #(.BRIGHTNESS_MIN(BRIGHTNESS_MIN)) u_brightness (
        .brightness_enable(brightness_enable),
        .brightness_level(brightness_level),
        .in_rgb565(layer_rgb565),
        .out_rgb565(out_rgb565)
    );

    always @* begin
        // Defaults avoid inferred latches in the combinational mixer.
        tr = 8'd0;
        tg = 8'd0;
        tb = 8'd0;

        if (transition_enable) begin
            tr = blend8(expand_r(base_rgb565), expand_r(next_rgb565), transition_level);
            tg = blend8(expand_g(base_rgb565), expand_g(next_rgb565), transition_level);
            tb = blend8(expand_b(base_rgb565), expand_b(next_rgb565), transition_level);
            transition_rgb565 = {tr[7:3], tg[7:2], tb[7:3]};
        end else begin
            transition_rgb565 = base_rgb565;
        end

        osd_mix_rgb565 = osd_alpha ? osd_rgb565 : transition_rgb565;
        if (spectrum_enable && spectrum_alpha)
            layer_rgb565 = spectrum_rgb565;
        else
            layer_rgb565 = osd_mix_rgb565;

        out_valid = pixel_valid;
        out_underflow = 1'b0;
    end
endmodule


