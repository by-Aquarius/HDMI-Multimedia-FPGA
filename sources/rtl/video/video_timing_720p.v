`timescale 1ns/1ps
// Fixed CEA720p60 raster / 固定标准720p60扫描。
// Every line remains 1650 clocks and every frame 750 lines, independent of memory readiness.
module video_timing_720p (
    input wire clk,
    input wire rst_n,
    output wire de,
    output wire hs,
    output wire vs
);
    reg [10:0] horizontal;
    reg [9:0] vertical;
    assign de=rst_n && horizontal<11'd1280 && vertical<10'd720;
    assign hs=rst_n && horizontal>=11'd1390 && horizontal<11'd1430;
    assign vs=rst_n && vertical>=10'd725 && vertical<10'd730;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin horizontal<=0;vertical<=0;end
        else if(horizontal==11'd1649)begin
            horizontal<=0;
            if(vertical==10'd749)vertical<=0;
            else vertical<=vertical+1'b1;
        end else horizontal<=horizontal+1'b1;
    end
endmodule
