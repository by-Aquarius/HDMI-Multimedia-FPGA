`timescale 1ns/1ps
// Reference CRC is produced before SDRAM, checked after real line refill.
module frame_line_crc (
    input wire write_clk,write_rst_n,
    input wire pixel_valid,pixel_ready,
    input wire [15:0] pixel_rgb565,
    input wire [11:0] pixel_x,pixel_y,image_width,
    input wire write_frame_select,
    input wire read_clk,read_rst_n,
    input wire line_start,read_frame_select,
    input wire [8:0] read_line_y,
    input wire [11:0] read_width,
    input wire word_valid,
    input wire [31:0] word_data,
    input wire line_done,
    output reg result_valid,result_ok,
    output wire [15:0] expected_crc,
    output reg [15:0] observed_crc
);
    function [15:0] crc_pixel;
        input [15:0] crc;
        input [15:0] pixel;
        integer bit_index;
        reg [15:0] value;
        begin
            value=crc;
            for(bit_index=15;bit_index>=0;bit_index=bit_index-1)
                value={value[14:0],1'b0} ^ ((value[15]^pixel[bit_index]) ? 16'h1021 : 16'd0);
            crc_pixel=value;
        end
    endfunction
    reg [15:0] write_crc;
    wire pixel_fire=pixel_valid&&pixel_ready;
    wire [15:0] write_next=crc_pixel(pixel_x==0 ? 16'hffff : write_crc,pixel_rgb565);
    wire reference_write=pixel_fire && image_width!=0 && pixel_x==image_width-1'b1 && pixel_y<480;
    wire [9:0] reference_address={write_frame_select,pixel_y[8:0]};
    reg [9:0] read_address;
    reg [9:0] read_address_stage;
    always @(negedge read_clk) begin
        if (!read_rst_n) read_address_stage <= 0;
        else read_address_stage <= read_address;
    end
    reg [11:0] width_hold;
    reg [8:0] word_index;
    reg [15:0] read_crc;
    reg compare_pending;
    wire [11:0] first_pixel={2'd0,word_index,1'b0};
    wire [15:0] crc_after_even=first_pixel<width_hold ? crc_pixel(read_crc,word_data[15:0]) : read_crc;
    wire [15:0] crc_after_word=first_pixel+12'd1<width_hold ? crc_pixel(crc_after_even,word_data[31:16]) : crc_after_even;

    always @(posedge write_clk or negedge write_rst_n) begin
        if(!write_rst_n)write_crc<=16'hffff;
        else if(pixel_fire)write_crc<=write_next;
    end
    // Two9K blocks store480CRC values for each of the two frame buffers.
    // The frame manager's ready bit qualifies table validity; no power-up data assumed.
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
        .DATA_WIDTH_B(16),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),
        .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),.FILL_ALL("NONE")
    ) reference_lines (
        .dia(write_next),.dib(16'd0),.addra(reference_address),.addrb(read_address_stage),
        .cea(reference_write),.ceb(1'b1),.ocea(1'b0),.oceb(1'b0),
        .clka(write_clk),.clkb(read_clk),.wea(reference_write),.web(1'b0),
        .bea(1'b1),.beb(1'b0),.rsta(!write_rst_n),.rstb(!read_rst_n),
        .doa(),.dob(expected_crc)
    );
    always @(posedge read_clk or negedge read_rst_n) begin
        if(!read_rst_n) begin
            read_address<=0;width_hold<=0;word_index<=0;read_crc<=16'hffff;
            compare_pending<=0;result_valid<=0;result_ok<=0;observed_crc<=0;
        end else begin
            result_valid<=0;
            if(line_start) begin
                read_address<={read_frame_select,read_line_y};width_hold<=read_width;
                word_index<=0;read_crc<=16'hffff;compare_pending<=0;result_ok<=0;
            end else begin
                if(word_valid) begin read_crc<=crc_after_word;word_index<=word_index+1'b1;end
                if(line_done)compare_pending<=1;
                if(compare_pending) begin
                    observed_crc<=read_crc;result_ok<=width_hold!=0 && width_hold<=640 && (read_crc==expected_crc);
                    result_valid<=1;compare_pending<=0;
                end
            end
        end
    end
endmodule
