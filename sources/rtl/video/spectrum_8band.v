`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// spectrum_8band.v
// Low-cost 8-band audio energy estimator for the P2 visualizer. It runs on the
// 48 kHz PCM sample stream and uses only shifts/adds (no multipliers/DSPs).
//
// The one-pole filters approximate low-pass bands; the difference between
// adjacent low-pass outputs is the band energy. The envelope attacks
// immediately and decays slowly so the bars are readable.
// -----------------------------------------------------------------------------
module spectrum_8band #(
    parameter integer IDLE_TIMEOUT_CYCLES = 50000,
    parameter integer IDLE_DECAY_CYCLES = 100000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_valid,
    input  wire [15:0] sample_pcm,
    output reg  [63:0] levels,
    output reg  [95:0] bar_tops
);

    reg signed [16:0] lp0, lp1, lp2, lp3, lp4, lp5, lp6, lp7;
    reg [7:0]  lvl0, lvl1, lvl2, lvl3, lvl4, lvl5, lvl6, lvl7;
    reg [3:0]  decay_count;
    reg [31:0] idle_count;
    reg [31:0] release_count;
    wire [7:0] release_level0 = (lvl0 == 0) ? 8'd0 : lvl0 - 1'b1;
    wire [7:0] release_level1 = (lvl1 == 0) ? 8'd0 : lvl1 - 1'b1;
    wire [7:0] release_level2 = (lvl2 == 0) ? 8'd0 : lvl2 - 1'b1;
    wire [7:0] release_level3 = (lvl3 == 0) ? 8'd0 : lvl3 - 1'b1;
    wire [7:0] release_level4 = (lvl4 == 0) ? 8'd0 : lvl4 - 1'b1;
    wire [7:0] release_level5 = (lvl5 == 0) ? 8'd0 : lvl5 - 1'b1;
    wire [7:0] release_level6 = (lvl6 == 0) ? 8'd0 : lvl6 - 1'b1;
    wire [7:0] release_level7 = (lvl7 == 0) ? 8'd0 : lvl7 - 1'b1;
    wire signed [16:0] s_in = {sample_pcm[15], sample_pcm};
    wire decay_step = (decay_count == 4'd15);

    function [16:0] adiff;
        input signed [16:0] a;
        input signed [16:0] b;
        reg signed [16:0] d;
        begin
            d = a - b;
            adiff = d[16] ? (~d + 1'b1) : d;
        end
    endfunction

    wire [16:0] raw0 = lp0[16] ? (~lp0 + 1'b1) : lp0;
    wire [16:0] raw1 = adiff(lp1, lp0);
    wire [16:0] raw2 = adiff(lp2, lp1);
    wire [16:0] raw3 = adiff(lp3, lp2);
    wire [16:0] raw4 = adiff(lp4, lp3);
    wire [16:0] raw5 = adiff(lp5, lp4);
    wire [16:0] raw6 = adiff(lp6, lp5);
    wire [16:0] raw7 = adiff(lp7, lp6);

    function [7:0] scale_energy;
        input [16:0] e;
        begin
            // 8x gain versus the first prototype so a normal 1 kHz sine
            // produces visible 4..31-pixel bars. Saturate before the 8-bit
            // slice so the level never wraps.
            scale_energy = (e >= 17'd4080) ? 8'hFF : e[11:4];
        end
    endfunction

    wire [7:0] s0 = scale_energy(raw0);
    wire [7:0] s1 = scale_energy(raw1);
    wire [7:0] s2 = scale_energy(raw2);
    wire [7:0] s3 = scale_energy(raw3);
    wire [7:0] s4 = scale_energy(raw4);
    wire [7:0] s5 = scale_energy(raw5);
    wire [7:0] s6 = scale_energy(raw6);
    wire [7:0] s7 = scale_energy(raw7);

    wire [7:0] n0 = (s0 >= lvl0) ? s0 :
                    ((decay_step && (lvl0 != 0)) ? (lvl0 - 1'b1) : lvl0);
    wire [7:0] n1 = (s1 >= lvl1) ? s1 :
                    ((decay_step && (lvl1 != 0)) ? (lvl1 - 1'b1) : lvl1);
    wire [7:0] n2 = (s2 >= lvl2) ? s2 :
                    ((decay_step && (lvl2 != 0)) ? (lvl2 - 1'b1) : lvl2);
    wire [7:0] n3 = (s3 >= lvl3) ? s3 :
                    ((decay_step && (lvl3 != 0)) ? (lvl3 - 1'b1) : lvl3);
    wire [7:0] n4 = (s4 >= lvl4) ? s4 :
                    ((decay_step && (lvl4 != 0)) ? (lvl4 - 1'b1) : lvl4);
    wire [7:0] n5 = (s5 >= lvl5) ? s5 :
                    ((decay_step && (lvl5 != 0)) ? (lvl5 - 1'b1) : lvl5);
    wire [7:0] n6 = (s6 >= lvl6) ? s6 :
                    ((decay_step && (lvl6 != 0)) ? (lvl6 - 1'b1) : lvl6);
    wire [7:0] n7 = (s7 >= lvl7) ? s7 :
                    ((decay_step && (lvl7 != 0)) ? (lvl7 - 1'b1) : lvl7);

    function [11:0] bar_top_for;
        input [7:0] level;
        begin
            bar_top_for = 12'd1008 - (level - (level >> 2));
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lp0 <= 17'sd0; lp1 <= 17'sd0; lp2 <= 17'sd0; lp3 <= 17'sd0;
            lp4 <= 17'sd0; lp5 <= 17'sd0; lp6 <= 17'sd0; lp7 <= 17'sd0;
            lvl0 <= 8'd0; lvl1 <= 8'd0; lvl2 <= 8'd0; lvl3 <= 8'd0;
            lvl4 <= 8'd0; lvl5 <= 8'd0; lvl6 <= 8'd0; lvl7 <= 8'd0;
            decay_count <= 4'd0;
            idle_count <= 32'd0;
            release_count <= 32'd0;
            levels <= 64'd0;
            bar_tops <= {8{12'd1008}};
        end else if (sample_valid) begin
            idle_count <= 32'd0;
            release_count <= 32'd0;
            // One-pole low-pass bank, shift/add only.
            lp0 <= lp0 + (s_in >>> 7) - (lp0 >>> 7);
            lp1 <= lp1 + (s_in >>> 6) - (lp1 >>> 6);
            lp2 <= lp2 + (s_in >>> 5) - (lp2 >>> 5);
            lp3 <= lp3 + (s_in >>> 4) - (lp3 >>> 4);
            lp4 <= lp4 + (s_in >>> 3) - (lp4 >>> 3);
            lp5 <= lp5 + (s_in >>> 2) - (lp5 >>> 2);
            lp6 <= lp6 + (s_in >>> 1) - (lp6 >>> 1);
            lp7 <= s_in;

            if (decay_count == 4'd15)
                decay_count <= 4'd0;
            else
                decay_count <= decay_count + 1'b1;

            lvl0 <= n0; lvl1 <= n1; lvl2 <= n2; lvl3 <= n3;
            lvl4 <= n4; lvl5 <= n5; lvl6 <= n6; lvl7 <= n7;
            levels <= {n7, n6, n5, n4, n3, n2, n1, n0};
            bar_tops <= {
                bar_top_for(n7), bar_top_for(n6),
                bar_top_for(n5), bar_top_for(n4),
                bar_top_for(n3), bar_top_for(n2),
                bar_top_for(n1), bar_top_for(n0)
            };
        end else if (idle_count < IDLE_TIMEOUT_CYCLES - 1) begin
            idle_count <= idle_count + 1'b1;
            release_count <= 32'd0;
        end else begin
            // No PCM for 1 ms: discard stale filter history and release the
            // envelopes using wall-clock time, independently of new samples.
            lp0 <= 17'sd0; lp1 <= 17'sd0; lp2 <= 17'sd0; lp3 <= 17'sd0;
            lp4 <= 17'sd0; lp5 <= 17'sd0; lp6 <= 17'sd0; lp7 <= 17'sd0;
            decay_count <= 4'd0;
            if (release_count == IDLE_DECAY_CYCLES - 1) begin
                release_count <= 32'd0;
                lvl0 <= release_level0; lvl1 <= release_level1;
                lvl2 <= release_level2; lvl3 <= release_level3;
                lvl4 <= release_level4; lvl5 <= release_level5;
                lvl6 <= release_level6; lvl7 <= release_level7;
                levels <= {release_level7, release_level6, release_level5,
                           release_level4, release_level3, release_level2,
                           release_level1, release_level0};
                bar_tops <= {bar_top_for(release_level7), bar_top_for(release_level6),
                             bar_top_for(release_level5), bar_top_for(release_level4),
                             bar_top_for(release_level3), bar_top_for(release_level2),
                             bar_top_for(release_level1), bar_top_for(release_level0)};
            end else begin
                release_count <= release_count + 1'b1;
            end
        end
    end

endmodule
