`timescale 1ns / 1ps
// Immutable Unicode/font assets / 不可变字符与字形字库。
// Native INIT_FILE values are embedded by TD in the volatile FPGA bitstream.
module fixed_subtitle_font (
    input wire clk,
    input wire [10:0] code_address,
    input wire [14:0] glyph_address,
    input wire [7:0] builtin_address,
    output wire [15:0] code_data,
    output wire [15:0] glyph_data,
    output wire [15:0] builtin_data
);
    wire [255:0] glyph_banks;
    reg [3:0] bank_q;
    always @(posedge clk) bank_q <= glyph_address[14:11];
    assign glyph_data = glyph_banks[bank_q*16 +: 16];
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_codes.dat"), .FILL_ALL("NONE")
    ) u_codes (
        .dia(16'd0), .dib(16'd0), .addra(code_address), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(code_data), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(9), .ADDR_WIDTH_B(9), .DATA_DEPTH_A(512), .DATA_DEPTH_B(512),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/builtin_codes.dat"), .FILL_ALL("NONE")
    ) u_builtin (
        .dia(16'd0), .dib(16'd0), .addra({1'b0,builtin_address}), .addrb(9'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(builtin_data), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_00.dat"), .FILL_ALL("NONE")
    ) u_glyph_00 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[0 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_01.dat"), .FILL_ALL("NONE")
    ) u_glyph_01 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[16 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_02.dat"), .FILL_ALL("NONE")
    ) u_glyph_02 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[32 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_03.dat"), .FILL_ALL("NONE")
    ) u_glyph_03 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[48 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_04.dat"), .FILL_ALL("NONE")
    ) u_glyph_04 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[64 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_05.dat"), .FILL_ALL("NONE")
    ) u_glyph_05 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[80 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .INIT_FILE("../assets/font_bank_06.dat"), .FILL_ALL("NONE")
    ) u_glyph_06 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[96 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_07.dat"), .FILL_ALL("NONE")
    ) u_glyph_07 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[112 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_08.dat"), .FILL_ALL("NONE")
    ) u_glyph_08 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[128 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_09.dat"), .FILL_ALL("NONE")
    ) u_glyph_09 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[144 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_10.dat"), .FILL_ALL("NONE")
    ) u_glyph_10 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[160 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_11.dat"), .FILL_ALL("NONE")
    ) u_glyph_11 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[176 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_12.dat"), .FILL_ALL("NONE")
    ) u_glyph_12 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[192 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_13.dat"), .FILL_ALL("NONE")
    ) u_glyph_13 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[208 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_14.dat"), .FILL_ALL("NONE")
    ) u_glyph_14 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[224 +: 16]), .dob()
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .DATA_WIDTH_B(16),
        .ADDR_WIDTH_A(11), .ADDR_WIDTH_B(11), .DATA_DEPTH_A(2048), .DATA_DEPTH_B(2048),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("32K"), .INIT_FILE("../assets/font_bank_15.dat"), .FILL_ALL("NONE")
    ) u_glyph_15 (
        .dia(16'd0), .dib(16'd0), .addra(glyph_address[10:0]), .addrb(11'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(glyph_banks[240 +: 16]), .dob()
    );
endmodule
