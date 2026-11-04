`timescale 1ns/1ps
module tb_right_image_window;
    reg clk;
    reg rst_n;
    reg [11:0] source_width;
    reg [11:0] source_height;
    reg frame_start;
    wire [12:0] dst_x0;
    wire [12:0] dst_x1;
    wire [12:0] dst_y0;
    wire [12:0] dst_y1;
    integer checks;

    adaptive_aspect_raster_mapper #(
        .C_DST_HEIGHT(720),
        .C_CONTENT_LEFT(312),
        .C_CONTENT_TOP(16),
        .C_CONTENT_WIDTH(944),
        .C_CONTENT_HEIGHT(656)
    ) dut (
        .i_clk(clk),
        .i_rstn(rst_n),
        .i_source_width(source_width),
        .i_source_height(source_height),
        .i_frame_start(frame_start),
        .i_line_start(1'b0),
        .i_line_y(12'd0),
        .i_raster_de(1'b0),
        .i_raster_x(12'd0),
        .i_raster_y(12'd0),
        .i_line_ready(1'b1),
        .o_source_width(),
        .o_source_height(),
        .o_dst_x0(dst_x0),
        .o_dst_x1(dst_x1),
        .o_dst_y0(dst_y0),
        .o_dst_y1(dst_y1),
        .o_line_req_pulse(),
        .o_line_req_y(),
        .o_pixel_req_valid(),
        .o_pixel_req_x(),
        .o_pixel_req_y()
    );

    always #5 clk = !clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        source_width = 12'd640;
        source_height = 12'd480;
        frame_start = 1'b0;
        checks = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        repeat (40) @(negedge clk);
        frame_start = 1'b1;
        @(negedge clk);
        frame_start = 1'b0;
        @(negedge clk);
        checks = checks + 1;
        if (dst_x0 !== 13'd347 || dst_x1 !== 13'd1221 ||
            dst_y0 !== 13'd16 || dst_y1 !== 13'd672) begin
            $display("FAIL 4:3 window actual x=%0d..%0d y=%0d..%0d",
                     dst_x0, dst_x1, dst_y0, dst_y1);
            $finish;
        end

        source_width = 12'd640;
        source_height = 12'd360;
        repeat (40) @(negedge clk);
        frame_start = 1'b1;
        @(negedge clk);
        frame_start = 1'b0;
        @(negedge clk);
        checks = checks + 1;
        if (dst_x0 !== 13'd312 || dst_x1 !== 13'd1256 ||
            dst_y0 !== 13'd78 || dst_y1 !== 13'd609) begin
            $display("FAIL 16:9 window actual x=%0d..%0d y=%0d..%0d",
                     dst_x0, dst_x1, dst_y0, dst_y1);
            $finish;
        end

        $display("RIGHT_IMAGE_WINDOW_PASS checks=%0d", checks);
        $finish;
    end
endmodule
