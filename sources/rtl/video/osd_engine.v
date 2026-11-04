// -----------------------------------------------------------------------------
// osd_engine.v
// D08: transparent ASCII/status OSD layer.
//
// Layout (8x8 glyphs, origin x=16/y=4):
//   FPGA MEDIA
//   IMG:xx SD:OK
//   AUD:OK ERR:xx
//   BR:xx SP:xx
//
// xx fields are hexadecimal nibbles. A small dark panel with a light border
// backs the text so yellow glyphs remain readable over bright image pixels.
// The layer is transparent outside that panel and never stalls the base video
// stream. The output can feed D09 as osd_rgb565/osd_alpha, while out_rgb565 is
// a convenience composited result.
// -----------------------------------------------------------------------------
module osd_engine #(
    parameter integer SCREEN_WIDTH  = 1280,
    parameter integer SCREEN_HEIGHT = 1024,
    parameter integer OSD_X        = 16,
    parameter integer OSD_Y        = 4,
    parameter integer CHAR_WIDTH   = 8,
    parameter integer CHAR_HEIGHT  = 8,
    parameter [15:0]  OSD_COLOR    = 16'hFFE0,
    parameter [15:0]  OSD_BG_COLOR = 16'h0000,
    parameter [15:0]  OSD_BORDER_COLOR = 16'h07FF,
    parameter integer OSD_PAD      = 2
) (
    input  wire        pixel_valid,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [15:0] base_rgb565,

    input  wire [7:0]  image_index,
    input  wire        sd_ok,
    input  wire        audio_ok,
    input  wire        error_valid,
    input  wire [7:0]  error_code,
    input  wire [7:0]  brightness_level,
    input  wire [7:0]  speed_level,

    output reg         out_valid,
    output reg  [15:0] out_rgb565,
    output reg  [15:0] osd_rgb565,
    output reg         osd_alpha,
    output reg         osd_active
);
    localparam integer TEXT_LEFT   = OSD_X;
    localparam integer TEXT_TOP    = OSD_Y;
    localparam integer TEXT_RIGHT  = OSD_X + 16*CHAR_WIDTH;
    localparam integer TEXT_BOTTOM = OSD_Y + 4*CHAR_HEIGHT;
    localparam integer PANEL_LEFT  = TEXT_LEFT - OSD_PAD;
    localparam integer PANEL_TOP   = TEXT_TOP - OSD_PAD;
    localparam integer PANEL_RIGHT = TEXT_RIGHT + OSD_PAD;
    localparam integer PANEL_BOTTOM = TEXT_BOTTOM + OSD_PAD;

    wire inside_osd = (pixel_x >= TEXT_LEFT) &&
                      (pixel_x < TEXT_RIGHT) &&
                      (pixel_y >= TEXT_TOP) &&
                      (pixel_y < TEXT_BOTTOM);
    wire inside_panel = (pixel_x >= PANEL_LEFT) &&
                        (pixel_x < PANEL_RIGHT) &&
                        (pixel_y >= PANEL_TOP) &&
                        (pixel_y < PANEL_BOTTOM);
    wire inside_border = inside_panel &&
                         ((pixel_x == PANEL_LEFT) ||
                          (pixel_x == PANEL_RIGHT - 1) ||
                          (pixel_y == PANEL_TOP) ||
                          (pixel_y == PANEL_BOTTOM - 1));
    wire [5:0] char_col = inside_osd ? ((pixel_x - OSD_X) >> 3) : 6'd0;
    wire [2:0] char_row = inside_osd ? ((pixel_y - OSD_Y) >> 3) : 3'd0;
    wire [2:0] glyph_x = inside_osd ? ((pixel_x - OSD_X) & 3'h7) : 3'd0;
    wire [2:0] glyph_y = inside_osd ? ((pixel_y - OSD_Y) & 3'h7) : 3'd0;

    reg [7:0] char_code;
    wire [7:0] glyph_pixels;
    wire glyph_on = inside_osd && glyph_pixels[7-glyph_x];
    wire [15:0] panel_rgb565 = glyph_on ? OSD_COLOR :
                               inside_border ? OSD_BORDER_COLOR :
                               OSD_BG_COLOR;

    function [7:0] hex_ascii;
        input [3:0] value;
        begin
            if (value < 10)
                hex_ascii = 8'h30 + value;
            else
                hex_ascii = 8'h41 + (value - 10);
        end
    endfunction

    function [7:0] osd_char_at;
        input [2:0] line;
        input [5:0] col;
        input [7:0] img;
        input        sd;
        input        aud;
        input        err;
        input [7:0]  err_code;
        input [7:0]  bright;
        input [7:0]  speed;
        begin
            osd_char_at = 8'h20;
            case (line)
                3'd0: begin
                    case (col)
                        0: osd_char_at=8'h46; // F
                        1: osd_char_at=8'h50; // P
                        2: osd_char_at=8'h47; // G
                        3: osd_char_at=8'h41; // A
                        5: osd_char_at=8'h4D; // M
                        6: osd_char_at=8'h45; // E
                        7: osd_char_at=8'h44; // D
                        8: osd_char_at=8'h49; // I
                        9: osd_char_at=8'h41; // A
                        default: osd_char_at=8'h20;
                    endcase
                end
                3'd1: begin
                    case (col)
                        0: osd_char_at=8'h49; // I
                        1: osd_char_at=8'h4D; // M
                        2: osd_char_at=8'h47; // G
                        3: osd_char_at=8'h3A; // :
                        4: osd_char_at=hex_ascii(img[7:4]);
                        5: osd_char_at=hex_ascii(img[3:0]);
                        7: osd_char_at=8'h53; // S
                        8: osd_char_at=8'h44; // D
                        9: osd_char_at=8'h3A; // :
                        10: osd_char_at=sd ? 8'h4F : 8'h45; // O/E
                        11: osd_char_at=sd ? 8'h4B : 8'h52; // K/R
                        default: osd_char_at=8'h20;
                    endcase
                end
                3'd2: begin
                    case (col)
                        0: osd_char_at=8'h41; // A
                        1: osd_char_at=8'h55; // U
                        2: osd_char_at=8'h44; // D
                        3: osd_char_at=8'h3A;
                        4: osd_char_at=aud ? 8'h4F : 8'h45;
                        5: osd_char_at=aud ? 8'h4B : 8'h52;
                        7: osd_char_at=8'h45; // E
                        8: osd_char_at=8'h52; // R
                        9: osd_char_at=8'h52; // R
                        10: osd_char_at=8'h3A;
                        11: osd_char_at=err ? hex_ascii(err_code[7:4]) : 8'h30;
                        12: osd_char_at=err ? hex_ascii(err_code[3:0]) : 8'h30;
                        default: osd_char_at=8'h20;
                    endcase
                end
                3'd3: begin
                    case (col)
                        0: osd_char_at=8'h42; // B
                        1: osd_char_at=8'h52; // R
                        2: osd_char_at=8'h3A;
                        3: osd_char_at=hex_ascii(bright[7:4]);
                        4: osd_char_at=hex_ascii(bright[3:0]);
                        6: osd_char_at=8'h53; // S
                        7: osd_char_at=8'h50; // P
                        8: osd_char_at=8'h3A;
                        9: osd_char_at=hex_ascii(speed[7:4]);
                        10: osd_char_at=hex_ascii(speed[3:0]);
                        default: osd_char_at=8'h20;
                    endcase
                end
                default: osd_char_at=8'h20;
            endcase
        end
    endfunction

    always @* begin
        char_code = osd_char_at(char_row, char_col, image_index, sd_ok,
                                audio_ok, error_valid, error_code,
                                brightness_level, speed_level);
    end

    font_rom_ascii u_font (
        .ascii(char_code),
        .row(glyph_y),
        .pixels(glyph_pixels)
    );

    always @* begin
        out_valid   = pixel_valid;
        osd_rgb565  = inside_panel ? panel_rgb565 : OSD_COLOR;
        osd_alpha   = pixel_valid && inside_panel;
        osd_active  = osd_alpha;
        out_rgb565  = osd_alpha ? panel_rgb565 : base_rgb565;
    end
endmodule



