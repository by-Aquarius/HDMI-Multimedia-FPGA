`timescale 1ns/1ps
// Two-stage RGB565 brightness gain for the 107.5 MHz pixel path.
// Stage 1 captures the three channel products; stage 2 rounds, saturates and
// formats the RGB565 result. Input pixels are carried through both stages.
module brightness_gain_pipelined #(
    parameter [7:0] BRIGHTNESS_MIN = 8'h20
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        brightness_enable,
    input  wire [7:0]  brightness_level,
    input  wire [15:0] in_rgb565,
    output reg  [15:0] out_rgb565
);

    reg [15:0] in_rgb565_q;
    reg        bypass_q;
    reg [16:0] r_product_q;
    reg [16:0] g_product_q;
    reg [16:0] b_product_q;

    reg [7:0] gain_eff;
    // User-visible levels are 0..10; the existing two-pixel-clock latency stays.
    always @(*) begin
        case(brightness_level)
            0:gain_eff=0; 1:gain_eff=26; 2:gain_eff=51; 3:gain_eff=77;
            4:gain_eff=102; 5:gain_eff=128; 6:gain_eff=153;
            7:gain_eff=179; 8:gain_eff=204; 9:gain_eff=230;
            default:gain_eff=255;
        endcase
    end
    wire [7:0] r8 = {in_rgb565[15:11], in_rgb565[15:13]};
    wire [7:0] g8 = {in_rgb565[10:5],  in_rgb565[10:9]};
    wire [7:0] b8 = {in_rgb565[4:0],   in_rgb565[4:2]};

    wire [16:0] r_rounded = r_product_q + 17'd255;
    wire [16:0] g_rounded = g_product_q + 17'd255;
    wire [16:0] b_rounded = b_product_q + 17'd255;
    wire [7:0] r_scaled = (r_rounded[16:8] > 8'hFF) ? 8'hFF :
                          r_rounded[15:8];
    wire [7:0] g_scaled = (g_rounded[16:8] > 8'hFF) ? 8'hFF :
                          g_rounded[15:8];
    wire [7:0] b_scaled = (b_rounded[16:8] > 8'hFF) ? 8'hFF :
                          b_rounded[15:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_rgb565_q  <= 16'd0;
            bypass_q     <= 1'b1;
            r_product_q  <= 17'd0;
            g_product_q  <= 17'd0;
            b_product_q  <= 17'd0;
        end else begin
            in_rgb565_q <= in_rgb565;
            bypass_q    <= !brightness_enable ||
                           (brightness_level >= 8'd10);
            r_product_q <= r8 * gain_eff;
            g_product_q <= g8 * gain_eff;
            b_product_q <= b8 * gain_eff;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out_rgb565 <= 16'd0;
        else if (bypass_q)
            out_rgb565 <= in_rgb565_q;
        else
            out_rgb565 <= {r_scaled[7:3], g_scaled[7:2], b_scaled[7:3]};
    end

endmodule
