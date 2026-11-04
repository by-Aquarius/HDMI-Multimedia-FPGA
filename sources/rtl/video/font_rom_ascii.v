`timescale 1ns / 1ps
// Synchronous fixed ASCII ROM / 同步固定ASCII字库。
// One BRAM read and one output register retain the original two-edge contract.
module font_rom_ascii (
    input wire clk,
    input wire rst_n,
    input wire [7:0] ascii,
    input wire [2:0] row,
    output reg [7:0] pixels
);
    wire [6:0] character_address=ascii[7] ? 7'h3f : ascii[6:0];
    wire [7:0] font_data;
    reg warm;
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8), .DATA_WIDTH_B(8), .ADDR_WIDTH_A(10), .ADDR_WIDTH_B(10),
        .DATA_DEPTH_A(1024), .DATA_DEPTH_B(1024), .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"), .IMPLEMENT("9K"),
        .INIT_FILE("../assets/ascii_rows.dat"), .FILL_ALL("NONE")
    ) u_ascii_rom (
        .dia(8'd0), .dib(8'd0), .addra({character_address,row}), .addrb(10'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(clk), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0), .doa(font_data), .dob()
    );
    // The warm flag preserves the first zero row after asynchronous reset release.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin warm<=0; pixels<=0; end
        else begin warm<=1; pixels<=warm ? font_data : 8'd0; end
    end
endmodule
