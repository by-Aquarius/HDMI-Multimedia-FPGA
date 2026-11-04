`timescale 1ns/1ps
module tb_left_hud_alignment;
    reg clk;
    reg rst_n;
    reg [11:0] x;
    reg [11:0] y;
    wire osd_valid;
    wire [15:0] osd_rgb;
    wire osd_alpha;
    wire osd_active;
    integer checks;

    osd_engine_pxl_split #(
        .SCREEN_WIDTH(1280), .SCREEN_HEIGHT(720),
        .OSD_X(32), .OSD_Y(32), .OSD_COLUMNS(15)
    ) dut (
        .clk(clk), .rst_n(rst_n), .pixel_valid(1'b1),
        .pixel_x(x), .pixel_y(y), .base_rgb565(16'd0),
        .status_enable(1'b1), .banner_enable(1'b0),
        .image_index(8'd1), .sd_ok(1'b1), .audio_ok(1'b1),
        .error_valid(1'b0), .error_code(8'd0),
        .brightness_level(8'd10), .speed_level(8'd2), .volume_level(5'd8),
        .subtitle_phase(5'd0), .program_status(17'd0), .playback_status(4'd0),
        .diag_mode(1'b0), .source_width(12'd640), .source_height(12'd480),
        .fps_value(8'd60), .swap_count(8'd0), .underflow_count(8'd0),
        .underrun_count(8'd0), .out_valid(osd_valid), .out_rgb565(),
        .osd_rgb565(osd_rgb), .osd_alpha(osd_alpha), .osd_active(osd_active)
    );

    always #5 clk = !clk;

    task check_pixel;
        input [11:0] px;
        input [11:0] py;
        input expected_alpha;
        begin
            x = px;
            y = py;
            repeat (6) @(negedge clk);
            checks = checks + 1;
            if (osd_alpha !== expected_alpha || osd_active !== expected_alpha) begin
                $display("FAIL menu x=%0d y=%0d alpha=%b active=%b",
                         px, py, osd_alpha, osd_active);
                $finish;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        x = 12'd0;
        y = 12'd0;
        checks = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        check_pixel(12'd24, 12'd100, 1'b1);
        check_pixel(12'd279, 12'd100, 1'b1);
        check_pixel(12'd280, 12'd100, 1'b0);
        check_pixel(12'd50, 12'd23, 1'b0);
        check_pixel(12'd50, 12'd152, 1'b0);
        $display("LEFT_HUD_ALIGNMENT_PASS checks=%0d width=256", checks);
        $finish;
    end
endmodule
