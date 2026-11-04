`timescale 1ns/1ps
// Shared signed PCM gain for the speaker, HDMI packets and spectrum estimator.
module audio_volume_control (
    input wire clk,
    input wire rst_n,
    input wire key_up,
    input wire key_down,
    input wire enable,
    input wire sample_valid,
    input wire [15:0] sample_pcm,
    output reg [4:0] volume_level,
    output reg output_valid,
    output reg [15:0] output_pcm
);
    wire signed [15:0] signed_sample = sample_pcm;
    reg signed [9:0] signed_gain;
    // Q8 gain table: 0 is mute, 10 is exactly unity; all paths share this PCM.
    always @(*) begin
        case(volume_level)
            0:signed_gain=0; 1:signed_gain=26; 2:signed_gain=51;
            3:signed_gain=77; 4:signed_gain=102; 5:signed_gain=128;
            6:signed_gain=154; 7:signed_gain=179; 8:signed_gain=205;
            9:signed_gain=230; default:signed_gain=256;
        endcase
    end
    reg signed [25:0] product;
    reg product_valid;
    reg enable_previous;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) volume_level <= 5'd8;
        else if(key_up && !key_down && volume_level<10) volume_level<=volume_level+1'b1;
        else if(key_down && !key_up && volume_level>0) volume_level<=volume_level-1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            product<=0; product_valid<=0; output_valid<=0; output_pcm<=0; enable_previous<=0;
        end else begin
            enable_previous<=enable;
            product<=signed_sample*signed_gain;
            product_valid<=sample_valid && enable;
            if(!enable)begin
                output_pcm<=0;
                output_valid<=enable_previous;
            end else begin
                output_valid<=product_valid;
                if(product_valid)output_pcm<=product >>> 8;
            end
        end
    end
endmodule
