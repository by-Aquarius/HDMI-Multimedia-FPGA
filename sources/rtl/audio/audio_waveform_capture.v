`timescale 1ns/1ps
// Publish a complete 256-point trace at vertical blank; hold each bank until ack.
module audio_waveform_capture (
    input wire ctrl_clk,
    input wire ctrl_rst_n,
    input wire sample_valid,
    input wire [15:0] sample_pcm,
    input wire pixel_clk,
    input wire pixel_rst_n,
    input wire frame_boundary,
    input wire [7:0] read_address,
    output wire [7:0] sample_current,
    output wire [7:0] sample_previous
);
    reg [7:0] trace_memory [0:511];
    reg [7:0] write_address;
    reg [1:0] decimation_count;
    reg write_bank, request_toggle;
    reg ack_meta, ack_sync;
    reg request_meta, request_sync, request_settled, request_seen;
    reg front_bank, trace_visible;
    reg [7:0] current_word, previous_word;
    reg visible_read;
    wire capture_ready = ack_sync == request_toggle;
    wire capture_sample = sample_valid && capture_ready && decimation_count == 3;
    wire [7:0] prior_address = read_address == 0 ? 8'd0 : read_address - 1'b1;
    assign sample_current = visible_read ? current_word : 8'd116;
    assign sample_previous = visible_read ? previous_word : 8'd116;

    // No memory reset: the visibility token masks all uninitialized words.
    always @(posedge ctrl_clk) begin
        if (capture_sample)
            trace_memory[{write_bank,write_address}] <= 8'd180 - {1'b0,(sample_pcm[15:9] ^ 7'h40)};
    end
    always @(posedge pixel_clk) begin
        current_word <= trace_memory[{front_bank,read_address}];
        previous_word <= trace_memory[{front_bank,prior_address}];
    end
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n) begin
            write_address<=0; decimation_count<=0;
            write_bank<=1; request_toggle<=0; ack_meta<=0; ack_sync<=0;
        end else begin
            ack_meta<=request_seen; ack_sync<=ack_meta;
            if (capture_ready) begin
                if (sample_valid) decimation_count<=decimation_count+1'b1;
                if (capture_sample) begin
                    write_address<=write_address+1'b1;
                    if (write_address==255) begin
                        request_toggle<=!request_toggle;
                        write_bank<=!write_bank;
                    end
                end
            end
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if (!pixel_rst_n) begin
            request_meta<=0; request_sync<=0; request_settled<=0;
            request_seen<=0; front_bank<=0; trace_visible<=0; visible_read<=0;
        end else begin
            request_meta<=request_toggle; request_sync<=request_meta;
            request_settled<=request_sync; visible_read<=trace_visible;
            if (frame_boundary && request_settled!=request_seen) begin
                front_bank<=!front_bank; trace_visible<=1;
                request_seen<=request_settled;
            end
        end
    end
endmodule
