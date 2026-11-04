`timescale 1ns / 1ps
// File completion rendezvous / 文件结束事件汇合。
// A short file can deliver its last byte before the SD sector finishes draining.
// Retain both events in either order, let the WAV parser settle, report once.
module audio_stream_completion (
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire last_consumed,
    input wire reader_done,
    output wire completed
);
    reg last_seen_q,reader_seen_q,reported_q,completed_q;
    reg [1:0] settle_q;
    assign completed=completed_q;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin last_seen_q<=0;reader_seen_q<=0;reported_q<=0;completed_q<=0;settle_q<=0;end
        else if(clear) begin last_seen_q<=0;reader_seen_q<=0;reported_q<=0;completed_q<=0;settle_q<=0;end
        else begin
            completed_q<=0;
            if(reader_done) reader_seen_q<=1;
            if(last_consumed) begin last_seen_q<=1;settle_q<=3;end
            else if(settle_q!=0) settle_q<=settle_q-1'b1;
            if(last_seen_q && reader_seen_q && settle_q==0 && !reported_q) begin
                completed_q<=1;reported_q<=1;
            end
        end
    end
endmodule
