`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// sample_rate_tick.v
// F02: fractional phase accumulator for an average 48 kHz sample tick.
// -----------------------------------------------------------------------------
module sample_rate_tick #(
    parameter integer CLK_HZ = 50000000,
    parameter integer TICK_HZ = 48000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    output reg  tick
);

    reg [31:0] phase;
    wire [32:0] phase_sum = {1'b0, phase} + TICK_HZ;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 32'd0;
            tick  <= 1'b0;
        end else if (!enable) begin
            phase <= 32'd0;
            tick  <= 1'b0;
        end else if (phase_sum >= CLK_HZ) begin
            phase <= phase_sum - CLK_HZ;
            tick  <= 1'b1;
        end else begin
            phase <= phase_sum[31:0];
            tick  <= 1'b0;
        end
    end

endmodule
