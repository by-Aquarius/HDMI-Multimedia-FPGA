`timescale 1ns/1ps
// Continuous sample cadence with bounded stream-edge tails / 连续采样与流边界平滑。
module audio_output_heartbeat #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer AUDIO_HZ=48000
)(
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire sample_valid,
    input wire [15:0] sample_pcm,
    output reg output_valid,
    output reg [15:0] output_pcm,
    output reg overflow
);
    // Original elastic FIFO; image changes never reset the sample clock phase.
    reg [25:0] phase;
    reg [15:0] samples[0:7];
    reg [2:0] write_index,read_index;
    reg [3:0] fill;
    wire tick=phase >= (CLOCK_HZ-AUDIO_HZ);
    wire bypass=enable && tick && fill==0 && sample_valid;
    wire push=enable && sample_valid && !bypass && (fill<8 || tick);
    wire pop=enable && tick && fill!=0;
    wire source_present=pop || bypass;
    wire signed [15:0] source_pcm=pop ? samples[read_index] : sample_pcm;

    // Q7 fade gain reaches exact unity; only stream boundaries change the waveform.
    reg [7:0] fade_gain;
    reg signed [15:0] tail_pcm;
    wire [7:0] next_gain=fade_gain<128 ? fade_gain+1'b1 : 8'd128;
    wire signed [8:0] signed_gain={1'b0,next_gain};
    wire signed [24:0] fade_product=source_pcm*signed_gain;
    wire signed [15:0] tail_step=tail_pcm>16'sd256 ? tail_pcm-16'sd256 :
        tail_pcm < -16'sd256 ? tail_pcm+16'sd256 : 16'sd0;
    wire signed [15:0] previous_pcm=output_pcm;
    wire signed [15:0] release_pcm=previous_pcm>16'sd256 ? previous_pcm-16'sd256 :
        previous_pcm < -16'sd256 ? previous_pcm+16'sd256 : 16'sd0;
    wire signed [17:0] faded_sample=fade_product[24:7];
    wire signed [17:0] tail_extended={{2{tail_step[15]}},tail_step};
    wire signed [17:0] mixed_sample=faded_sample+tail_extended;
    wire [15:0] limited_sample=mixed_sample>18'sd32767 ? 16'h7fff :
        mixed_sample < -18'sd32768 ? 16'h8000 : mixed_sample[15:0];

    // Stable 48kHz output and signed tail/gain registers share one clock domain.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            phase<=0;write_index<=0;read_index<=0;fill<=0;
            output_valid<=0;output_pcm<=0;overflow<=0;
            fade_gain<=0;tail_pcm<=0;
        end else begin
            phase<=tick ? phase+AUDIO_HZ-CLOCK_HZ : phase+AUDIO_HZ;
            output_valid<=tick;
            if(tick)begin
                if(source_present)begin
                    fade_gain<=next_gain;tail_pcm<=tail_step;
                    output_pcm<=limited_sample;
                end else begin
                    fade_gain<=0;tail_pcm<=release_pcm;
                    output_pcm<=release_pcm;
                end
            end
            if(!enable)begin
                write_index<=0;read_index<=0;fill<=0;
            end else begin
                if(sample_valid && fill==8 && !tick)overflow<=1;
                if(push)begin samples[write_index]<=sample_pcm;write_index<=write_index+1'b1;end
                if(pop)read_index<=read_index+1'b1;
                case({push,pop})
                    2'b10:fill<=fill+1'b1;
                    2'b01:fill<=fill-1'b1;
                    default:fill<=fill;
                endcase
            end
        end
    end
endmodule
