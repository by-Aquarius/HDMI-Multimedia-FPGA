// -----------------------------------------------------------------------------
// Transparent ASCII/status OSD and image-synchronized scrolling scene banner.
// Both use uniformly doubled 8x8 font pixels, a navy backing and cyan frame.
// The status panel and centered banner share a 32-pixel top screen margin.
// Numeric fields are unsigned decimal values, including source image geometry.
// The layer is transparent outside that panel and never stalls the base video
// stream. The output can feed D09 as osd_rgb565/osd_alpha, while out_rgb565 is
// a convenience composited result.
// -----------------------------------------------------------------------------
module osd_engine_pxl_split #(
    parameter integer SCREEN_WIDTH  = 1280,
    parameter integer SCREEN_HEIGHT = 1024,
    parameter integer OSD_X        = 40,
    parameter integer OSD_Y        = 40,
    parameter integer OSD_COLUMNS  = 15,
    parameter integer CHAR_WIDTH   = 16,
    parameter integer CHAR_HEIGHT  = 16,
    parameter integer BANNER_PANEL_HEIGHT = 48,
    parameter [15:0]  OSD_COLOR    = 16'hFFE0,
    parameter [15:0]  OSD_BG_COLOR = 16'h0864,
    parameter [15:0]  OSD_BORDER_COLOR = 16'h07FF,
    parameter integer OSD_PAD      = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        pixel_valid,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [15:0] base_rgb565,
    input  wire        status_enable,
    input  wire        banner_enable,

    input  wire [7:0]  image_index,
    input  wire        sd_ok,
    input  wire        audio_ok,
    input  wire        error_valid,
    input  wire [7:0]  error_code,
    input  wire [7:0]  brightness_level,
    input  wire [7:0]  speed_level,
    input  wire [4:0]  volume_level,
    input  wire [4:0]  subtitle_phase,
    input  wire [16:0] program_status,
    input  wire [3:0] playback_status,
    input  wire        diag_mode,
    input  wire [11:0] source_width,
    input  wire [11:0] source_height,
    input  wire [7:0]  fps_value,
    input  wire [7:0]  swap_count,
    input  wire [7:0]  underflow_count,
    input  wire [7:0]  underrun_count,

    output reg         out_valid,
    output reg  [15:0] out_rgb565,
    output reg  [15:0] osd_rgb565,
    output reg         osd_alpha,
    output reg         osd_active
);
    localparam integer TEXT_LEFT   = OSD_X;
    localparam integer TEXT_TOP    = OSD_Y;
    localparam integer TEXT_RIGHT  = OSD_X + OSD_COLUMNS*CHAR_WIDTH;
    localparam integer TEXT_BOTTOM = OSD_Y + 7*CHAR_HEIGHT;
    localparam integer PANEL_LEFT  = TEXT_LEFT - OSD_PAD;
    localparam integer PANEL_TOP   = TEXT_TOP - OSD_PAD;
    localparam integer PANEL_RIGHT = TEXT_RIGHT + OSD_PAD;
    localparam integer PANEL_BOTTOM = TEXT_BOTTOM + OSD_PAD;
    localparam integer BANNER_LEFT = (SCREEN_WIDTH - 32*16)/2;
    localparam integer BANNER_RIGHT = BANNER_LEFT + 32*16;
    localparam integer BANNER_PANEL_TOP = SCREEN_HEIGHT - BANNER_PANEL_HEIGHT;
    localparam integer BANNER_PANEL_BOTTOM =
        BANNER_PANEL_TOP + BANNER_PANEL_HEIGHT;
    localparam integer BANNER_TOP =
        BANNER_PANEL_TOP + (BANNER_PANEL_HEIGHT - 16)/2;
    localparam integer BANNER_BOTTOM = BANNER_TOP + 16;
    localparam integer BANNER_PANEL_LEFT = 0;
    localparam integer BANNER_PANEL_RIGHT = SCREEN_WIDTH;

    wire inside_osd = status_enable &&
                      (pixel_x >= TEXT_LEFT) &&
                      (pixel_x < TEXT_RIGHT) &&
                      (pixel_y >= TEXT_TOP) &&
                      (pixel_y < TEXT_BOTTOM);
    wire inside_banner_text = banner_enable &&
                               (pixel_x >= BANNER_LEFT) &&
                               (pixel_x < BANNER_RIGHT) &&
                               (pixel_y >= BANNER_TOP) &&
                               (pixel_y < BANNER_BOTTOM);
    wire inside_status_panel = status_enable &&
                               (pixel_x >= PANEL_LEFT) &&
                               (pixel_x < PANEL_RIGHT) &&
                               (pixel_y >= PANEL_TOP) &&
                               (pixel_y < PANEL_BOTTOM);
    wire inside_banner_panel = banner_enable &&
                               (pixel_x >= BANNER_PANEL_LEFT) &&
                               (pixel_x < BANNER_PANEL_RIGHT) &&
                               (pixel_y >= BANNER_PANEL_TOP) &&
                               (pixel_y < BANNER_PANEL_BOTTOM);
    wire inside_panel = inside_status_panel || inside_banner_panel;
    wire inside_status_border = inside_status_panel &&
                                ((pixel_x == PANEL_LEFT) ||
                                 (pixel_x == PANEL_RIGHT - 1) ||
                                 (pixel_y == PANEL_TOP) ||
                                 (pixel_y == PANEL_BOTTOM - 1));
    wire inside_banner_border = inside_banner_panel &&
                                ((pixel_x == BANNER_PANEL_LEFT) ||
                                 (pixel_x == BANNER_PANEL_RIGHT - 1) ||
                                 (pixel_y == BANNER_PANEL_TOP) ||
                                 (pixel_y == BANNER_PANEL_BOTTOM - 1));
    wire inside_border = inside_status_border || inside_banner_border;
    wire [5:0] status_char_col =
        inside_osd ? ((pixel_x - OSD_X) >> 4) : 6'd0;
    wire [5:0] banner_char_col =
        inside_banner_text ? ((pixel_x - BANNER_LEFT) >> 4) : 6'd0;
    wire [5:0] char_col = inside_osd ? status_char_col : banner_char_col;
    wire [2:0] char_row =
        inside_osd ? ((pixel_y - OSD_Y) >> 4) : 3'd0;
    wire [2:0] glyph_x = inside_osd ?
                         (((pixel_x - OSD_X) >> 1) & 3'h7) :
                         (((pixel_x - BANNER_LEFT) >> 1) & 3'h7);
    wire [2:0] glyph_y = inside_osd ?
                         (((pixel_y - OSD_Y) >> 1) & 3'h7) :
                         (((pixel_y - BANNER_TOP) >> 1) & 3'h7);

    reg [7:0] char_code_q /* synthesis keep=true */;
    reg [5:0] char_col_q;
    reg [2:0] char_row_q;
    reg [7:0] mode_char_q, key_char_q, program_caption_char_q;
    reg normal_row_q, mode_row_q, key_row_q;
    reg [2:0] glyph_x_q, glyph_y_q;
    reg       inside_osd_q;
    reg       inside_banner_text_q;
    reg       inside_panel_q;
    reg       inside_border_q;
    reg       pixel_valid_q;
    reg [15:0] base_rgb565_q;
    reg [15:0] width_digits_q, height_digits_q;
    reg [3:0] bcd_field_q, bcd_step_q;
    reg [11:0] bcd_binary_q;
    reg [15:0] bcd_work_q;
    wire [3:0] bcd_adjust_thousands = (bcd_work_q[15:12] >= 5) ? bcd_work_q[15:12] + 4'd3 : bcd_work_q[15:12];
    wire [3:0] bcd_adjust_hundreds = (bcd_work_q[11:8] >= 5) ? bcd_work_q[11:8] + 4'd3 : bcd_work_q[11:8];
    wire [3:0] bcd_adjust_tens = (bcd_work_q[7:4] >= 5) ? bcd_work_q[7:4] + 4'd3 : bcd_work_q[7:4];
    wire [3:0] bcd_adjust_ones = (bcd_work_q[3:0] >= 5) ? bcd_work_q[3:0] + 4'd3 : bcd_work_q[3:0];
    wire [15:0] bcd_adjusted = {bcd_adjust_thousands, bcd_adjust_hundreds, bcd_adjust_tens, bcd_adjust_ones};
    wire [15:0] bcd_next = {bcd_adjusted[14:0], bcd_binary_q[11]};
    reg [2:0] text_style_q, text_style_qq, text_style_qqq, text_style_qqqq;
    reg header_zone_q, header_zone_qq, header_zone_qqq, header_zone_qqqq;
    reg [11:0] image_digits_q;
    reg [11:0] error_digits_q;
    reg [7:0]  error_code_d1;
    reg        error_valid_d1;
    reg [11:0] brightness_digits_q;
    reg [3:0]  speed_digit_q;
    reg [7:0] volume_digits_q;
    wire [3:0] volume_tens = (volume_level >= 10) ? 4'd1 : 4'd0;
    wire [3:0] volume_ones = (volume_level >= 10) ? volume_level-5'd10 : volume_level;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) volume_digits_q<=8'h08;
        else volume_digits_q<={volume_tens,volume_ones};
    end
    reg [11:0] fps_digits_q;
    reg [11:0] swap_digits_q;
    reg [11:0] underflow_digits_q;
    reg [11:0] underrun_digits_q;
    reg        sd_ok_q;
    reg        audio_ok_q;
    reg        diag_mode_q;
    reg [1:0] scene_id_q;
    reg [4:0] subtitle_idx_q;
    reg [2:0] glyph_x_qq, glyph_y_qq;
    reg [2:0] glyph_x_qqq, glyph_y_qqq;
    reg [2:0] glyph_x_qqqq, glyph_y_qqqq;
    reg       inside_osd_qq;
    reg       inside_osd_qqq;
    reg       inside_osd_qqqq;
    reg       inside_banner_text_qq;
    reg       inside_banner_text_qqq;
    reg       inside_banner_text_qqqq;
    reg       inside_panel_qq;
    reg       inside_panel_qqq;
    reg       inside_panel_qqqq;
    reg       inside_border_qq;
    reg       inside_border_qqq;
    reg       inside_border_qqqq;
    reg       pixel_valid_qq;
    reg       pixel_valid_qqq;
    reg       pixel_valid_qqqq;
    reg [15:0] base_rgb565_qq;
    reg [15:0] base_rgb565_qqq;
    reg [15:0] base_rgb565_qqqq;
    wire [7:0] glyph_pixels;
    wire [7:0] glyph_mask = 8'h80 >> glyph_x_qqqq;
    wire glyph_on = (inside_osd_qqqq || inside_banner_text_qqqq) &&
                    (|(glyph_pixels & glyph_mask));
    wire panel_on = pixel_valid_qqqq && inside_panel_qqqq;
    wire [15:0] text_rgb565 = (text_style_qqqq == 3'd1) ? 16'h07FF :
                                (text_style_qqqq == 3'd2) ? 16'hFFFF :
                                (text_style_qqqq == 3'd3) ? 16'hA534 :
                                (text_style_qqqq == 3'd4) ? 16'hF9E5 : OSD_COLOR;
    wire [15:0] panel_rgb565 = glyph_on ? text_rgb565 :
                               inside_border_qqqq ? OSD_BORDER_COLOR :
                               header_zone_qqqq ? 16'h10A7 : OSD_BG_COLOR;

    function [7:0] digit_ascii;
        input [3:0] value;
        begin
            if (value < 10)
                digit_ascii = 8'h30 + value;
            else
                digit_ascii = 8'h3F;
        end
    endfunction

    // The image index selects the program scene. The audio controller uses the
    // same one-based image index to reopen its associated WAV, so the visible
    // scene and soundtrack change from one common playback context.
    function [7:0] subtitle_char;
        input [1:0] scene;
        input [4:0] idx;
        begin
            case (scene)
                2'd0: begin
                    // "2026 FPGA MEDIA STARTUP SCENE 00"
                    case (idx)
                        5'd0:  subtitle_char = 8'h32;
                        5'd1:  subtitle_char = 8'h30;
                        5'd2:  subtitle_char = 8'h32;
                        5'd3:  subtitle_char = 8'h36;
                        5'd4:  subtitle_char = 8'h20;
                        5'd5:  subtitle_char = 8'h46;
                        5'd6:  subtitle_char = 8'h50;
                        5'd7:  subtitle_char = 8'h47;
                        5'd8:  subtitle_char = 8'h41;
                        5'd9:  subtitle_char = 8'h20;
                        5'd10: subtitle_char = 8'h4D;
                        5'd11: subtitle_char = 8'h45;
                        5'd12: subtitle_char = 8'h44;
                        5'd13: subtitle_char = 8'h49;
                        5'd14: subtitle_char = 8'h41;
                        5'd15: subtitle_char = 8'h20;
                        5'd16: subtitle_char = 8'h53;
                        5'd17: subtitle_char = 8'h54;
                        5'd18: subtitle_char = 8'h41;
                        5'd19: subtitle_char = 8'h52;
                        5'd20: subtitle_char = 8'h54;
                        5'd21: subtitle_char = 8'h55;
                        5'd22: subtitle_char = 8'h50;
                        5'd23: subtitle_char = 8'h20;
                        5'd24: subtitle_char = 8'h53;
                        5'd25: subtitle_char = 8'h43;
                        5'd26: subtitle_char = 8'h45;
                        5'd27: subtitle_char = 8'h4E;
                        5'd28: subtitle_char = 8'h45;
                        5'd29: subtitle_char = 8'h20;
                        5'd30: subtitle_char = 8'h30;
                        default: subtitle_char = 8'h30;
                    endcase
                end
                2'd1: begin
                    // "2026 FPGA CAMPUS NOTICE AUDIO 01"
                    case (idx)
                        5'd0:  subtitle_char = 8'h32;
                        5'd1:  subtitle_char = 8'h30;
                        5'd2:  subtitle_char = 8'h32;
                        5'd3:  subtitle_char = 8'h36;
                        5'd4:  subtitle_char = 8'h20;
                        5'd5:  subtitle_char = 8'h46;
                        5'd6:  subtitle_char = 8'h50;
                        5'd7:  subtitle_char = 8'h47;
                        5'd8:  subtitle_char = 8'h41;
                        5'd9:  subtitle_char = 8'h20;
                        5'd10: subtitle_char = 8'h43;
                        5'd11: subtitle_char = 8'h41;
                        5'd12: subtitle_char = 8'h4D;
                        5'd13: subtitle_char = 8'h50;
                        5'd14: subtitle_char = 8'h55;
                        5'd15: subtitle_char = 8'h53;
                        5'd16: subtitle_char = 8'h20;
                        5'd17: subtitle_char = 8'h4E;
                        5'd18: subtitle_char = 8'h4F;
                        5'd19: subtitle_char = 8'h54;
                        5'd20: subtitle_char = 8'h49;
                        5'd21: subtitle_char = 8'h43;
                        5'd22: subtitle_char = 8'h45;
                        5'd23: subtitle_char = 8'h20;
                        5'd24: subtitle_char = 8'h41;
                        5'd25: subtitle_char = 8'h55;
                        5'd26: subtitle_char = 8'h44;
                        5'd27: subtitle_char = 8'h49;
                        5'd28: subtitle_char = 8'h4F;
                        5'd29: subtitle_char = 8'h20;
                        5'd30: subtitle_char = 8'h30;
                        default: subtitle_char = 8'h31;
                    endcase
                end
                2'd2: begin
                    // "2026 FPGA LAB INFO PAGE AUDIO 02"
                    case (idx)
                        5'd0:  subtitle_char = 8'h32;
                        5'd1:  subtitle_char = 8'h30;
                        5'd2:  subtitle_char = 8'h32;
                        5'd3:  subtitle_char = 8'h36;
                        5'd4:  subtitle_char = 8'h20;
                        5'd5:  subtitle_char = 8'h46;
                        5'd6:  subtitle_char = 8'h50;
                        5'd7:  subtitle_char = 8'h47;
                        5'd8:  subtitle_char = 8'h41;
                        5'd9:  subtitle_char = 8'h20;
                        5'd10: subtitle_char = 8'h4C;
                        5'd11: subtitle_char = 8'h41;
                        5'd12: subtitle_char = 8'h42;
                        5'd13: subtitle_char = 8'h20;
                        5'd14: subtitle_char = 8'h49;
                        5'd15: subtitle_char = 8'h4E;
                        5'd16: subtitle_char = 8'h46;
                        5'd17: subtitle_char = 8'h4F;
                        5'd18: subtitle_char = 8'h20;
                        5'd19: subtitle_char = 8'h50;
                        5'd20: subtitle_char = 8'h41;
                        5'd21: subtitle_char = 8'h47;
                        5'd22: subtitle_char = 8'h45;
                        5'd23: subtitle_char = 8'h20;
                        5'd24: subtitle_char = 8'h41;
                        5'd25: subtitle_char = 8'h55;
                        5'd26: subtitle_char = 8'h44;
                        5'd27: subtitle_char = 8'h49;
                        5'd28: subtitle_char = 8'h4F;
                        5'd29: subtitle_char = 8'h20;
                        5'd30: subtitle_char = 8'h30;
                        default: subtitle_char = 8'h32;
                    endcase
                end
                default: begin
                    // "2026 FPGA AUDIO PROGRAM DEMO 03 "
                    case (idx)
                        5'd0:  subtitle_char = 8'h32;
                        5'd1:  subtitle_char = 8'h30;
                        5'd2:  subtitle_char = 8'h32;
                        5'd3:  subtitle_char = 8'h36;
                        5'd4:  subtitle_char = 8'h20;
                        5'd5:  subtitle_char = 8'h46;
                        5'd6:  subtitle_char = 8'h50;
                        5'd7:  subtitle_char = 8'h47;
                        5'd8:  subtitle_char = 8'h41;
                        5'd9:  subtitle_char = 8'h20;
                        5'd10: subtitle_char = 8'h41;
                        5'd11: subtitle_char = 8'h55;
                        5'd12: subtitle_char = 8'h44;
                        5'd13: subtitle_char = 8'h49;
                        5'd14: subtitle_char = 8'h4F;
                        5'd15: subtitle_char = 8'h20;
                        5'd16: subtitle_char = 8'h50;
                        5'd17: subtitle_char = 8'h52;
                        5'd18: subtitle_char = 8'h4F;
                        5'd19: subtitle_char = 8'h47;
                        5'd20: subtitle_char = 8'h52;
                        5'd21: subtitle_char = 8'h41;
                        5'd22: subtitle_char = 8'h4D;
                        5'd23: subtitle_char = 8'h20;
                        5'd24: subtitle_char = 8'h44;
                        5'd25: subtitle_char = 8'h45;
                        5'd26: subtitle_char = 8'h4D;
                        5'd27: subtitle_char = 8'h4F;
                        5'd28: subtitle_char = 8'h20;
                        5'd29: subtitle_char = 8'h30;
                        5'd30: subtitle_char = 8'h33;
                        default: subtitle_char = 8'h20;
                    endcase
                end
            endcase
        end
    endfunction

    function [7:0] resolution_digit;
        input [15:0] digits;
        input [1:0] place;
        begin
            if (digits == 16'd0) resolution_digit = 8'h2D;
            else case (place)
                0: resolution_digit = (digits[15:12] == 0) ? 8'h20 : digit_ascii(digits[15:12]);
                1: resolution_digit = (digits[15:8] == 0) ? 8'h20 : digit_ascii(digits[11:8]);
                2: resolution_digit = (digits[15:4] == 0) ? 8'h20 : digit_ascii(digits[7:4]);
                default: resolution_digit = digit_ascii(digits[3:0]);
            endcase
        end
    endfunction

    function [7:0] osd_char_at;
        input [2:0] line;
        input [5:0] col;
        input [11:0] img_digits;
        input        sd;
        input        aud;
        input        err_valid;
        input [11:0] err_digits;
        input [11:0] bright_digits;
        input [3:0]  speed_digit;
        input [7:0] volume_digits;
        input        diag;
        input [11:0] fps_digits;
        input [11:0] swap_digits;
        input [11:0] underflow_digits;
        input [11:0] underrun_digits;
        input [15:0] width_digits;
        input [15:0] height_digits;
        begin
            osd_char_at = 8'h20;
            if (diag) begin
                case (line)
                    3'd0: osd_char_at = (col == 6) ? 8'h32 :
                        (col == 4) ? 8'h52 : (col == 5) ? 8'h46 :
                        (col == 0) ? 8'h50 : (col == 1) ? 8'h45 :
                        (col == 2) ? 8'h52 : (col == 3) ? 8'h20 : 8'h20;
                    3'd1: begin
                        case (col)
                            0: osd_char_at = 8'h46;
                            1: osd_char_at = 8'h50;
                            2: osd_char_at = 8'h53;
                            3: osd_char_at = 8'h3A;
                            4: osd_char_at = digit_ascii(fps_digits[11:8]);
                            5: osd_char_at = digit_ascii(fps_digits[7:4]);
                            6: osd_char_at = digit_ascii(fps_digits[3:0]);
                            8: osd_char_at = 8'h53;
                            9: osd_char_at = 8'h57;
                            10: osd_char_at = 8'h3A;
                            11: osd_char_at = digit_ascii(swap_digits[11:8]);
                            12: osd_char_at = digit_ascii(swap_digits[7:4]);
                            13: osd_char_at = digit_ascii(swap_digits[3:0]);
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd2: begin
                        case (col)
                            0: osd_char_at = 8'h55;
                            1: osd_char_at = 8'h46;
                            2: osd_char_at = 8'h3A;
                            3: osd_char_at = digit_ascii(underflow_digits[11:8]);
                            4: osd_char_at = digit_ascii(underflow_digits[7:4]);
                            5: osd_char_at = digit_ascii(underflow_digits[3:0]);
                            7: osd_char_at = 8'h55;
                            8: osd_char_at = 8'h52;
                            9: osd_char_at = 8'h3A;
                            10: osd_char_at = digit_ascii(underrun_digits[11:8]);
                            11: osd_char_at = digit_ascii(underrun_digits[7:4]);
                            12: osd_char_at = digit_ascii(underrun_digits[3:0]);
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd3: begin
                        case (col)
                            0: osd_char_at = 8'h53;
                            1: osd_char_at = 8'h49;
                            2: osd_char_at = 8'h5A;
                            3: osd_char_at = 8'h45;
                            4: osd_char_at = 8'h3A;
                            5: osd_char_at = resolution_digit(width_digits, 2'd0);
                            6: osd_char_at = resolution_digit(width_digits, 2'd1);
                            7: osd_char_at = resolution_digit(width_digits, 2'd2);
                            8: osd_char_at = resolution_digit(width_digits, 2'd3);
                            9: osd_char_at = 8'h78;
                            10: osd_char_at = resolution_digit(height_digits, 2'd0);
                            11: osd_char_at = resolution_digit(height_digits, 2'd1);
                            12: osd_char_at = resolution_digit(height_digits, 2'd2);
                            13: osd_char_at = resolution_digit(height_digits, 2'd3);
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd4: begin
                        case (col)
                            0: osd_char_at = 8'h49;
                            1: osd_char_at = 8'h4D;
                            2: osd_char_at = 8'h47;
                            3: osd_char_at = 8'h3A;
                            4: osd_char_at = digit_ascii(img_digits[7:4]);
                            5: osd_char_at = digit_ascii(img_digits[3:0]);
                            7: osd_char_at = 8'h41;
                            8: osd_char_at = 8'h3A;
                            9: osd_char_at = aud ? 8'h4F : 8'h2D;
                            10: osd_char_at = aud ? 8'h4B : 8'h2D;
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd5: begin
                        case (col)
                            0: osd_char_at = 8'h4B;
                            1: osd_char_at = 8'h30;
                            2: osd_char_at = 8'h3A;
                            3: osd_char_at = 8'h50;
                            4: osd_char_at = 8'h4C;
                            5: osd_char_at = 8'h41;
                            6: osd_char_at = 8'h59;
                            7: osd_char_at = 8'h45;
                            8: osd_char_at = 8'h52;
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    default: osd_char_at = 8'h20;
                endcase
            end else begin
                case (line)
                    3'd0: begin
                        case (col)
                            0: osd_char_at = 8'h46;
                            1: osd_char_at = 8'h50;
                            2: osd_char_at = 8'h47;
                            3: osd_char_at = 8'h41;
                            5: osd_char_at = 8'h50;
                            6: osd_char_at = 8'h4C;
                            7: osd_char_at = 8'h41;
                            8: osd_char_at = 8'h59;
                            9: osd_char_at = 8'h45;
                            10: osd_char_at = 8'h52;
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd1: begin
                        case (col)
                            0: osd_char_at = 8'h49;
                            1: osd_char_at = 8'h4D;
                            2: osd_char_at = 8'h47;
                            3: osd_char_at = 8'h3A;
                            4: osd_char_at = digit_ascii(img_digits[7:4]);
                            5: osd_char_at = digit_ascii(img_digits[3:0]);
                            7: osd_char_at = 8'h53;
                            8: osd_char_at = 8'h44;
                            9: osd_char_at = 8'h3A;
                            10: osd_char_at = sd ? 8'h4F : 8'h45;
                            11: osd_char_at = sd ? 8'h4B : 8'h52;
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd2: begin
                        case (col)
                            0: osd_char_at = 8'h53;
                            1: osd_char_at = 8'h49;
                            2: osd_char_at = 8'h5A;
                            3: osd_char_at = 8'h45;
                            4: osd_char_at = 8'h3A;
                            5: osd_char_at = resolution_digit(width_digits, 2'd0);
                            6: osd_char_at = resolution_digit(width_digits, 2'd1);
                            7: osd_char_at = resolution_digit(width_digits, 2'd2);
                            8: osd_char_at = resolution_digit(width_digits, 2'd3);
                            9: osd_char_at = 8'h78;
                            10: osd_char_at = resolution_digit(height_digits, 2'd0);
                            11: osd_char_at = resolution_digit(height_digits, 2'd1);
                            12: osd_char_at = resolution_digit(height_digits, 2'd2);
                            13: osd_char_at = resolution_digit(height_digits, 2'd3);
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd3: begin
                        case (col)
                            0: osd_char_at = 8'h41;
                            1: osd_char_at = 8'h55;
                            2: osd_char_at = 8'h44;
                            3: osd_char_at = 8'h3A;
                            4: osd_char_at = aud ? 8'h4F : 8'h2D;
                            5: osd_char_at = aud ? 8'h4B : 8'h2D;
                            7: osd_char_at = 8'h45;
                            8: osd_char_at = 8'h3A;
                            9: osd_char_at = err_valid ? digit_ascii(err_digits[11:8]) : 8'h2D;
                            10: osd_char_at = err_valid ? digit_ascii(err_digits[7:4]) : 8'h2D;
                            11: osd_char_at = err_valid ? digit_ascii(err_digits[3:0]) : 8'h2D;
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    3'd4: begin
                        case (col)
                            0: osd_char_at = 8'h42;
                            1: osd_char_at = digit_ascii(bright_digits[7:4]);
                            2: osd_char_at = digit_ascii(bright_digits[3:0]);
                            4: osd_char_at = 8'h53;
                            5: osd_char_at = digit_ascii(speed_digit);
                            7: osd_char_at = 8'h56;
                            8: osd_char_at = digit_ascii(volume_digits[7:4]);
                            9: osd_char_at = digit_ascii(volume_digits[3:0]);
                            default: osd_char_at = 8'h20;
                        endcase
                    end
                    default: osd_char_at = 8'h20;
                endcase
            end
        end
    endfunction

    // Split the long coordinate-to-glyph path into two pixel-clock stages.
    // The first stage captures row/column and pixel controls; the second
    // decodes the dynamic character and captures it for the font ROM. The
    // external video pipeline is advanced by the same one pixel in the top.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            text_style_q <= 3'd0;
            header_zone_q <= 1'b0;
            char_col_q    <= 6'd0;
            char_row_q    <= 3'd0;
            mode_char_q <= 8'h20;
            key_char_q <= 8'h20;
            program_caption_char_q <= 8'h20;
            normal_row_q <= 1'b0;
            mode_row_q <= 1'b0;
            key_row_q <= 1'b0;
            glyph_x_q     <= 3'd0;
            glyph_y_q     <= 3'd0;
            inside_osd_q  <= 1'b0;
            inside_banner_text_q <= 1'b0;
            inside_panel_q <= 1'b0;
            inside_border_q <= 1'b0;
            pixel_valid_q <= 1'b0;
            base_rgb565_q <= 16'd0;
            subtitle_idx_q <= 5'd0;
        end else begin
            text_style_q <= inside_banner_text ?
                ((program_status[16] && program_status[11]) ? 3'd2 : 3'd1) :
                ((char_row == 0) || (char_row == 6)) ? 3'd1 :
                ((!diag_mode && (char_row == 3) && error_valid && (char_col >= 7))) ? 3'd4 :
                (char_col >= 4) ? 3'd2 : 3'd3;
            header_zone_q <= inside_osd && ((char_row == 0) || (char_row == 6));
            char_col_q    <= char_col;
            char_row_q    <= char_row;
            // Decode added static text in parallel with the coordinate stage.
            // The character register below then needs only a one-hot selection.
            mode_char_q <= playback_mode_char(status_char_col,
                playback_status[3], program_status[16], program_status[14]);
            key_char_q <= playback_key_char(status_char_col);
            program_caption_char_q <= program_caption_char(program_status[10:8],
                banner_char_col[4:0] - 5'd7);
            normal_row_q <= inside_osd && (char_row < 3'd5);
            mode_row_q <= inside_osd && (char_row == 3'd5);
            key_row_q <= inside_osd && (char_row == 3'd6);
            glyph_x_q     <= glyph_x;
            glyph_y_q     <= glyph_y;
            inside_osd_q  <= inside_osd;
            inside_banner_text_q <= inside_banner_text;
            inside_panel_q <= inside_panel;
            inside_border_q <= inside_border;
            pixel_valid_q <= pixel_valid;
            base_rgb565_q <= base_rgb565;
            subtitle_idx_q <= (banner_char_col[4:0] +
                               subtitle_phase) & 5'h1F;
        end
    end

    // Share one iterative binary-to-BCD datapath across all slow status fields.
    // Each field takes 13 clocks; the display refreshes in under 2 us.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bcd_field_q <= 0; bcd_step_q <= 0;
            bcd_binary_q <= 0; bcd_work_q <= 0;
            width_digits_q <= 0; height_digits_q <= 0;
            image_digits_q <= 0; error_digits_q <= 0;
            brightness_digits_q <= 0; speed_digit_q <= 0;
            fps_digits_q <= 0; swap_digits_q <= 0;
            underflow_digits_q <= 0; underrun_digits_q <= 0;
            error_code_d1 <= 0; error_valid_d1 <= 0;
            sd_ok_q <= 0; audio_ok_q <= 0; diag_mode_q <= 0; scene_id_q <= 0;
        end else begin
            error_code_d1 <= error_code; error_valid_d1 <= error_valid;
            sd_ok_q <= sd_ok; audio_ok_q <= audio_ok;
            diag_mode_q <= diag_mode; scene_id_q <= image_index[1:0];
            if (bcd_step_q == 0) begin
                bcd_work_q <= 0;
                bcd_step_q <= 1;
                case (bcd_field_q)
                    0: bcd_binary_q <= source_width;
                    1: bcd_binary_q <= source_height;
                    2: bcd_binary_q <= {4'd0,image_index};
                    3: bcd_binary_q <= {4'd0,(error_valid ? error_code : 8'd0)};
                    4: bcd_binary_q <= {4'd0,brightness_level};
                    5: bcd_binary_q <= {4'd0,speed_level};
                    6: bcd_binary_q <= {4'd0,fps_value};
                    7: bcd_binary_q <= {4'd0,swap_count};
                    8: bcd_binary_q <= {4'd0,underflow_count};
                    9: bcd_binary_q <= {4'd0,underrun_count};
                    default: bcd_binary_q <= 0;
                endcase
            end else begin
                bcd_work_q <= bcd_next;
                bcd_binary_q <= {bcd_binary_q[10:0],1'b0};
                if (bcd_step_q == 12) begin
                    bcd_step_q <= 0;
                    bcd_field_q <= (bcd_field_q == 9) ? 0 : bcd_field_q + 1'b1;
                    case (bcd_field_q)
                        0: width_digits_q <= bcd_next;
                        1: height_digits_q <= bcd_next;
                        2: image_digits_q <= bcd_next[11:0];
                        3: error_digits_q <= bcd_next[11:0];
                        4: brightness_digits_q <= bcd_next[11:0];
                        5: speed_digit_q <= bcd_next[3:0];
                        6: fps_digits_q <= bcd_next[11:0];
                        7: swap_digits_q <= bcd_next[11:0];
                        8: underflow_digits_q <= bcd_next[11:0];
                        9: underrun_digits_q <= bcd_next[11:0];
                        default: begin end
                    endcase
                end else bcd_step_q <= bcd_step_q + 1'b1;
            end
        end
    end

    // Frame-coherent mode and direct key hints share the status panel.
    function [7:0] playback_mode_char;
        input [5:0] column;
        input normal_auto;
        input program_on;
        input program_paused;
        begin
            playback_mode_char = 8'h20;
            case (column)
                0: playback_mode_char = 8'h4d;
                1: playback_mode_char = 8'h4f;
                2: playback_mode_char = 8'h44;
                3: playback_mode_char = 8'h45;
                4: playback_mode_char = 8'h3a;
                5: playback_mode_char = program_on ? 8'h50 : (normal_auto ? 8'h41 : 8'h4d);
                6: playback_mode_char = program_on ? 8'h52 : (normal_auto ? 8'h55 : 8'h41);
                7: playback_mode_char = program_on ? 8'h4f : (normal_auto ? 8'h54 : 8'h4e);
                8: playback_mode_char = program_on ? 8'h47 : (normal_auto ? 8'h4f : 8'h20);
                default: playback_mode_char = 8'h20;
            endcase
        end
    endfunction

    function [7:0] playback_key_char;
        input [5:0] column;
        begin
            playback_key_char = 8'h20;
            case (column)
                0: playback_key_char = 8'h4b;
                1: playback_key_char = 8'h31;
                2: playback_key_char = 8'h30;
                3: playback_key_char = 8'h3a;
                4: playback_key_char = 8'h50;
                5: playback_key_char = 8'h4c;
                6: playback_key_char = 8'h41;
                7: playback_key_char = 8'h59;
                default: playback_key_char = 8'h20;
            endcase
        end
    endfunction

    wire [7:0] normal_char_d = osd_char_at(
        char_row_q, char_col_q,
        image_digits_q, sd_ok_q, audio_ok_q,
        error_valid_d1, error_digits_q,
        brightness_digits_q, speed_digit_q, volume_digits_q,
        diag_mode_q,
        fps_digits_q, swap_digits_q,
        underflow_digits_q, underrun_digits_q, width_digits_q, height_digits_q
    );
    function [7:0] program_caption_char;
        input [2:0] caption_id;
        input [4:0] column;
        begin
            case ({caption_id, column})
                8'd0: program_caption_char = 8'h57;
                8'd1: program_caption_char = 8'h45;
                8'd2: program_caption_char = 8'h4C;
                8'd3: program_caption_char = 8'h43;
                8'd4: program_caption_char = 8'h4F;
                8'd5: program_caption_char = 8'h4D;
                8'd6: program_caption_char = 8'h45;
                8'd7: program_caption_char = 8'h3A;
                8'd9: program_caption_char = 8'h46;
                8'd10: program_caption_char = 8'h50;
                8'd11: program_caption_char = 8'h47;
                8'd12: program_caption_char = 8'h41;
                8'd14: program_caption_char = 8'h4D;
                8'd15: program_caption_char = 8'h45;
                8'd16: program_caption_char = 8'h44;
                8'd17: program_caption_char = 8'h49;
                8'd18: program_caption_char = 8'h41;
                8'd20: program_caption_char = 8'h53;
                8'd21: program_caption_char = 8'h48;
                8'd22: program_caption_char = 8'h4F;
                8'd23: program_caption_char = 8'h57;
                8'd32: program_caption_char = 8'h41;
                8'd33: program_caption_char = 8'h4C;
                8'd34: program_caption_char = 8'h4C;
                8'd36: program_caption_char = 8'h4D;
                8'd37: program_caption_char = 8'h45;
                8'd38: program_caption_char = 8'h44;
                8'd39: program_caption_char = 8'h49;
                8'd40: program_caption_char = 8'h41;
                8'd42: program_caption_char = 8'h52;
                8'd43: program_caption_char = 8'h55;
                8'd44: program_caption_char = 8'h4E;
                8'd45: program_caption_char = 8'h53;
                8'd47: program_caption_char = 8'h49;
                8'd48: program_caption_char = 8'h4E;
                8'd50: program_caption_char = 8'h46;
                8'd51: program_caption_char = 8'h50;
                8'd52: program_caption_char = 8'h47;
                8'd53: program_caption_char = 8'h41;
                8'd64: program_caption_char = 8'h49;
                8'd65: program_caption_char = 8'h4D;
                8'd66: program_caption_char = 8'h41;
                8'd67: program_caption_char = 8'h47;
                8'd68: program_caption_char = 8'h45;
                8'd69: program_caption_char = 8'h3A;
                8'd71: program_caption_char = 8'h53;
                8'd72: program_caption_char = 8'h4F;
                8'd73: program_caption_char = 8'h55;
                8'd74: program_caption_char = 8'h52;
                8'd75: program_caption_char = 8'h43;
                8'd76: program_caption_char = 8'h45;
                8'd78: program_caption_char = 8'h52;
                8'd79: program_caption_char = 8'h45;
                8'd80: program_caption_char = 8'h53;
                8'd81: program_caption_char = 8'h4F;
                8'd82: program_caption_char = 8'h4C;
                8'd83: program_caption_char = 8'h55;
                8'd84: program_caption_char = 8'h54;
                8'd85: program_caption_char = 8'h49;
                8'd86: program_caption_char = 8'h4F;
                8'd87: program_caption_char = 8'h4E;
                8'd96: program_caption_char = 8'h4E;
                8'd97: program_caption_char = 8'h4F;
                8'd98: program_caption_char = 8'h54;
                8'd99: program_caption_char = 8'h49;
                8'd100: program_caption_char = 8'h43;
                8'd101: program_caption_char = 8'h45;
                8'd102: program_caption_char = 8'h3A;
                8'd104: program_caption_char = 8'h4C;
                8'd105: program_caption_char = 8'h49;
                8'd106: program_caption_char = 8'h56;
                8'd107: program_caption_char = 8'h45;
                8'd109: program_caption_char = 8'h49;
                8'd110: program_caption_char = 8'h4D;
                8'd111: program_caption_char = 8'h41;
                8'd112: program_caption_char = 8'h47;
                8'd113: program_caption_char = 8'h45;
                8'd115: program_caption_char = 8'h56;
                8'd116: program_caption_char = 8'h49;
                8'd117: program_caption_char = 8'h45;
                8'd118: program_caption_char = 8'h57;
                8'd128: program_caption_char = 8'h41;
                8'd129: program_caption_char = 8'h55;
                8'd130: program_caption_char = 8'h44;
                8'd131: program_caption_char = 8'h49;
                8'd132: program_caption_char = 8'h4F;
                8'd133: program_caption_char = 8'h3A;
                8'd135: program_caption_char = 8'h48;
                8'd136: program_caption_char = 8'h44;
                8'd137: program_caption_char = 8'h4D;
                8'd138: program_caption_char = 8'h49;
                8'd140: program_caption_char = 8'h53;
                8'd141: program_caption_char = 8'h4F;
                8'd142: program_caption_char = 8'h55;
                8'd143: program_caption_char = 8'h4E;
                8'd144: program_caption_char = 8'h44;
                8'd146: program_caption_char = 8'h4F;
                8'd147: program_caption_char = 8'h55;
                8'd148: program_caption_char = 8'h54;
                8'd149: program_caption_char = 8'h50;
                8'd150: program_caption_char = 8'h55;
                8'd151: program_caption_char = 8'h54;
                8'd160: program_caption_char = 8'h4E;
                8'd161: program_caption_char = 8'h4F;
                8'd162: program_caption_char = 8'h54;
                8'd163: program_caption_char = 8'h49;
                8'd164: program_caption_char = 8'h43;
                8'd165: program_caption_char = 8'h45;
                8'd166: program_caption_char = 8'h3A;
                8'd168: program_caption_char = 8'h56;
                8'd169: program_caption_char = 8'h4F;
                8'd170: program_caption_char = 8'h4C;
                8'd171: program_caption_char = 8'h55;
                8'd172: program_caption_char = 8'h4D;
                8'd173: program_caption_char = 8'h45;
                8'd175: program_caption_char = 8'h49;
                8'd176: program_caption_char = 8'h53;
                8'd178: program_caption_char = 8'h4C;
                8'd179: program_caption_char = 8'h49;
                8'd180: program_caption_char = 8'h56;
                8'd181: program_caption_char = 8'h45;
                8'd192: program_caption_char = 8'h43;
                8'd193: program_caption_char = 8'h4F;
                8'd194: program_caption_char = 8'h4E;
                8'd195: program_caption_char = 8'h54;
                8'd196: program_caption_char = 8'h52;
                8'd197: program_caption_char = 8'h4F;
                8'd198: program_caption_char = 8'h4C;
                8'd199: program_caption_char = 8'h3A;
                8'd201: program_caption_char = 8'h50;
                8'd202: program_caption_char = 8'h4C;
                8'd203: program_caption_char = 8'h41;
                8'd204: program_caption_char = 8'h59;
                8'd206: program_caption_char = 8'h41;
                8'd207: program_caption_char = 8'h4E;
                8'd208: program_caption_char = 8'h44;
                8'd210: program_caption_char = 8'h50;
                8'd211: program_caption_char = 8'h41;
                8'd212: program_caption_char = 8'h55;
                8'd213: program_caption_char = 8'h53;
                8'd214: program_caption_char = 8'h45;
                8'd224: program_caption_char = 8'h4E;
                8'd225: program_caption_char = 8'h4F;
                8'd226: program_caption_char = 8'h54;
                8'd227: program_caption_char = 8'h49;
                8'd228: program_caption_char = 8'h43;
                8'd229: program_caption_char = 8'h45;
                8'd230: program_caption_char = 8'h3A;
                8'd232: program_caption_char = 8'h41;
                8'd233: program_caption_char = 8'h55;
                8'd234: program_caption_char = 8'h44;
                8'd235: program_caption_char = 8'h49;
                8'd236: program_caption_char = 8'h4F;
                8'd238: program_caption_char = 8'h56;
                8'd239: program_caption_char = 8'h49;
                8'd240: program_caption_char = 8'h53;
                8'd241: program_caption_char = 8'h55;
                8'd242: program_caption_char = 8'h41;
                8'd243: program_caption_char = 8'h4C;
                8'd245: program_caption_char = 8'h53;
                8'd246: program_caption_char = 8'h59;
                8'd247: program_caption_char = 8'h4E;
                8'd248: program_caption_char = 8'h43;
                default: program_caption_char = 8'h20;
            endcase
        end
    endfunction

    reg [7:0] program_banner_char_d;
    always @(*) begin
        program_banner_char_d = program_caption_char_q;
        case (char_col_q)
            0: program_banner_char_d = program_status[12] ? 8'h45 : program_status[14] ? 8'h50 : program_status[15] ? 8'h4C : program_status[13] ? 8'h57 : 8'h52;
            1: program_banner_char_d = program_status[12] ? 8'h4E : program_status[14] ? 8'h41 : program_status[15] ? 8'h4F : program_status[13] ? 8'h41 : 8'h55;
            2: program_banner_char_d = program_status[12] ? 8'h44 : program_status[14] ? 8'h55 : program_status[15] ? 8'h41 : program_status[13] ? 8'h49 : 8'h4E;
            3, 6: program_banner_char_d = 8'h20;
            4: program_banner_char_d = 8'h30 + {4'd0, program_status[7:4]};
            5: program_banner_char_d = 8'h30 + {4'd0, program_status[3:0]};
            default: begin end
        endcase
    end

    wire [7:0] banner_char_d = program_status[16] ? program_banner_char_d : subtitle_char(scene_id_q, subtitle_idx_q);
    wire [7:0] char_code_d =
        (banner_char_d & {8{inside_banner_text_q}}) |
        (normal_char_d & {8{normal_row_q}}) |
        (mode_char_q & {8{mode_row_q}}) |
        (key_char_q & {8{key_row_q}});
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            text_style_qq <= 0; text_style_qqq <= 0; text_style_qqqq <= 0;
            header_zone_qq <= 0; header_zone_qqq <= 0; header_zone_qqqq <= 0;
            char_code_q     <= 8'h20;
            glyph_x_qq      <= 3'd0;
            glyph_y_qq      <= 3'd0;
            glyph_x_qqq     <= 3'd0;
            glyph_y_qqq     <= 3'd0;
            glyph_x_qqqq    <= 3'd0;
            glyph_y_qqqq    <= 3'd0;
            inside_osd_qq   <= 1'b0;
            inside_osd_qqq  <= 1'b0;
            inside_osd_qqqq <= 1'b0;
            inside_banner_text_qq   <= 1'b0;
            inside_banner_text_qqq  <= 1'b0;
            inside_banner_text_qqqq <= 1'b0;
            inside_panel_qq <= 1'b0;
            inside_panel_qqq <= 1'b0;
            inside_panel_qqqq <= 1'b0;
            inside_border_qq <= 1'b0;
            inside_border_qqq <= 1'b0;
            inside_border_qqqq <= 1'b0;
            pixel_valid_qq  <= 1'b0;
            pixel_valid_qqq <= 1'b0;
            pixel_valid_qqqq <= 1'b0;
            base_rgb565_qq  <= 16'd0;
            base_rgb565_qqq <= 16'd0;
            base_rgb565_qqqq <= 16'd0;
        end else begin
            text_style_qq <= text_style_q; text_style_qqq <= text_style_qq; text_style_qqqq <= text_style_qqq;
            header_zone_qq <= header_zone_q; header_zone_qqq <= header_zone_qq; header_zone_qqqq <= header_zone_qqq;
            char_code_q     <= char_code_d;
            glyph_x_qq      <= glyph_x_q;
            glyph_y_qq      <= glyph_y_q;
            glyph_x_qqq     <= glyph_x_qq;
            glyph_y_qqq     <= glyph_y_qq;
            glyph_x_qqqq    <= glyph_x_qqq;
            glyph_y_qqqq    <= glyph_y_qqq;
            inside_osd_qq   <= inside_osd_q;
            inside_osd_qqq  <= inside_osd_qq;
            inside_osd_qqqq <= inside_osd_qqq;
            inside_banner_text_qq   <= inside_banner_text_q;
            inside_banner_text_qqq  <= inside_banner_text_qq;
            inside_banner_text_qqqq <= inside_banner_text_qqq;
            inside_panel_qq <= inside_panel_q;
            inside_panel_qqq <= inside_panel_qq;
            inside_panel_qqqq <= inside_panel_qqq;
            inside_border_qq <= inside_border_q;
            inside_border_qqq <= inside_border_qq;
            inside_border_qqqq <= inside_border_qqq;
            pixel_valid_qq  <= pixel_valid_q;
            pixel_valid_qqq <= pixel_valid_qq;
            pixel_valid_qqqq <= pixel_valid_qqq;
            base_rgb565_qq  <= base_rgb565_q;
            base_rgb565_qqq <= base_rgb565_qq;
            base_rgb565_qqqq <= base_rgb565_qqq;
        end
    end

    font_rom_ascii u_font (
        .clk(clk),
        .rst_n(rst_n),
        .ascii(char_code_q),
        .row(glyph_y_qq),
        .pixels(glyph_pixels)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid  <= 1'b0;
            osd_rgb565 <= OSD_COLOR;
            osd_alpha  <= 1'b0;
            osd_active <= 1'b0;
            out_rgb565 <= 16'd0;
        end else begin
            out_valid  <= pixel_valid_qqqq;
            osd_rgb565 <= panel_on ? panel_rgb565 : OSD_COLOR;
            osd_alpha  <= panel_on;
            osd_active <= panel_on;
            out_rgb565 <= panel_on ? panel_rgb565 : base_rgb565_qqqq;
        end
    end
endmodule


