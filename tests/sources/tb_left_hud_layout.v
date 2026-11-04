`timescale 1ns/1ps
module tb_left_hud_layout;
    reg clk;
    reg rst_n;
    reg [11:0] x;
    reg [11:0] y;
    wire alpha;
    wire [15:0] rgb;
    integer checks;

    audio_spectrum_overlay dut (
        .clk(clk),
        .rst_n(rst_n),
        .pixel_x(x),
        .pixel_y(y),
        .bar_tops({8{12'd900}}),
        .waveform_sample(8'd116),
        .waveform_previous(8'd116),
        .panel_enable(1'b1),
        .alpha(alpha),
        .rgb565(rgb)
    );

    always #5 clk = !clk;

    task check_pixel;
        input [11:0] px;
        input [11:0] py;
        input expected_alpha;
        begin
            x = px;
            y = py;
            @(negedge clk);
            @(negedge clk);
            checks = checks + 1;
            if (alpha !== expected_alpha || (expected_alpha && (^rgb === 1'bx))) begin
                $display("FAIL layout x=%0d y=%0d alpha=%b rgb=%h",
                         px, py, alpha, rgb);
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
        repeat (2) @(negedge clk);
        rst_n = 1'b1;

        check_pixel(12'd50, 12'd200, 1'b1);
        check_pixel(12'd200, 12'd300, 1'b1);
        check_pixel(12'd200, 12'd500, 1'b1);
        check_pixel(12'd200, 12'd620, 1'b0);
        check_pixel(12'd200, 12'd376, 1'b0);
        check_pixel(12'd300, 12'd200, 1'b0);
        check_pixel(12'd1279, 12'd719, 1'b0);
        $display("LEFT_HUD_LAYOUT_PASS checks=%0d", checks);
        $finish;
    end
endmodule
