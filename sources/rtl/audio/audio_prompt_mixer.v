`timescale 1ns/1ps
// Sample-rate voice mixer / 采样同步语音混音与背景压低。
module audio_prompt_mixer (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire music_enable,
    input wire music_valid,
    input wire [15:0] music_pcm,
    input wire voice_enable,
    input wire voice_busy,
    input wire [15:0] voice_pcm,
    output reg output_valid,
    output reg [15:0] output_pcm,
    output reg overflow
);
    reg [15:0] samples [0:7];
    reg [2:0] write_pointer, read_pointer;
    reg [3:0] fill;
    reg [7:0] music_gain;
    reg music_enable_seen;
    wire music_boundary=music_enable!=music_enable_seen;
    reg signed [15:0] voice_hold;
    reg signed [15:0] voice_target_q;
    reg signed [18:0] voice_ramp;
    reg signed [16:0] voice_step;
    reg [2:0] voice_remaining;
    wire bypass=music_enable && sample_tick && !music_boundary && fill==0 && music_valid;
    wire pop=music_enable && sample_tick && !music_boundary && fill!=0;
    wire push=music_enable && music_valid && !bypass && (fill<8 || pop);
    wire present=pop || bypass;
    wire signed [15:0] music_source=pop ? samples[read_pointer] : music_pcm;
    wire signed [8:0] gain_signed={1'b0,music_gain};
    wire signed [24:0] music_product=music_source*gain_signed;
    reg signed [17:0] scaled_music;
    reg signed [17:0] voice_extended;
    reg signed [17:0] sum;
    reg valid_product, valid_sum;
    wire duck=voice_enable && voice_busy;
    wire signed [15:0] voice_target=voice_enable ? voice_pcm : 16'sd0;
    // Linear 6k-to-48k reconstruction; wide Q3 residual avoids tiny-delta overshoot.
    wire signed [16:0] voice_delta={voice_target[15],voice_target}-{voice_hold[15],voice_hold};
    wire signed [18:0] voice_start={voice_hold,3'd0};
    wire signed [18:0] voice_delta_wide={{2{voice_delta[16]}},voice_delta};
    wire signed [18:0] voice_step_wide={{2{voice_step[16]}},voice_step};
    wire signed [18:0] voice_first=voice_start+voice_delta_wide;
    wire signed [18:0] voice_follow=voice_ramp+voice_step_wide;
    wire voice_changed=voice_target!=voice_target_q;
    wire signed [15:0] voice_next=voice_changed ? voice_first[18:3] :
        voice_remaining!=0 ? voice_follow[18:3] : voice_hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer<=0; read_pointer<=0; fill<=0; music_gain<=128; music_enable_seen<=0;
            voice_hold<=0; voice_target_q<=0; voice_ramp<=0; voice_step<=0; voice_remaining<=0; scaled_music<=0; voice_extended<=0;
            sum<=0; valid_product<=0; valid_sum<=0;
            output_valid<=0; output_pcm<=0; overflow<=0;
        end else begin
            valid_product<=sample_tick && !music_boundary &&
                !(music_enable && !present) && (present || voice_enable || voice_hold!=0);
            valid_sum<=valid_product; output_valid<=valid_sum;
            if (sample_tick) begin
                music_enable_seen<=music_enable;
                if (duck && music_gain>16) music_gain<=music_gain-1'b1;
                else if (!duck && music_gain<128) music_gain<=music_gain+1'b1;
                voice_hold<=voice_next;
                if (voice_changed) begin
                    voice_target_q<=voice_target; voice_step<=voice_delta;
                    voice_ramp<=voice_first; voice_remaining<=7;
                end else if (voice_remaining!=0) begin
                    voice_ramp<=voice_follow; voice_remaining<=voice_remaining-1'b1;
                end
                scaled_music<=present ? (music_product >>> 7) : 18'sd0;
                voice_extended<={{2{voice_next[15]}},voice_next};
            end
            if (valid_product) sum<=scaled_music+voice_extended;
            if (valid_sum) begin
                if (sum>18'sd32767) output_pcm<=16'h7fff;
                else if (sum < -18'sd32768) output_pcm<=16'h8000;
                else output_pcm<=sum[15:0];
            end
            if (!music_enable) begin write_pointer<=0; read_pointer<=0; fill<=0; end
            else begin
                if (music_valid && fill==8 && !pop) overflow<=1;
                if (push) begin samples[write_pointer]<=music_pcm; write_pointer<=write_pointer+1'b1; end
                if (pop) read_pointer<=read_pointer+1'b1;
                case ({push,pop})
                    2'b10: fill<=fill+1'b1;
                    2'b01: fill<=fill-1'b1;
                    default: fill<=fill;
                endcase
            end
        end
    end
endmodule
